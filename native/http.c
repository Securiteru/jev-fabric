#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Pooled HTTPS POST through the system libcurl, loaded at runtime so builds need
// neither curl headers nor a link flag. One process-wide share keeps the DNS,
// TLS-session and connection caches, so successive Jev calls reuse a warm
// connection instead of paying a fresh TLS handshake each time.
//
// The policy matches the curl executable path in HttpCore.argv: HTTPS only, no
// redirects, no proxies (environment proxies are ignored), verified TLS peer and
// hostname, a 1 MiB body bound, no netrc, no retries. As with the curl tool,
// CURL_CA_BUNDLE may name the trust anchors. The key only ever lives in this
// process's memory; request buffers holding it are zeroed before release.

#define JH_BODY_LIMIT 1048576
#define JH_URL_MAX 4096
#define JH_KEY_MAX 16384
#define JH_CONNECT_TIMEOUT_MS 10000
#define JH_TIMEOUT_MAX_MS 3600000
// Result code for "libcurl could not be loaded": HttpCore may fall back to curl.
#define JH_UNAVAILABLE 1000000u

// ABI-stable libcurl constants (curl/curl.h), spelled out because only the
// shared library, not its headers, is a runtime dependency.
enum {
  JH_OPT_WRITEDATA = 10001,
  JH_OPT_URL = 10002,
  JH_OPT_PROXY = 10004,
  JH_OPT_POSTFIELDS = 10015,
  JH_OPT_HTTPHEADER = 10023,
  JH_OPT_CAINFO = 10065,
  JH_OPT_SHARE = 10100,
  JH_OPT_NOPROXY = 10177,
  JH_OPT_PROTOCOLS_STR = 10318,
  JH_OPT_REDIR_PROTOCOLS_STR = 10319,
  JH_OPT_WRITEFUNCTION = 20011,
  JH_OPT_XFERINFOFUNCTION = 20219,
  JH_OPT_XFERINFODATA = 10057,
  JH_OPT_NOPROGRESS = 43,
  JH_OPT_POST = 47,
  JH_OPT_NETRC = 51,
  JH_OPT_FOLLOWLOCATION = 52,
  JH_OPT_SSL_VERIFYPEER = 64,
  JH_OPT_SSL_VERIFYHOST = 81,
  JH_OPT_NOSIGNAL = 99,
  JH_OPT_TIMEOUT_MS = 155,
  JH_OPT_CONNECTTIMEOUT_MS = 156,
  JH_OPT_MAXFILESIZE_LARGE = 30117,
  JH_OPT_POSTFIELDSIZE_LARGE = 30120,
  JH_INFO_RESPONSE_CODE = 0x200002,
  JH_GLOBAL_DEFAULT = 3,
  JH_SHOPT_SHARE = 1,
  JH_SHOPT_LOCKFUNC = 3,
  JH_SHOPT_UNLOCKFUNC = 4,
  JH_LOCK_DNS = 3,
  JH_LOCK_SSL_SESSION = 4,
  JH_LOCK_CONNECT = 5,
  JH_LOCKS = 8,
};

typedef void JhHandle;
typedef struct JhList JhList;
typedef size_t (*JhWrite)(char *, size_t, size_t, void *);
typedef int (*JhProgress)(void *, long long, long long, long long, long long);
typedef void (*JhLock)(JhHandle *, int, int, void *);
typedef void (*JhUnlock)(JhHandle *, int, void *);

static struct {
  int (*global_init)(long);
  JhHandle *(*easy_init)(void);
  int (*easy_setopt)(JhHandle *, int, ...);
  int (*easy_perform)(JhHandle *);
  int (*easy_getinfo)(JhHandle *, int, ...);
  void (*easy_cleanup)(JhHandle *);
  JhList *(*slist_append)(JhList *, const char *);
  void (*slist_free_all)(JhList *);
  JhHandle *(*share_init)(void);
  int (*share_setopt)(JhHandle *, int, ...);
} jh_curl;

static pthread_once_t jh_once = PTHREAD_ONCE_INIT;
static int jh_ready;
static JhHandle *jh_share;
static pthread_mutex_t jh_locks[JH_LOCKS];

// posix.c records SIGINT/SIGTERM and Process.cancel; an interrupted scope
// aborts in-flight transfers the same way it stops owned child processes.
int jf_interrupted(void);

static void jh_lock(JhHandle *handle, int data, int access, void *user) {
  (void)handle;
  (void)access;
  (void)user;
  pthread_mutex_lock(&jh_locks[data % JH_LOCKS]);
}

static void jh_unlock(JhHandle *handle, int data, void *user) {
  (void)handle;
  (void)user;
  pthread_mutex_unlock(&jh_locks[data % JH_LOCKS]);
}

static void *jh_symbol(void *library, const char *name, int *missing) {
  void *symbol = dlsym(library, name);
  if (!symbol) {
    *missing = 1;
  }
  return symbol;
}

static void jh_load(void) {
  static const char *const names[] = {"libcurl.4.dylib", "libcurl.so.4", "libcurl.so"};
  void *library = NULL;
  for (size_t i = 0; i < sizeof names / sizeof *names && !library; i++) {
    library = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
  }
  if (!library) {
    return;
  }
  int missing = 0;
  *(void **)&jh_curl.global_init = jh_symbol(library, "curl_global_init", &missing);
  *(void **)&jh_curl.easy_init = jh_symbol(library, "curl_easy_init", &missing);
  *(void **)&jh_curl.easy_setopt = jh_symbol(library, "curl_easy_setopt", &missing);
  *(void **)&jh_curl.easy_perform = jh_symbol(library, "curl_easy_perform", &missing);
  *(void **)&jh_curl.easy_getinfo = jh_symbol(library, "curl_easy_getinfo", &missing);
  *(void **)&jh_curl.easy_cleanup = jh_symbol(library, "curl_easy_cleanup", &missing);
  *(void **)&jh_curl.slist_append = jh_symbol(library, "curl_slist_append", &missing);
  *(void **)&jh_curl.slist_free_all = jh_symbol(library, "curl_slist_free_all", &missing);
  *(void **)&jh_curl.share_init = jh_symbol(library, "curl_share_init", &missing);
  *(void **)&jh_curl.share_setopt = jh_symbol(library, "curl_share_setopt", &missing);
  if (missing || jh_curl.global_init(JH_GLOBAL_DEFAULT) != 0) {
    return;
  }
  for (int i = 0; i < JH_LOCKS; i++) {
    pthread_mutex_init(&jh_locks[i], NULL);
  }
  jh_share = jh_curl.share_init();
  if (!jh_share
      || jh_curl.share_setopt(jh_share, JH_SHOPT_LOCKFUNC, (JhLock)jh_lock)
      || jh_curl.share_setopt(jh_share, JH_SHOPT_UNLOCKFUNC, (JhUnlock)jh_unlock)
      || jh_curl.share_setopt(jh_share, JH_SHOPT_SHARE, (long)JH_LOCK_DNS)
      || jh_curl.share_setopt(jh_share, JH_SHOPT_SHARE, (long)JH_LOCK_SSL_SESSION)
      || jh_curl.share_setopt(jh_share, JH_SHOPT_SHARE, (long)JH_LOCK_CONNECT)) {
    return;
  }
  jh_ready = 1;
}

typedef struct {
  char *url;
  char *key;
  char *body;
  u64 url_len;
  u64 key_len;
  u64 body_len;
  u32 timeout;
  u32 unavailable;
  long status;
  char *out;
  size_t out_len;
} JhPost;

static void jh_scrub(char *text, size_t length) {
  if (text) {
    volatile char *bytes = text;
    for (size_t i = 0; i < length; i++) {
      bytes[i] = 0;
    }
  }
  free(text);
}

// Stops the transfer (curl reports a write error) instead of truncating.
static size_t jh_write(char *data, size_t size, size_t count, void *user) {
  JhPost *post = user;
  size_t length = size * count;
  if (length > JH_BODY_LIMIT - post->out_len) {
    return 0;
  }
  memcpy(post->out + post->out_len, data, length);
  post->out_len += length;
  return length;
}

static int jh_progress(void *user, long long dltotal, long long dlnow, long long ultotal, long long ulnow) {
  (void)user;
  (void)dltotal;
  (void)dlnow;
  (void)ultotal;
  (void)ulnow;
  return jf_interrupted() ? 1 : 0;
}

static int jh_configure(JhHandle *easy, JhPost *post, JhList *headers, long timeout_ms) {
  const char *ca_bundle = getenv("CURL_CA_BUNDLE");
  long connect_ms = timeout_ms < JH_CONNECT_TIMEOUT_MS ? timeout_ms : JH_CONNECT_TIMEOUT_MS;
  return jh_curl.easy_setopt(easy, JH_OPT_SHARE, jh_share)
    || jh_curl.easy_setopt(easy, JH_OPT_URL, post->url)
    || jh_curl.easy_setopt(easy, JH_OPT_PROTOCOLS_STR, "https")
    || jh_curl.easy_setopt(easy, JH_OPT_REDIR_PROTOCOLS_STR, "https")
    || jh_curl.easy_setopt(easy, JH_OPT_FOLLOWLOCATION, 0L)
    || jh_curl.easy_setopt(easy, JH_OPT_PROXY, "")
    || jh_curl.easy_setopt(easy, JH_OPT_NOPROXY, "*")
    || jh_curl.easy_setopt(easy, JH_OPT_NETRC, 0L)
    || jh_curl.easy_setopt(easy, JH_OPT_SSL_VERIFYPEER, 1L)
    || jh_curl.easy_setopt(easy, JH_OPT_SSL_VERIFYHOST, 2L)
    || (ca_bundle && ca_bundle[0] && jh_curl.easy_setopt(easy, JH_OPT_CAINFO, ca_bundle))
    || jh_curl.easy_setopt(easy, JH_OPT_NOSIGNAL, 1L)
    || jh_curl.easy_setopt(easy, JH_OPT_CONNECTTIMEOUT_MS, connect_ms)
    || jh_curl.easy_setopt(easy, JH_OPT_TIMEOUT_MS, timeout_ms)
    || jh_curl.easy_setopt(easy, JH_OPT_MAXFILESIZE_LARGE, (long long)JH_BODY_LIMIT)
    || jh_curl.easy_setopt(easy, JH_OPT_POST, 1L)
    || jh_curl.easy_setopt(easy, JH_OPT_POSTFIELDS, post->body)
    || jh_curl.easy_setopt(easy, JH_OPT_POSTFIELDSIZE_LARGE, (long long)post->body_len)
    || jh_curl.easy_setopt(easy, JH_OPT_HTTPHEADER, headers)
    || jh_curl.easy_setopt(easy, JH_OPT_WRITEFUNCTION, (JhWrite)jh_write)
    || jh_curl.easy_setopt(easy, JH_OPT_WRITEDATA, post)
    || jh_curl.easy_setopt(easy, JH_OPT_NOPROGRESS, 0L)
    || jh_curl.easy_setopt(easy, JH_OPT_XFERINFOFUNCTION, (JhProgress)jh_progress)
    || jh_curl.easy_setopt(easy, JH_OPT_XFERINFODATA, post);
}

// Runs on a helper thread: touches only the request, never Bend terms.
static void jh_post_call(IoWork *w) {
  JhPost *post = (JhPost *)w->data;
  pthread_once(&jh_once, jh_load);
  if (!jh_ready) {
    post->unavailable = 1;
    return;
  }
  if (jf_interrupted()) {
    w->code = EINTR;
    return;
  }
  static const char prefix[] = "Authorization: Bearer ";
  size_t auth_len = sizeof prefix + post->key_len;
  char *auth = malloc(auth_len);
  post->out = malloc(JH_BODY_LIMIT);
  JhHandle *easy = jh_curl.easy_init();
  JhList *headers = NULL;
  if (!auth || !post->out || !easy) {
    w->code = ENOMEM;
  } else {
    memcpy(auth, prefix, sizeof prefix - 1);
    memcpy(auth + sizeof prefix - 1, post->key, post->key_len);
    auth[auth_len - 1] = 0;
    // An empty Expect header stops libcurl waiting for 100-continue.
    JhList *list = jh_curl.slist_append(NULL, "Content-Type: application/json");
    headers = list ? jh_curl.slist_append(list, "Expect:") : NULL;
    headers = headers ? jh_curl.slist_append(headers, auth) : NULL;
    if (!headers) {
      if (list) {
        jh_curl.slist_free_all(list);
      }
      w->code = ENOMEM;
    } else if (jh_configure(easy, post, headers, (long)post->timeout)) {
      w->code = EINVAL;
    } else if (jh_curl.easy_perform(easy) != 0) {
      w->code = EIO;
    } else if (jh_curl.easy_getinfo(easy, JH_INFO_RESPONSE_CODE, &post->status) != 0) {
      w->code = EIO;
    }
  }
  if (easy) {
    jh_curl.easy_cleanup(easy);
  }
  if (headers) {
    jh_curl.slist_free_all(headers);
  }
  jh_scrub(auth, auth_len);
}

static Term jh_bytes(Env e, const char *data, size_t size) {
  Term bytes = term_pak(CID(Nil), 0);
  for (size_t i = size; i > 0; i--) {
    bytes = io_node(e, CID(Con), (uint8_t)data[i - 1], bytes);
  }
  return bytes;
}

// Packs (status, body) and releases every request buffer.
static Term jh_post_pack(Env e, IoWork *w) {
  JhPost *post = (JhPost *)w->data;
  Term result;
  if (post->unavailable) {
    result = io_fail(e, JH_UNAVAILABLE, "libcurl unavailable");
  } else if (w->code) {
    result = io_fail(e, w->code, "pooled HTTPS request failed");
  } else {
    Term body = jh_bytes(e, post->out, post->out_len);
    result = io_done(e, io_tup(e, (Term)(u32)post->status, body));
  }
  free(post->url);
  jh_scrub(post->key, post->key_len);
  jh_scrub(post->body, post->body_len);
  free(post->out);
  free(post);
  return result;
}

static int jh_https(const char *url, u64 length) {
  return length > 8 && length <= JH_URL_MAX && strncmp(url, "https://", 8) == 0;
}

#ifdef CID(Native.http_post)
Term native_http_post_run(Env e, Term *f, IoWork *w) {
  JhPost *post = io_mem(calloc(1, sizeof *post));
  w->data = (char *)post;
  w->code = 0;
  post->url = io_cstr(e, f[0], &post->url_len);
  post->key = io_cstr(e, f[1], &post->key_len);
  post->body = io_cstr(e, f[2], &post->body_len);
  post->timeout = (u32)f[3];
  if (!jh_https(post->url, post->url_len) || io_nul(post->url, post->url_len)
      || !post->key_len || post->key_len > JH_KEY_MAX || io_nul(post->key, post->key_len)
      || post->body_len > JH_BODY_LIMIT || io_nul(post->body, post->body_len)
      || !post->timeout || post->timeout > JH_TIMEOUT_MAX_MS) {
    w->code = EINVAL;
    return jh_post_pack(e, w);
  }
  return io_work(w, jh_post_call, jh_post_pack);
}

static void __attribute__((constructor)) native_http_post_use(void) {
  io_eff(CID(Native.http_post), native_http_post_run, 0);
}
#endif
