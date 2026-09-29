#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <stdatomic.h>

extern char **environ;

#define JF_TAIL 32768
#define JF_ARGS 64
#define JF_JOBS 32
#define JF_ARG_BYTES 4096
#define JF_SPOOL_LIMIT 1048576
#define JF_LIMIT_MAX 1048580
#define JF_TEXT_INPUT_MAX 131072u
#define JF_BYTES_INPUT_MAX 4194304u
#define JF_TIMEOUT_MAX_MS 3600000
// Only exec_logged and rolling exec_pipe, the job and session workers' effects, accept a day.
#define JF_JOB_TIMEOUT_MAX_MS 86400000
#define JF_TIMEOUT_EXIT 124
#define JF_NS_PER_MS 1000000ull
// After the child exits, keep draining pipes held by escaped descendants this long.
#define JF_DRAIN_GRACE_NS 100000000ull
#define JF_POLL_MS 10
// A cancelled group gets SIGTERM, then SIGKILL once this grace has passed.
#define JF_TERM_GRACE_NS 500000000ull
// Rolling spools: a 16-byte header (bytes written as a little-endian u64, then a
// u64 of flags, bit 0 meaning the stream has ended) and a ring of this many bytes.
#define JF_RING 1048576
#define JF_RING_HEAD 16
#define JF_CWD_MAX 4096

#ifdef __linux__
// glibc 2.29+; declared here in case the build's feature macros hide it.
extern int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);
#endif

// Report flags; Process.decode reads the same bits.
enum {
  JF_TIMED_OUT = 1,
  JF_STDOUT_CUT = 2,
  JF_STDERR_CUT = 4,
  JF_CANCELLED = 8,
};

typedef struct {
  char *argv[JF_ARGS + 1];
  size_t argc;
  char *input;
  u64 input_len;
  u32 timeout;
  int inherit_stdin;
  int stdin_fd;
  u32 code;
  u32 flags;
  char *out;
  char *err;
  u32 limit;
  int bytes;
  int logs[2];
  size_t logged[2];
  int rolling;
  char *cwd;
  int log_error;
  size_t out_len;
  size_t err_len;
} JfExec;

static pthread_mutex_t jf_gate = PTHREAD_MUTEX_INITIALIZER;
static unsigned jf_jobs;
static pid_t jf_pids[JF_JOBS];
static int jf_shutdown;
static _Atomic int jf_interrupt;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "signal flag must be lock-free");

static void jf_signal(int signal_number) {
  atomic_store_explicit(&jf_interrupt, signal_number, memory_order_relaxed);
}

// Shared with http.c, which aborts pooled transfers on the same interrupt.
int jf_interrupted(void) {
  return atomic_load_explicit(&jf_interrupt, memory_order_relaxed) != 0;
}

static void jf_cleanup(void) {
  pid_t owned[JF_JOBS];
  pthread_mutex_lock(&jf_gate);
  jf_shutdown = 1;
  memcpy(owned, jf_pids, sizeof owned);
  for (unsigned i = 0; i < JF_JOBS; i++) {
    if (owned[i] > 0) {
      kill(-owned[i], SIGKILL);
    }
  }
  pthread_mutex_unlock(&jf_gate);
  for (unsigned i = 0; i < JF_JOBS; i++) {
    if (owned[i] > 0) {
      while (waitpid(owned[i], NULL, 0) < 0 && errno == EINTR) {}
    }
  }
}

static void jf_close(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

static int jf_pipe(int fds[2]) {
  if (pipe(fds) < 0) {
    return -1;
  }
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
    int saved = errno;
    jf_close(&fds[0]);
    jf_close(&fds[1]);
    errno = saved;
    return -1;
  }
  return 0;
}

// Keep the newest `limit` bytes of a stream in `dest`, setting `bit` once any are dropped.
static void jf_tail(
  char *dest,
  size_t *used,
  const char *data,
  size_t count,
  size_t limit,
  u32 *flags,
  u32 bit
) {
  if (*used + count > limit) {
    *flags |= bit;
  }
  if (count >= limit) {
    memcpy(dest, data + count - limit, limit);
    *used = limit;
  } else {
    size_t discard = *used + count > limit ? *used + count - limit : 0;
    memmove(dest, dest + discard, *used - discard);
    *used -= discard;
    memcpy(dest + *used, data, count);
    *used += count;
  }
}

// Publishes a rolling spool's header: the bytes written so far and the flags.
static void jf_ring_head(JfExec *job, int stream, u64 flags) {
  unsigned char head[JF_RING_HEAD];
  u64 count = (u64)job->logged[stream];
  for (int i = 0; i < 8; i++) {
    head[i] = (unsigned char)(count >> (8 * i));
    head[8 + i] = (unsigned char)(flags >> (8 * i));
  }
  size_t used = 0;
  while (used < sizeof head) {
    ssize_t put = pwrite(job->logs[stream], head + used, sizeof head - used, (off_t)used);
    if (put > 0) {
      used += (size_t)put;
    } else if (put < 0 && errno == EINTR) {
      continue;
    } else {
      job->log_error = put < 0 ? errno : EIO;
      return;
    }
  }
}

// Writes into the ring at the running offset, wrapping, then publishes the new count.
// Data is written before the header, so a reader never sees a count ahead of its bytes.
static void jf_ring(JfExec *job, int stream, const char *data, size_t length) {
  while (length) {
    size_t at = job->logged[stream] % JF_RING;
    size_t room = JF_RING - at;
    size_t chunk = length < room ? length : room;
    ssize_t put = pwrite(job->logs[stream], data, chunk, (off_t)(JF_RING_HEAD + at));
    if (put > 0) {
      job->logged[stream] += (size_t)put;
      data += put;
      length -= (size_t)put;
    } else if (put < 0 && errno == EINTR) {
      continue;
    } else {
      job->log_error = put < 0 ? errno : EIO;
      return;
    }
  }
  jf_ring_head(job, stream, 0);
}

// Append to the stream's spool file until it holds JF_SPOOL_LIMIT bytes, or
// keep its latest JF_RING bytes when the spool is rolling.
static void jf_spool(JfExec *job, int stream, const char *data, size_t length) {
  if (job->logs[stream] >= 0 && job->rolling) {
    jf_ring(job, stream, data, length);
    return;
  }
  if (job->logs[stream] < 0 || job->logged[stream] >= JF_SPOOL_LIMIT) {
    return;
  }
  size_t room = JF_SPOOL_LIMIT - job->logged[stream];
  size_t pending = length < room ? length : room;
  while (pending) {
    ssize_t put = write(job->logs[stream], data, pending);
    if (put > 0) {
      job->logged[stream] += (size_t)put;
      data += put;
      pending -= (size_t)put;
    } else if (put < 0 && errno == EINTR) {
      continue;
    } else {
      job->log_error = put < 0 ? errno : EIO;
      break;
    }
  }
}

// `stream` is 0 for stdout and 1 for stderr.
static void jf_read(int *fd, JfExec *job, int stream) {
  char buffer[8192];
  ssize_t got = read(*fd, buffer, sizeof buffer);
  if (got > 0) {
    jf_spool(job, stream, buffer, (size_t)got);
    jf_tail(
      stream ? job->err : job->out,
      stream ? &job->err_len : &job->out_len,
      buffer,
      (size_t)got,
      job->limit,
      &job->flags,
      stream ? JF_STDERR_CUT : JF_STDOUT_CUT
    );
  } else if (got == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
    jf_close(fd);
  }
}

// This helper thread owns all descriptors and the child's process group.
// It never touches Bend terms or Env; packing occurs back on Bend's IO loop.
static void jf_exec_call(IoWork *w) {
  JfExec *job = (JfExec *)w->data;
  int in_pipe[2] = {-1, -1};
  int out_pipe[2] = {-1, -1};
  int err_pipe[2] = {-1, -1};
  pid_t pid = -1;
  int status = 0;
  int done = 0;
  int registered = 0;
  int slot = -1;
  size_t sent = 0;
  u64 exited_at = 0;
  u64 term_at = 0;
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  int have_actions = 0;
  int have_attr = 0;
  pthread_mutex_lock(&jf_gate);
  if (!jf_shutdown && jf_jobs < JF_JOBS) {
    for (unsigned i = 0; i < JF_JOBS; i++) {
      if (jf_pids[i] == 0) {
        slot = (int)i;
        jf_pids[i] = -1;
        break;
      }
    }
    jf_jobs++;
    registered = 1;
  }
  pthread_mutex_unlock(&jf_gate);
  if (!registered) {
    w->code = EAGAIN;
    return;
  }
  if (jf_interrupt) {
    w->code = EINTR;
    goto cleanup;
  }
  if (job->rolling) {
    for (int s = 0; s < 2; s++) {
      if (job->logs[s] >= 0) {
        jf_ring_head(job, s, 0);
      }
    }
    if (job->log_error) {
      w->code = job->log_error;
      goto cleanup;
    }
  }
  // A caller-provided stdin reader is not re-piped here: in_pipe[0] carries it so
  // the spawn file action and every cleanup path close that one fd.
  if (job->stdin_fd >= 0) {
    in_pipe[0] = job->stdin_fd;
    job->stdin_fd = -1;
  } else if (!job->inherit_stdin && jf_pipe(in_pipe) < 0) {
    w->code = errno;
    goto cleanup;
  }
  if (jf_pipe(out_pipe) < 0 || jf_pipe(err_pipe) < 0) {
    w->code = errno;
    goto cleanup;
  }
  w->code = posix_spawn_file_actions_init(&actions);
  if (w->code) {
    goto cleanup;
  }
  have_actions = 1;
  w->code = posix_spawnattr_init(&attr);
  if (w->code) {
    goto cleanup;
  }
  have_attr = 1;
  sigset_t defaults;
  sigemptyset(&defaults);
  sigaddset(&defaults, SIGPIPE);
  sigaddset(&defaults, SIGINT);
  sigaddset(&defaults, SIGTERM);
  short spawn_flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF;
  if ((w->code = posix_spawnattr_setpgroup(&attr, 0))
      || (w->code = posix_spawnattr_setsigdefault(&attr, &defaults))
      || (w->code = posix_spawnattr_setflags(&attr, spawn_flags))) {
    goto cleanup;
  }
  int child_stdin = job->inherit_stdin ? STDIN_FILENO : in_pipe[0];
  if ((w->code = posix_spawn_file_actions_adddup2(&actions, child_stdin, STDIN_FILENO))
      || (w->code = posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO))
      || (w->code = posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO))) {
    goto cleanup;
  }
  if (job->cwd && job->cwd[0]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    w->code = posix_spawn_file_actions_addchdir_np(&actions, job->cwd);
#pragma clang diagnostic pop
    if (w->code) {
      goto cleanup;
    }
  }
  // A rolling child that reads this process's own stdin (a session worker
  // passing on its owner's pipe) takes it over: once it has started, this
  // process lets go of fd 0, so the owner's writes fail once the child is gone.
  int release_stdin = 0;
  if (job->rolling && in_pipe[0] >= 0) {
    struct stat given;
    struct stat own;
    release_stdin = fstat(in_pipe[0], &given) == 0 && fstat(STDIN_FILENO, &own) == 0
      && given.st_dev == own.st_dev && given.st_ino == own.st_ino;
  }
  pthread_mutex_lock(&jf_gate);
  if (jf_shutdown) {
    w->code = ECANCELED;
  } else {
    w->code = posix_spawnp(&pid, job->argv[0], &actions, &attr, job->argv, environ);
  }
  if (!w->code && release_stdin) {
    int none = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (none >= 0) {
      dup2(none, STDIN_FILENO);
      close(none);
    }
  }
  if (!w->code) {
    jf_pids[slot] = pid;
  } else {
    pid = -1;
  }
  pthread_mutex_unlock(&jf_gate);
  if (w->code) {
    goto cleanup;
  }
  jf_close(&in_pipe[0]);
  jf_close(&out_pipe[1]);
  jf_close(&err_pipe[1]);
  if ((in_pipe[1] >= 0 && fcntl(in_pipe[1], F_SETFL, O_NONBLOCK) < 0)
      || fcntl(out_pipe[0], F_SETFL, O_NONBLOCK) < 0
      || fcntl(err_pipe[0], F_SETFL, O_NONBLOCK) < 0) {
    w->code = errno;
    goto cleanup;
  }
  u64 deadline = io_tick() + (u64)job->timeout * JF_NS_PER_MS;
  while (!done || out_pipe[0] >= 0 || err_pipe[0] >= 0) {
    // Stop the group, then force it once the grace has passed.
    if (!done && jf_interrupt && !(job->flags & JF_CANCELLED)) {
      job->flags |= JF_CANCELLED;
      job->code = 128 + jf_interrupt;
      kill(-pid, SIGTERM);
      term_at = io_tick();
    } else if (!done && term_at && io_tick() - term_at >= JF_TERM_GRACE_NS) {
      kill(-pid, SIGKILL);
      term_at = 0;
    }
    if (!done && io_tick() >= deadline && !(job->flags & (JF_TIMED_OUT | JF_CANCELLED))) {
      job->flags |= JF_TIMED_OUT;
      job->code = JF_TIMEOUT_EXIT;
      kill(-pid, SIGKILL);
    }
    if (!done) {
      pid_t got = waitpid(pid, &status, WNOHANG);
      if (got == pid) {
        done = 1;
        exited_at = io_tick();
        kill(-pid, SIGKILL);
        jf_close(&in_pipe[1]);
        pthread_mutex_lock(&jf_gate);
        jf_pids[slot] = -1;
        pthread_mutex_unlock(&jf_gate);
      } else if (got < 0 && errno != EINTR) {
        w->code = errno;
        goto cleanup;
      }
    }
    if (done && io_tick() - exited_at > JF_DRAIN_GRACE_NS) {
      // Do not hang on an escaped daemon that retained a pipe. Disclose lost output.
      if (out_pipe[0] >= 0) {
        job->flags |= JF_STDOUT_CUT;
      }
      if (err_pipe[0] >= 0) {
        job->flags |= JF_STDERR_CUT;
      }
      jf_close(&out_pipe[0]);
      jf_close(&err_pipe[0]);
      break;
    }
    if (sent == job->input_len) {
      jf_close(&in_pipe[1]);
    }
    struct pollfd fds[3] = {
      {out_pipe[0], POLLIN, 0},
      {err_pipe[0], POLLIN, 0},
      {in_pipe[1], POLLOUT, 0},
    };
    int ready = poll(fds, 3, JF_POLL_MS);
    if (ready < 0 && errno != EINTR) {
      w->code = errno;
      goto cleanup;
    }
    if (out_pipe[0] >= 0 && fds[0].revents) {
      jf_read(&out_pipe[0], job, 0);
    }
    if (err_pipe[0] >= 0 && fds[1].revents) {
      jf_read(&err_pipe[0], job, 1);
    }
    if (job->log_error) {
      w->code = job->log_error;
      goto cleanup;
    }
    if (in_pipe[1] >= 0 && fds[2].revents) {
      ssize_t wrote = write(in_pipe[1], job->input + sent, job->input_len - sent);
      if (wrote > 0) {
        sent += wrote;
      } else if (wrote < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        jf_close(&in_pipe[1]);
      }
    }
  }
  if (!(job->flags & (JF_TIMED_OUT | JF_CANCELLED))) {
    job->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  }
cleanup:
  if (pid > 0 && !done) {
    kill(-pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  }
  jf_close(&in_pipe[0]);
  jf_close(&in_pipe[1]);
  jf_close(&out_pipe[0]);
  jf_close(&out_pipe[1]);
  jf_close(&err_pipe[0]);
  jf_close(&err_pipe[1]);
  if (have_actions) {
    posix_spawn_file_actions_destroy(&actions);
  }
  if (have_attr) {
    posix_spawnattr_destroy(&attr);
  }
  pthread_mutex_lock(&jf_gate);
  jf_pids[slot] = 0;
  jf_jobs--;
  pthread_mutex_unlock(&jf_gate);
}

static Term jf_bytes(Env e, const char *data, size_t size) {
  Term xs = term_pak(CID(Nil), 0);
  for (size_t i = size; i > 0; i--) {
    xs = io_node(e, CID(Con), (uint8_t)data[i - 1], xs);
  }
  return xs;
}

// Byte captures return List<U32>; text captures return a String.
static Term jf_stream(Env e, JfExec *job, const char *data, size_t size) {
  return job->bytes ? jf_bytes(e, data, size) : io_str(e, data, size);
}

// Packs (code, (flags, (stdout, stderr))) and frees every job resource.
static Term jf_exec_pack(Env e, IoWork *w) {
  JfExec *job = (JfExec *)w->data;
  Term result;
  if (w->code) {
    result = io_fail(e, w->code, "native subprocess request failed");
  } else {
    Term out = jf_stream(e, job, job->out, job->out_len);
    Term err = jf_stream(e, job, job->err, job->err_len);
    Term streams = io_tup(e, out, err);
    result = io_done(e, io_tup(e, (Term)job->code, io_tup(e, (Term)job->flags, streams)));
  }
  for (size_t i = 0; i < job->argc; i++) {
    free(job->argv[i]);
  }
  if (job->logs[0] == job->logs[1]) {
    job->logs[1] = -1;
  }
  // A rolling stream has ended once its supervisor has: mark it for readers.
  for (int s = 0; s < 2 && job->rolling; s++) {
    if (job->logs[s] >= 0) {
      jf_ring_head(job, s, 1);
    }
  }
  free(job->cwd);
  jf_close(&job->logs[0]);
  jf_close(&job->logs[1]);
  jf_close(&job->stdin_fd);
  free(job->input);
  free(job->out);
  free(job->err);
  free(job);
  return result;
}

static Term jf_exec_start(
  Env e,
  Term *f,
  IoWork *w,
  u32 limit,
  int inherit,
  int bytes,
  int log_out,
  int log_err,
  int stdin_fd,
  u32 timeout_max,
  int rolling,
  Term cwd
) {
  JfExec *job = io_mem(calloc(1, sizeof *job));
  w->data = (char *)job;
  w->code = 0;
  job->logs[0] = log_out;
  job->logs[1] = log_err;
  job->rolling = rolling;
  u64 cwd_len = 0;
  job->cwd = io_cstr(e, cwd, &cwd_len);
  // A working directory is absolute or empty (inherit); spawn reports a missing one.
  if (cwd_len > JF_CWD_MAX || io_nul(job->cwd, cwd_len) || (cwd_len && job->cwd[0] != '/')) {
    w->code = EINVAL;
  }
  for (int i = 0; i < 2; i++) {
    if (job->logs[i] >= 0) {
      struct stat st;
      if (fstat(job->logs[i], &st) < 0 || !S_ISREG(st.st_mode)) {
        w->code = EINVAL;
      }
    }
  }
  Term args = f[0];
  while (term_aux(args) == CID(Con)) {
    Term fields[2];
    spare_free(e, cls_fit(2), ctr_take(e, args, 2, fields));
    u64 length = 0;
    char *arg = io_cstr(e, fields[0], &length);
    if (job->argc == JF_ARGS || length > JF_ARG_BYTES || io_nul(arg, length)) {
      w->code = EINVAL;
      free(arg);
    } else {
      job->argv[job->argc++] = arg;
    }
    args = fields[1];
  }
  job->input = io_cstr(e, f[1], &job->input_len);
  job->timeout = (u32)f[2];
  job->inherit_stdin = inherit;
  job->stdin_fd = stdin_fd;
  job->bytes = bytes;
  job->limit = limit;
  u64 input_max = bytes ? JF_BYTES_INPUT_MAX : JF_TEXT_INPUT_MAX;
  if (!job->argc || !job->argv[0][0] || job->input_len > input_max
      || !job->timeout || job->timeout > timeout_max
      || !limit || limit > JF_LIMIT_MAX
      || stdin_fd < -1 || (stdin_fd >= 0 && inherit)) {
    w->code = EINVAL;
  }
  if (!w->code) {
    job->out = malloc(limit);
    job->err = malloc(limit);
    if (!job->out || !job->err) {
      w->code = ENOMEM;
    }
  }
  return w->code ? jf_exec_pack(e, w) : io_work(w, jf_exec_call, jf_exec_pack);
}

#ifdef CID(Native.exec)
Term native_exec_run(Env e, Term *f, IoWork *w) {
  int inherit = term_aux(f[3]) == CID(True);
  return jf_exec_start(e, f, w, JF_TAIL, inherit, 0, -1, -1, -1, JF_TIMEOUT_MAX_MS, 0, f[4]);
}
#endif

#ifdef CID(Native.capture)
Term native_capture_run(Env e, Term *f, IoWork *w) {
  Term none = term_pak(CID(SNil), 0);
  return jf_exec_start(e, f, w, (u32)f[3], 0, 1, -1, -1, -1, JF_TIMEOUT_MAX_MS, 0, none);
}
#endif

#ifdef CID(Native.exec_logged)
Term native_exec_logged_run(Env e, Term *f, IoWork *w) {
  Term args[3] = {f[0], term_pak(CID(SNil), 0), f[1]};
  int log_out = (int)io_hand_v(f[2]);
  int log_err = (int)io_hand_v(f[3]);
  return jf_exec_start(e, args, w, JF_TAIL, 0, 0, log_out, log_err, -1, JF_JOB_TIMEOUT_MAX_MS, 0, f[4]);
}
#endif

// Interactive sibling of exec_logged: the child's stdin is a caller-provided
// pipe reader (consumed and closed after dup2), while stdout/stderr spool to
// the given writer handles as exec_logged does, or, when rolling, keep the
// latest JF_RING bytes of each stream behind a published header. A rolling
// child may live for a day, like a job; the first-byte form keeps the hour.
#ifdef CID(Native.exec_pipe)
Term native_exec_pipe_run(Env e, Term *f, IoWork *w) {
  Term args[3] = {f[0], term_pak(CID(SNil), 0), f[2]};
  int stdin_fd = (int)io_hand_v(f[1]);
  int log_out = (int)io_hand_v(f[3]);
  int log_err = (int)io_hand_v(f[4]);
  int rolling = term_aux(f[5]) == CID(True);
  u32 max = rolling ? JF_JOB_TIMEOUT_MAX_MS : JF_TIMEOUT_MAX_MS;
  return jf_exec_start(e, args, w, JF_TAIL, 0, 0, log_out, log_err, stdin_fd, max, rolling, f[6]);
}
#endif

#ifdef CID(Native.cancel)
Term native_cancel_run(Env e, Term *f, IoWork *w) {
  jf_signal(SIGTERM);
  return term_pak(CID(Unit), 0);
}
#endif

static void __attribute__((constructor)) native_exec_use(void) {
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = jf_signal;
  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGTERM, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  atexit(jf_cleanup);
#ifdef CID(Native.exec)
  io_eff(CID(Native.exec), native_exec_run, 0);
#endif
#ifdef CID(Native.capture)
  io_eff(CID(Native.capture), native_capture_run, 0);
#endif
#ifdef CID(Native.exec_logged)
  io_eff(CID(Native.exec_logged), native_exec_logged_run, 0);
#endif
#ifdef CID(Native.exec_pipe)
  io_eff(CID(Native.exec_pipe), native_exec_pipe_run, 0);
#endif
#ifdef CID(Native.cancel)
  io_eff(CID(Native.cancel), native_cancel_run, 0);
#endif
}
