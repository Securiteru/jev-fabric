#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <limits.h>
#include <time.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

extern char **environ;

#define JFH_ID_LEN 32
#define JFH_LEAF_MAX 64
#define JFH_ARGS 69
#define JFH_ARG_BYTES 4096
#define JFH_TEXT_MAX 1048576
#define JFH_JOBS_MAX 4096

#define JFH_STORE_NAME ".jev-fabric-store.json"
#define JFH_STORE_MAX 4096
#define JFH_PATH_MAX 4096

// Operations of Host.jfh_os (0..6, 8..17) and Host.jfh_spool (7).
enum {
  JFH_SELF = 0,
  JFH_CREATE = 1,
  JFH_READ = 2,
  JFH_WRITE = 3,
  JFH_CLAIM = 4,
  JFH_ALIVE = 5,
  JFH_SPAWN = 6,
  JFH_SPOOL = 7,
  JFH_LIST = 8,
  JFH_CLOCK = 9,
  JFH_PARENT = 10,
  JFH_ENQUEUE = 11,
  JFH_DEQUEUE = 12,
  JFH_REMOVE = 13,
  JFH_PLATFORM = 14,
  JFH_DIRECTORY = 15,
  JFH_STORE = 16,
  JFH_ADOPT = 17,
};

/* No JSON, job state machine, event policy or command execution here. The
 * worker is this same native executable; posix_spawn avoids Bend post-fork
 * allocator/runtime hazards. Every OS string and buffer has a fixed bound. */
typedef struct {
  u32 op;
  u32 limit;
  int opened;
  char *id;
  char *name;
  char *text;
  char *argv[JFH_ARGS + 1];
  size_t argc;
  size_t text_len;
  size_t result_len;
  char *result;
} jfh_request;

static int jfh_lease = -1;

// Owned by us, no group/other permissions, and a directory or a single-link regular file.
static int jfh_private(int fd, int directory) {
  struct stat s;
  if (fstat(fd, &s) < 0) {
    return -1;
  }
  int right_type = directory ? S_ISDIR(s.st_mode) : (S_ISREG(s.st_mode) && s.st_nlink == 1);
  if (s.st_uid != geteuid() || (s.st_mode & 077) || !right_type) {
    errno = EPERM;
    return -1;
  }
  return 0;
}

static int jfh_id(const char *s) {
  if (strlen(s) != JFH_ID_LEN) {
    return 0;
  }
  for (unsigned i = 0; i < JFH_ID_LEN; i++) {
    int hex = (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= '0' && s[i] <= '9');
    if (!hex) {
      return 0;
    }
  }
  return 1;
}

static int jfh_leaf(const char *s) {
  size_t n = strlen(s);
  if (!n || n > JFH_LEAF_MAX || s[0] == '.') {
    return 0;
  }
  for (size_t i = 0; i < n; i++) {
    int allowed = (s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9')
      || s[i] == '.' || s[i] == '-';
    if (!allowed) {
      return 0;
    }
  }
  return 1;
}

/* A default root created by this call also ignores itself in version control.
 * Best effort: the root stays valid without it, and nothing reads it back. */
static void jfh_ignore(int root) {
  int fd = openat(root, ".gitignore", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    return;
  }
  ssize_t put;
  do {
    put = write(fd, "*\n", 2);
  } while (put < 0 && errno == EINTR);
  close(fd);
}

/* Walk components with no-follow directory descriptors, including ancestors.
 * No realpath(root): it would silently bless symlink traversal. `made`, when
 * given, reports whether this call created the root itself. */
static int jfh_root_made(int *made) {
  const char *env = getenv("JEV_FABRIC_HOME");
  const char *path = env ? env : ".jev-fabric-native";
  int created = 0;
  if (!*path || strlen(path) >= PATH_MAX) {
    errno = EINVAL;
    return -1;
  }
  char copy[PATH_MAX];
  strcpy(copy, path);
  int fd = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    return -1;
  }
  char *save = NULL;
  char *part = strtok_r(copy, "/", &save);
  while (part) {
    if (!strcmp(part, ".") || !strcmp(part, "..")) {
      close(fd);
      errno = EINVAL;
      return -1;
    }
    created = mkdirat(fd, part, 0700) == 0;
    if (!created && errno != EEXIST) {
      int saved = errno;
      close(fd);
      errno = saved;
      return -1;
    }
    int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int saved = errno;
    close(fd);
    fd = next;
    if (fd < 0) {
      errno = saved;
      return -1;
    }
    part = strtok_r(NULL, "/", &save);
  }
  if (jfh_private(fd, 1) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  if (!env && created) {
    jfh_ignore(fd);
  }
  if (made) {
    *made = created;
  }
  return fd;
}

static int jfh_root(void) {
  return jfh_root_made(NULL);
}

static int jfh_dir(const char *id) {
  if (!jfh_id(id)) {
    errno = EINVAL;
    return -1;
  }
  int root = jfh_root();
  if (root < 0) {
    return -1;
  }
  int fd = openat(root, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int saved = errno;
  close(root);
  if (fd < 0) {
    errno = saved;
    return -1;
  }
  if (jfh_private(fd, 1) < 0) {
    saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

// Writes 32 lowercase hex digits from /dev/urandom plus a NUL.
static int jfh_random(char out[JFH_ID_LEN + 1]) {
  static const char digits[] = "0123456789abcdef";
  unsigned char bytes[JFH_ID_LEN / 2];
  int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return -1;
  }
  size_t used = 0;
  while (used < sizeof bytes) {
    ssize_t got = read(fd, bytes + used, sizeof bytes - used);
    if (got < 0 && errno == EINTR) {
      continue;
    }
    if (got <= 0) {
      int saved = got ? errno : EIO;
      close(fd);
      errno = saved;
      return -1;
    }
    used += (size_t)got;
  }
  close(fd);
  for (unsigned i = 0; i < sizeof bytes; i++) {
    out[2 * i] = digits[bytes[i] >> 4];
    out[2 * i + 1] = digits[bytes[i] & 15];
  }
  out[JFH_ID_LEN] = 0;
  return 0;
}

// A missing file succeeds with *text unset; the caller treats that as empty.
static int jfh_read_file(int dir, const char *name, u32 limit, char **text, size_t *length) {
  int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) {
    return errno == ENOENT ? 0 : -1;
  }
  struct stat s;
  if (jfh_private(fd, 0) < 0 || fstat(fd, &s) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  if (s.st_size < 0 || (uint64_t)s.st_size > limit) {
    close(fd);
    errno = EFBIG;
    return -1;
  }
  *text = malloc((size_t)limit + 1);
  if (!*text) {
    close(fd);
    errno = ENOMEM;
    return -1;
  }
  // Read one byte past the limit so growth after the fstat is detected.
  size_t used = 0;
  while (used <= limit) {
    ssize_t got = read(fd, *text + used, (size_t)limit + 1 - used);
    if (got < 0 && errno == EINTR) {
      continue;
    }
    if (got < 0) {
      int saved = errno;
      close(fd);
      errno = saved;
      return -1;
    }
    if (!got) {
      break;
    }
    used += (size_t)got;
  }
  close(fd);
  if (used > limit) {
    errno = EFBIG;
    return -1;
  }
  *length = used;
  return 0;
}

// Replace `name` via a fsynced exclusive temp file and rename.
static int jfh_atomic(int dir, const char *name, const char *text, size_t length) {
  struct stat s;
  if (fstatat(dir, name, &s, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(s.st_mode) || s.st_uid != geteuid() || (s.st_mode & 077) || s.st_nlink != 1) {
      errno = EPERM;
      return -1;
    }
  } else if (errno != ENOENT) {
    return -1;
  }
  char random[JFH_ID_LEN + 1];
  char temp[40];
  if (jfh_random(random) < 0) {
    return -1;
  }
  snprintf(temp, sizeof temp, ".%s.tmp", random);
  int fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    return -1;
  }
  size_t used = 0;
  int result = -1;
  while (used < length) {
    ssize_t put = write(fd, text + used, length - used);
    if (put < 0 && errno == EINTR) {
      continue;
    }
    if (put <= 0) {
      goto end;
    }
    used += (size_t)put;
  }
  if (fsync(fd) < 0 || renameat(dir, temp, dir, name) < 0 || fsync(dir) < 0) {
    goto end;
  }
  result = 0;
end:;
  int saved = errno;
  close(fd);
  unlinkat(dir, temp, 0);
  errno = saved;
  return result;
}

static int jfh_answer(jfh_request *req, const char *text, size_t length) {
  req->result = malloc(length + 1);
  if (!req->result) {
    errno = ENOMEM;
    return -1;
  }
  memcpy(req->result, text, length);
  req->result[length] = 0;
  req->result_len = length;
  return 0;
}

// Holds an exclusive advisory lock on an owned descriptor, retrying signals.
static int jfh_lock(int fd, int how) {
  while (flock(fd, how) < 0) {
    if (errno != EINTR) {
      return -1;
    }
  }
  return 0;
}

static int jfh_write_all(int fd, const char *text, size_t length) {
  size_t used = 0;
  while (used < length) {
    ssize_t put = write(fd, text + used, length - used);
    if (put < 0 && errno == EINTR) {
      continue;
    }
    if (put <= 0) {
      if (!put) {
        errno = EIO;
      }
      return -1;
    }
    used += (size_t)put;
  }
  return 0;
}

/* The private input queue of an interactive job: `input.queue` holds bytes
 * not yet handed to the child, `input.closed` records end of input. Both are
 * changed only under an exclusive lock on the queue file, so writers and the
 * draining worker see one order. Bytes are opaque here; bounds come from Bend. */
static int jfh_queue_open(int dir) {
  int fd = openat(dir, "input.queue", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    return -1;
  }
  if (jfh_private(fd, 0) < 0 || jfh_lock(fd, LOCK_EX) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

static int jfh_queue_closed(int dir) {
  struct stat s;
  return fstatat(dir, "input.closed", &s, AT_SYMLINK_NOFOLLOW) == 0;
}

// Appends text unless input is closed (EPIPE) or the queue would pass `limit`
// bytes (ENOSPC). A name of "close" also ends input after the text.
static int jfh_enqueue(jfh_request *req, int dir) {
  int close_after = !strcmp(req->name, "close");
  if (!close_after && req->name[0]) {
    errno = EINVAL;
    return -1;
  }
  int fd = jfh_queue_open(dir);
  if (fd < 0) {
    return -1;
  }
  int rc = -1;
  struct stat s;
  if (jfh_queue_closed(dir)) {
    errno = EPIPE;
  } else if (fstat(fd, &s) < 0) {
    // errno is set.
  } else if ((uint64_t)s.st_size + req->text_len > req->limit) {
    errno = ENOSPC;
  } else if (lseek(fd, 0, SEEK_END) >= 0 && jfh_write_all(fd, req->text, req->text_len) == 0) {
    if (close_after) {
      int mark = openat(dir, "input.closed", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
      if (mark >= 0) {
        close(mark);
      }
      rc = mark < 0 && errno != EEXIST ? -1 : 0;
    } else {
      rc = 0;
    }
    if (rc == 0) {
      char text[24];
      int length = snprintf(text, sizeof text, "%llu", (unsigned long long)s.st_size + req->text_len);
      rc = jfh_answer(req, text, (size_t)length);
    }
  }
  int saved = errno;
  close(fd);
  errno = saved;
  return rc;
}

// Takes every queued byte (at most `limit`), leaving the queue empty. The answer
// is "C" when input has ended, else "O", followed by the bytes.
static int jfh_dequeue(jfh_request *req, int dir) {
  int fd = jfh_queue_open(dir);
  if (fd < 0) {
    return -1;
  }
  int rc = -1;
  struct stat s;
  char *text = NULL;
  if (fstat(fd, &s) < 0) {
    // errno is set.
  } else if (s.st_size < 0 || (uint64_t)s.st_size > req->limit) {
    errno = EFBIG;
  } else if (!(text = malloc((size_t)s.st_size + 2))) {
    errno = ENOMEM;
  } else {
    size_t used = 0;
    text[used++] = jfh_queue_closed(dir) ? 'C' : 'O';
    size_t want = (size_t)s.st_size + 1;
    while (used < want) {
      ssize_t got = pread(fd, text + used, want - used, (off_t)(used - 1));
      if (got < 0 && errno == EINTR) {
        continue;
      }
      if (got <= 0) {
        break;
      }
      used += (size_t)got;
    }
    if (used == want && ftruncate(fd, 0) == 0) {
      req->result = text;
      req->result_len = used;
      text = NULL;
      rc = 0;
    } else if (used != want) {
      errno = EIO;
    }
  }
  int saved = errno;
  free(text);
  close(fd);
  errno = saved;
  return rc;
}

/* Deletes one job-shaped directory and the plain files directly inside it,
 * unless a live worker still holds its lease. Used for session children, which
 * nothing can address once their owner has ended. */
static int jfh_remove(jfh_request *req) {
  if (!jfh_id(req->id)) {
    errno = EINVAL;
    return -1;
  }
  int root = jfh_root();
  if (root < 0) {
    return -1;
  }
  int rc = -1;
  int dir = openat(root, req->id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int lease = -1;
  DIR *entries = NULL;
  if (dir < 0 || jfh_private(dir, 1) < 0) {
    goto done;
  }
  lease = openat(dir, ".lease", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) < 0) {
    errno = errno == EWOULDBLOCK || errno == EAGAIN ? EBUSY : errno;
    goto done;
  }
  int copy = fcntl(dir, F_DUPFD_CLOEXEC, 3);
  if (copy < 0 || !(entries = fdopendir(copy))) {
    if (copy >= 0) {
      close(copy);
    }
    goto done;
  }
  struct dirent *ent;
  while ((ent = readdir(entries))) {
    if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) {
      continue;
    }
    struct stat st;
    if (fstatat(dir, ent->d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && !S_ISDIR(st.st_mode)) {
      unlinkat(dir, ent->d_name, 0);
    }
  }
  rc = unlinkat(root, req->id, AT_REMOVEDIR);
done:;
  int saved = errno;
  if (entries) {
    closedir(entries);
  }
  if (lease >= 0) {
    close(lease);
  }
  if (dir >= 0) {
    close(dir);
  }
  close(root);
  errno = saved;
  return rc;
}

static const char *jfh_platform(void) {
#if defined(__APPLE__)
#define JFH_OS "darwin"
#elif defined(__linux__)
#define JFH_OS "linux"
#else
#define JFH_OS "unknown"
#endif
#if defined(__aarch64__) || defined(__arm64__)
  return JFH_OS "-arm64";
#elif defined(__x86_64__)
  return JFH_OS "-x64";
#else
  return JFH_OS "-unknown";
#endif
}

// "+" when this call created the root, else "=", then the store marker or nothing.
static int jfh_store(jfh_request *req) {
  int made = 0;
  int root = jfh_root_made(&made);
  if (root < 0) {
    return -1;
  }
  char *text = NULL;
  size_t length = 0;
  // A marker being adopted has a second link for an instant; read it again.
  int rc = -1;
  for (int attempt = 0; attempt < 20; attempt++) {
    rc = jfh_read_file(root, JFH_STORE_NAME, JFH_STORE_MAX, &text, &length);
    if (rc == 0 || errno != EPERM) {
      break;
    }
    free(text);
    text = NULL;
    usleep(1000);
  }
  int saved = errno;
  close(root);
  if (rc < 0) {
    free(text);
    errno = saved;
    return -1;
  }
  req->result = malloc(length + 2);
  if (!req->result) {
    free(text);
    errno = ENOMEM;
    return -1;
  }
  req->result[0] = made ? '+' : '=';
  if (length) {
    memcpy(req->result + 1, text, length);
  }
  req->result[length + 1] = 0;
  req->result_len = length + 1;
  free(text);
  return 0;
}

/* Writes the store marker only if none exists, atomically and owner-only: a
 * fsynced temp file is linked into place, which fails rather than replace a
 * marker another process wrote first. Answers "written" or "exists". */
static int jfh_adopt(jfh_request *req) {
  int root = jfh_root();
  if (root < 0) {
    return -1;
  }
  char random[JFH_ID_LEN + 1];
  char temp[40];
  int rc = -1;
  int fd = -1;
  if (jfh_random(random) < 0) {
    goto done;
  }
  snprintf(temp, sizeof temp, ".%s.tmp", random);
  fd = openat(root, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    goto done;
  }
  if (jfh_write_all(fd, req->text, req->text_len) < 0 || fsync(fd) < 0) {
    goto done;
  }
  if (linkat(root, temp, root, JFH_STORE_NAME, 0) < 0) {
    if (errno == EEXIST) {
      rc = jfh_answer(req, "exists", 6);
    }
    goto done;
  }
  unlinkat(root, temp, 0);
  rc = fsync(root) < 0 ? -1 : jfh_answer(req, "written", 7);
done:;
  int saved = errno;
  if (fd >= 0) {
    close(fd);
    unlinkat(root, temp, 0);
  }
  close(root);
  errno = saved;
  return rc;
}

static void *jfh_reap(void *value) {
  pid_t pid = (pid_t)(intptr_t)value;
  while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
  return NULL;
}

static int jfh_spawn_process(jfh_request *req) {
  if (!req->argc || req->argv[0][0] != '/') {
    errno = EINVAL;
    return -1;
  }
  posix_spawn_file_actions_t actions;
  int rc = posix_spawn_file_actions_init(&actions);
  if (rc) {
    errno = rc;
    return -1;
  }
  for (int fd = 0; fd < 3 && !rc; fd++) {
    int mode = fd ? O_WRONLY : O_RDONLY;
    rc = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", mode, 0);
  }
  pid_t pid;
  if (!rc) {
    rc = posix_spawn(&pid, req->argv[0], &actions, NULL, req->argv, environ);
  }
  posix_spawn_file_actions_destroy(&actions);
  if (rc) {
    errno = rc;
    return -1;
  }
  pthread_t thread;
  /* Reap while the launcher lives; after its exit the OS adopts the worker.
   * Failure to allocate a reaper does not invalidate a successfully spawned job. */
  if (!pthread_create(&thread, NULL, jfh_reap, (void *)(intptr_t)pid)) {
    pthread_detach(thread);
  }
  return 0;
}

/* Names only: ids of private, no-follow job-shaped directories, one per line.
 * `limit` bounds the answer; one extra id lets the caller disclose truncation.
 * Whether a directory holds a job, and its state, is decided in Bend. */
static int jfh_list(jfh_request *req) {
  if (!req->limit || req->limit >= JFH_JOBS_MAX) {
    errno = EINVAL;
    return -1;
  }
  int dir = jfh_root();
  if (dir < 0) {
    return -1;
  }
  int copy = fcntl(dir, F_DUPFD_CLOEXEC, 3);
  if (copy < 0) {
    int saved = errno;
    close(dir);
    errno = saved;
    return -1;
  }
  DIR *entries = fdopendir(copy);
  if (!entries) {
    int saved = errno;
    close(copy);
    close(dir);
    errno = saved;
    return -1;
  }
  size_t wanted = (size_t)req->limit + 1;
  char *out = malloc(wanted * (JFH_ID_LEN + 1) + 1);
  if (!out) {
    closedir(entries);
    close(dir);
    errno = ENOMEM;
    return -1;
  }
  size_t used = 0;
  size_t found = 0;
  int failed = 0;
  while (found < wanted) {
    errno = 0;
    struct dirent *ent = readdir(entries);
    if (!ent) {
      failed = errno;
      break;
    }
    if (!jfh_id(ent->d_name)) {
      continue;
    }
    int job = openat(dir, ent->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (job < 0) {
      continue;
    }
    int private = jfh_private(job, 1) == 0;
    close(job);
    if (!private) {
      continue;
    }
    memcpy(out + used, ent->d_name, JFH_ID_LEN);
    used += JFH_ID_LEN;
    out[used++] = '\n';
    found++;
  }
  closedir(entries);
  close(dir);
  if (failed) {
    free(out);
    errno = failed;
    return -1;
  }
  req->result = out;
  req->result_len = used;
  return 0;
}

static void jfh_call(IoWork *w) {
  jfh_request *req = (jfh_request *)w->data;
  int dir = -1;
  int fd = -1;
  int rc = -1;
  if (req->op == JFH_SELF) {
    char path[PATH_MAX];
    char resolved[PATH_MAX];
#ifdef __APPLE__
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) {
      errno = ENAMETOOLONG;
      goto end;
    }
#else
    ssize_t n = readlink("/proc/self/exe", path, sizeof path - 1);
    if (n < 0) {
      goto end;
    }
    if ((size_t)n == sizeof path - 1) {
      errno = ENAMETOOLONG;
      goto end;
    }
    path[n] = 0;
#endif
    if (!realpath(path, resolved)) {
      goto end;
    }
    req->result = strdup(resolved);
    req->result_len = strlen(resolved);
    rc = req->result ? 0 : -1;
  } else if (req->op == JFH_CREATE) {
    // `limit` is the maximum number of job directories under the root.
    if (!req->limit || req->limit > JFH_JOBS_MAX) {
      errno = EINVAL;
      goto end;
    }
    dir = jfh_root();
    if (dir < 0 || flock(dir, LOCK_EX) < 0) {
      goto end;
    }
    int copy = fcntl(dir, F_DUPFD_CLOEXEC, 3);
    if (copy < 0) {
      goto end;
    }
    DIR *entries = fdopendir(copy);
    if (!entries) {
      close(copy);
      goto end;
    }
    unsigned count = 0;
    struct dirent *ent;
    while (count < req->limit && (ent = readdir(entries))) {
      // Hidden entries (.gitignore, the store marker, temp files) are not job directories.
      if (ent->d_name[0] != '.') {
        count++;
      }
    }
    closedir(entries);
    if (count >= req->limit) {
      errno = ENOSPC;
      goto end;
    }
    char id[JFH_ID_LEN + 1];
    if (jfh_random(id) < 0 || mkdirat(dir, id, 0700) < 0 || fsync(dir) < 0) {
      goto end;
    }
    req->result = strdup(id);
    req->result_len = JFH_ID_LEN;
    rc = req->result ? 0 : -1;
  } else if (req->op == JFH_SPAWN) {
    rc = jfh_spawn_process(req);
  } else if (req->op == JFH_LIST) {
    rc = jfh_list(req);
  } else if (req->op == JFH_PARENT) {
    char text[24];
    int length = snprintf(text, sizeof text, "%ld", (long)getppid());
    rc = jfh_answer(req, text, (size_t)length);
  } else if (req->op == JFH_REMOVE) {
    rc = jfh_remove(req);
  } else if (req->op == JFH_PLATFORM) {
    const char *name = jfh_platform();
    rc = jfh_answer(req, name, strlen(name));
  } else if (req->op == JFH_DIRECTORY) {
    // `text` is an absolute path that must name an existing directory.
    struct stat st;
    if (!req->text_len || req->text[0] != '/' || req->text_len > JFH_PATH_MAX) {
      errno = EINVAL;
      goto end;
    }
    if (stat(req->text, &st) < 0) {
      goto end;
    }
    if (!S_ISDIR(st.st_mode)) {
      errno = ENOTDIR;
      goto end;
    }
    rc = jfh_answer(req, "1", 1);
  } else if (req->op == JFH_STORE) {
    rc = jfh_store(req);
  } else if (req->op == JFH_ADOPT) {
    rc = jfh_adopt(req);
  } else if (req->op == JFH_CLOCK) {
    struct timespec now;
    char text[24];
    if (clock_gettime(CLOCK_REALTIME, &now) < 0) {
      goto end;
    }
    unsigned long long ms = (unsigned long long)now.tv_sec * 1000ull
      + (unsigned long long)(now.tv_nsec / 1000000);
    int length = snprintf(text, sizeof text, "%llu", ms);
    req->result = strdup(text);
    req->result_len = (size_t)length;
    rc = req->result ? 0 : -1;
  } else {
    dir = jfh_dir(req->id);
    if (dir < 0) {
      goto end;
    }
    if (req->op == JFH_SPOOL) {
      if (!jfh_leaf(req->name)) {
        errno = EINVAL;
        goto end;
      }
      // For spool, a nonzero `limit` means "create the writer".
      int mode = req->limit ? (O_WRONLY | O_CREAT | O_EXCL) : O_RDONLY;
      fd = openat(dir, req->name, O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | mode, 0600);
      if (fd < 0 || jfh_private(fd, 0) < 0) {
        goto end;
      }
      req->opened = fd;
      fd = -1;
      rc = 0;
    } else if (req->op == JFH_ENQUEUE) {
      rc = jfh_enqueue(req, dir);
    } else if (req->op == JFH_DEQUEUE) {
      rc = jfh_dequeue(req, dir);
    } else if (req->op == JFH_READ || req->op == JFH_WRITE) {
      if (!jfh_leaf(req->name)) {
        errno = EINVAL;
        goto end;
      }
      if (req->op == JFH_READ) {
        rc = jfh_read_file(dir, req->name, req->limit, &req->result, &req->result_len);
      } else {
        rc = jfh_atomic(dir, req->name, req->text, req->text_len);
      }
    } else if (req->op == JFH_CLAIM || req->op == JFH_ALIVE) {
      fd = openat(dir, ".lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
      if (fd < 0 || jfh_private(fd, 0) < 0) {
        goto end;
      }
      if (req->op == JFH_CLAIM) {
        if (jfh_lease >= 0) {
          errno = EBUSY;
          goto end;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
          goto end;
        }
        // A worker its owner spawned into a group of its own already leads
        // that group and stays in the owner's session.
        if (setsid() < 0 && !(errno == EPERM && getpgrp() == getpid())) {
          goto end;
        }
        jfh_lease = fd;
        fd = -1;
        rc = 0;
      } else {
        int locked = flock(fd, LOCK_EX | LOCK_NB);
        if (locked < 0 && errno != EWOULDBLOCK && errno != EAGAIN) {
          goto end;
        }
        req->result = strdup(locked < 0 ? "1" : "0");
        req->result_len = 1;
        rc = req->result ? 0 : -1;
      }
    } else {
      errno = EINVAL;
    }
  }
end:
  w->code = rc < 0 ? (errno ? errno : EIO) : 0;
  if (fd >= 0) {
    close(fd);
  }
  if (dir >= 0) {
    close(dir);
  }
}

// Spool answers a File handle; every other operation answers a String.
static Term jfh_pack(Env e, IoWork *w) {
  jfh_request *req = (jfh_request *)w->data;
  Term result;
  if (w->code) {
    result = io_fail(e, w->code, "native private job operation failed");
  } else if (req->op == JFH_SPOOL) {
    result = io_done(e, io_hand(req->opened));
  } else {
    result = io_done(e, io_str(e, req->result ? req->result : "", req->result_len));
  }
  free(req->id);
  free(req->name);
  free(req->text);
  free(req->result);
  for (size_t i = 0; i < req->argc; i++) {
    free(req->argv[i]);
  }
  free(req);
  return result;
}

Term jfh_os_run(Env e, Term *f, IoWork *w) {
  jfh_request *req = io_mem(calloc(1, sizeof *req));
  w->data = (char *)req;
  w->code = 0;
  req->op = (u32)f[0];
  req->limit = (u32)f[5];
  u64 id_len;
  u64 name_len;
  u64 text_len;
  req->id = io_cstr(e, f[1], &id_len);
  req->name = io_cstr(e, f[2], &name_len);
  req->text = io_cstr(e, f[3], &text_len);
  req->text_len = (size_t)text_len;
  if (req->op == JFH_SPOOL || req->op > JFH_ADOPT || id_len > JFH_ID_LEN || name_len > JFH_LEAF_MAX
      || text_len > JFH_TEXT_MAX || req->limit > JFH_TEXT_MAX
      || io_nul(req->id, id_len) || io_nul(req->name, name_len)) {
    w->code = EINVAL;
  }
  Term args = f[4];
  while (term_aux(args) == CID(Con)) {
    Term fields[2];
    spare_free(e, cls_fit(2), ctr_take(e, args, 2, fields));
    u64 length;
    char *arg = io_cstr(e, fields[0], &length);
    if (req->argc == JFH_ARGS || length > JFH_ARG_BYTES || io_nul(arg, length)) {
      w->code = EINVAL;
      free(arg);
    } else {
      req->argv[req->argc++] = arg;
    }
    args = fields[1];
  }
  return w->code ? jfh_pack(e, w) : io_work(w, jfh_call, jfh_pack);
}

Term jfh_spool_run(Env e, Term *f, IoWork *w) {
  jfh_request *req = io_mem(calloc(1, sizeof *req));
  w->data = (char *)req;
  w->code = 0;
  req->op = JFH_SPOOL;
  req->limit = term_aux(f[2]) == CID(True);
  u64 id_len;
  u64 name_len;
  req->id = io_cstr(e, f[0], &id_len);
  req->name = io_cstr(e, f[1], &name_len);
  if (id_len > JFH_ID_LEN || name_len > JFH_LEAF_MAX
      || io_nul(req->id, id_len) || io_nul(req->name, name_len)) {
    w->code = EINVAL;
  }
  return w->code ? jfh_pack(e, w) : io_work(w, jfh_call, jfh_pack);
}

static void __attribute__((constructor)) jfh_os_use(void) {
#ifdef CID(jfh_os)
  io_eff(CID(jfh_os), jfh_os_run, 0);
#endif
#ifdef CID(jfh_spool)
  io_eff(CID(jfh_spool), jfh_spool_run, 0);
#endif
}
