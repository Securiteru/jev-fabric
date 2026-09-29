import Base
import ./Json.bend as Json
import ./Streams.bend as Streams

# Pure policy for reading raw output by byte offset (`read`). Spool.bend performs
# the file reads and sleeps; nothing here touches a file or a clock.
#
# A batch spool keeps the first 1 MiB of a stream as plain bytes. A rolling spool
# (session children and interactive jobs) is a 16-byte header, the bytes written
# so far as a little-endian u64 and a u64 of flags (bit 0: the stream has ended),
# followed by a ring holding the latest 1 MiB: byte N lives at 16 + N mod 1 MiB.
# The writer stores bytes before it publishes the count that covers them.

# Bytes a rolling spool retains, and a batch spool's first-byte cap.
def ring() -> Nat:
  1048576n

def head_size() -> U32:
  16

# The most bytes one read returns.
def read_max() -> U32:
  65536

# ---------------------------------------------------------------------------
# Header.

type Head is Data:
  Head{count: Nat, closed: Bool}

# The little-endian number in the first `width` bytes.
def little(width: Nat, bytes: List<&2, U32>) -> Nat:
  match width bytes:
    case 0n _:
      0n
    case 1n+rest Nil{}:
      0n
    case 1n+rest Con{b, tail}:
      Nat.add(U32.to_nat(b), Nat.mul(256n, little(rest, tail)))

def flag_set(flags: List<&2, U32>) -> Bool:
  match flags:
    case Nil{}:
      False{}
    case Con{b, rest}:
      U32.is_ne((b .&. 1 : U32), 0)

def head_sized(+bytes: List<&2, U32>, complete: Bool) -> Head:
  match complete:
    case True{}:
      Head{little(8n, bytes), flag_set(List.drop(&2, U32, bytes, 8n))}
    case False{}:
      Head{0n, False{}}

# A header not yet written (a spool shorter than 16 bytes) reads as nothing written.
def head(+bytes: List<&2, U32>) -> Head:
  head_sized(bytes, Nat.is_ge(List.length(&2, U32, bytes), 16n))

def head_count(h: Head) -> Nat:
  match h:
    case Head{count, closed}:
      count

def head_closed(h: Head) -> Bool:
  match h:
    case Head{count, closed}:
      closed

# ---------------------------------------------------------------------------
# Which bytes a read returns.

# a - b, stopping at zero, taking b first so that `less(0n, a)` is `a`.
def less(b: Nat, a: Nat) -> Nat:
  match b a:
    case 0n _:
      a
    case 1n+bp 0n:
      0n
    case 1n+bp 1n+ap:
      less(bp, ap)

def minus(a: Nat, b: Nat) -> Nat:
  less(b, a)

# The larger of the requested offset and the oldest retained byte.
def from(offset: Nat, oldest: Nat) -> Nat:
  match offset oldest:
    case 0n _:
      oldest
    case 1n+q 0n:
      1n+q
    case 1n+q 1n+p:
      1n+from(q, p)

# The oldest byte a rolling spool still holds once `count` bytes were written.
def oldest(+count: Nat) -> Nat:
  minus(count, ring())

type Span is Data:
  Span{start: Nat, length: Nat, omitted: Nat}

# A read starts at the requested offset, or at the oldest retained byte when the
# offset lies below it, and discloses the difference as omitted. It returns at
# most `max` bytes and none past `count`, the bytes written so far.
def span(+retained: Nat, +count: Nat, +offset: Nat, max: Nat) -> Span:
  +start = from(offset, retained)
  Span{start, Nat.min(max, minus(count, start)), minus(start, offset)}

def span_start(s: Span) -> Nat:
  match s:
    case Span{start, length, omitted}:
      start

def span_length(s: Span) -> Nat:
  match s:
    case Span{start, length, omitted}:
      length

def span_omitted(s: Span) -> Nat:
  match s:
    case Span{start, length, omitted}:
      omitted

type Slice is Data:
  Slice{at: U32, length: U32}

def second_slice(+length: Nat) -> List<&2, Slice>:
  match length:
    case 0n:
      Nil{}
    case other:
      [Slice{head_size(), U32.from_nat(other)}]

# Where the span's bytes lie in a rolling spool: one read, or two when they wrap.
def slices(+start: Nat, +length: Nat) -> List<&2, Slice>:
  +at = Nat.mod(start, ring())
  +first = Nat.min(length, minus(ring(), at))
  Con{Slice{U32.from_nat(Nat.add(at, 16n)), U32.from_nat(first)}, second_slice(minus(length, first))}

# Bytes the writer may have overwritten while they were read: those below the
# oldest byte the header published after the read.
def overwritten(+start: Nat, +length: Nat, +after: Nat) -> Nat:
  Nat.min(length, minus(oldest(after), start))

# ---------------------------------------------------------------------------
# UTF-8: a partial character at the end of a read is held for the next one.

def continuation(+b: U32) -> Bool:
  U32.is_ge(b, 128) && U32.is_lt(b, 192)

# The sequence length a lead byte announces, or 0 for a byte that leads nothing.
def announced(+b: U32) -> U32:
  Bool.pick(U32, U32.is_lt(b, 192), 0,
    Bool.pick(U32, U32.is_lt(b, 224), 2,
      Bool.pick(U32, U32.is_lt(b, 240), 3,
        Bool.pick(U32, U32.is_lt(b, 248), 4, 0))))

def partial(+seen: U32, +needed: U32) -> U32:
  Bool.pick(U32, U32.is_gt(needed, seen), seen, 0)

# Walks back from the last byte over at most three continuation bytes to a lead.
def trailing(fuel: Nat, reversed: List<&2, U32>, +continued: U32) -> U32:
  match fuel reversed:
    case 0n _:
      0
    case 1n+left Nil{}:
      0
    case 1n+left Con{+b, rest}:
      Bool.pick(
        U32,
        continuation(b),
        trailing(left, rest, U32.inc(continued)),
        partial(U32.inc(continued), announced(b)),
      )

# How many trailing bytes form an incomplete character: 0 to 3.
def held(bytes: List<&2, U32>) -> U32:
  trailing(4n, List.reverse(&2, U32, bytes), 0)

# The bytes a read returns: all of them once the stream has ended, otherwise
# without a trailing partial character.
def kept(+bytes: List<&2, U32>, ended: Bool) -> List<&2, U32>:
  match ended:
    case True{}:
      bytes
    case False{}:
      List.take(&2, U32, bytes, minus(List.length(&2, U32, bytes), U32.to_nat(held(bytes))))

# ---------------------------------------------------------------------------
# Encodings.

def digit64(+i: U32) -> Char:
  Bool.pick(Char, U32.is_lt(i, 26), Chr{U32.add(i, 65)},
    Bool.pick(Char, U32.is_lt(i, 52), Chr{U32.add(i, 71)},
      Bool.pick(Char, U32.is_lt(i, 62), Chr{U32.sub(i, 4)},
        Bool.pick(Char, U32.is_eq(i, 62), '+', '/'))))

def sextet(+n: U32, shift: U32) -> Char:
  digit64(U32.mod(U32.div(n, shift), 64))

# Standard base64 with padding, byte-exact.
def base64(bytes: List<&2, U32>) -> String:
  match bytes:
    case Nil{}:
      ""
    case Con{a, Nil{}}:
      +n = U32.mul(a, 65536)
      SCon{sextet(n, 262144), SCon{sextet(n, 4096), "=="}}
    case Con{a, Con{b, Nil{}}}:
      +n = U32.add(U32.mul(a, 65536), U32.mul(b, 256))
      SCon{sextet(n, 262144), SCon{sextet(n, 4096), SCon{sextet(n, 64), "="}}}
    case Con{a, Con{b, Con{c, rest}}}:
      +n = U32.add(U32.add(U32.mul(a, 65536), U32.mul(b, 256)), c)
      SCon{sextet(n, 262144), SCon{sextet(n, 4096), SCon{sextet(n, 64), SCon{sextet(n, 1), base64(rest)}}}}

def text(bytes: List<&2, U32>) -> String:
  Streams.finish(Streams.feed(bytes, Streams.empty()))

# `"text":…` decoded (malformed bytes become U+FFFD), or `"data":…` in base64.
def payload(bytes: List<&2, U32>, encoded: Bool) -> String:
  match encoded:
    case True{}:
      "\"data\":" ++ Json.quote(base64(bytes))
    case False{}:
      "\"text\":" ++ Json.quote(text(bytes))

# ---------------------------------------------------------------------------
# The read record.

type Read is Data:
  Read{
    id: String,
    stream: String,
    start: Nat,
    omitted: Nat,
    bytes: List<&2, U32>,
    eof: Bool,
    state: String,
  }

def record(read: Read, encoded: Bool) -> String:
  match read:
    case Read{id, stream, +start, omitted, +bytes, eof, state}:
      +count = List.length(&2, U32, bytes)
      "{\"id\":" ++ Json.quote(id)
        ++ ",\"stream\":" ++ Json.quote(stream)
        ++ ",\"offset\":" ++ Nat.show(start)
        ++ ",\"bytes\":" ++ Nat.show(count)
        ++ ",\"omittedBytes\":" ++ Nat.show(omitted)
        ++ "," ++ payload(bytes, encoded)
        ++ ",\"next\":" ++ Nat.show(Nat.add(start, count))
        ++ ",\"eof\":" ++ Json.boolean(eof)
        ++ ",\"state\":" ++ Json.quote(state)
        ++ "}"

# A stream has ended when its writer has finished and nothing past `next` remains.
def ended(finished: Bool, +next: Nat, +count: Nat) -> Bool:
  finished && Nat.is_ge(next, count)

# A long poll answers once bytes past the offset can be returned, the stream has
# ended, or its ceiling has passed.
def answer_now(expired: Bool, returned: Bool, eof: Bool) -> Bool:
  expired || returned || eof

# Poll quickly at first, when a reply is likely close, then back off.
def interval(+elapsed: Nat) -> U32:
  Bool.pick(U32, Nat.is_lt(elapsed, 100n), 1, Bool.pick(U32, Nat.is_lt(elapsed, 1000n), 5, 20))
