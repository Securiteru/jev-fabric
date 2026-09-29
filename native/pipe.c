// Native.pipe
//
// One CLOEXEC pipe, both ends returned as Base File handles. The caller owns
// each descriptor exactly once: hand an end to Native.exec_pipe or close it
// with File.close. CLOEXEC keeps the pair out of unrelated children.

#ifdef CID(Native.pipe)

Term native_pipe_run(Env e, Term* f, IoWork* w) {
  int fds[2];
  if (pipe(fds) < 0) return io_fail(e, errno, NULL);
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
    int saved = errno;
    close(fds[0]);
    close(fds[1]);
    return io_fail(e, saved, NULL);
  }
  return io_done(e, io_tup(e, io_hand(fds[0]), io_hand(fds[1])));
}

static void __attribute__((constructor)) native_pipe_use(void) {
  io_eff(CID(Native.pipe), native_pipe_run, 0);
}

#endif

// Native.stdin
//
// A CLOEXEC duplicate of fd 0 as a Base File handle. Reopening /dev/stdin fails
// on Linux when fd 0 is a socket (Node, Bun and libuv give children socketpairs),
// so readers duplicate the descriptor instead. File.close closes the duplicate
// only; fd 0 stays open.

#ifdef CID(Native.stdin)

Term native_stdin_run(Env e, Term* f, IoWork* w) {
  int fd = fcntl(0, F_DUPFD_CLOEXEC, 3);
  if (fd < 0) return io_fail(e, errno, NULL);
  return io_done(e, io_hand(fd));
}

static void __attribute__((constructor)) native_stdin_use(void) {
  io_eff(CID(Native.stdin), native_stdin_run, 0);
}

#endif
