import Base
import ../../native/Jev.bend as Jev
import ../../native/Codec.bend as Codec
import ../../native/Process.bend as Process
import ../../native/Json.bend as Json

# Wikirace: follow article links from a start page to a target page. Jev choice
# supports up to 255 options, so larger link sets run as a tournament: one
# choice per chunk of 255, then a final choice among the chunk winners.

def Error() -> Type:
  U32 & String

def Titles() -> Data:
  List<&2, String>

def Picked() -> Type:
  Jev.Client & Result<&1, &1, Error, String>

def Winners() -> Type:
  Jev.Client & Result<&1, &1, Error, Titles>

# ---- Fetching links ---------------------------------------------------------

def fetch_script() -> String:
  "set -eu\n" ++
  "curl -fsS --max-time 15 --get https://en.wikipedia.org/w/api.php -A 'jev-fabric-wikirace-demo/0.1' " ++
  "--data-urlencode action=parse --data-urlencode format=json --data-urlencode formatversion=2 " ++
  "--data-urlencode prop=links --data-urlencode redirects=1 --data-urlencode \"page=$1\" " ++
  "| jq -r '[.parse.links[] | select(.ns == 0 and .exists) | .title] | unique | .[]'"

def non_empty(lines: Titles) -> Titles:
  match lines:
    case Nil{}:
      Nil{}
    case Con{+line, rest}:
      +kept : Titles = non_empty(rest)
      Bool.pick(Titles, String.is_empty(line), kept, Con{line, kept})

def decoded(text: Result<&1, &1, Error, String>) -> Result<&1, &1, Error, Titles>:
  match text:
    case Fail{e}:
      Fail{e}
    case Done{s}:
      Done{non_empty(String.lines(s))}

def succeeded(+code: U32, out: List<&2, U32>, ok: Bool) -> Result<&1, &1, Error, Titles>:
  match ok:
    case False{}:
      Fail{(code, "link fetch failed")}
    case True{}:
      decoded(Codec.decode_utf8(out))

def captured(raw: Result<&1, &1, Error, Process.RawBytes>) -> Result<&1, &1, Error, Titles>:
  match raw:
    case Fail{e}:
      Fail{e}
    case Done{(+code, (flags, (out, err)))}:
      succeeded(code, out, U32.is_eq(code, 0) && U32.is_eq(flags, 0))

def fetch(title: String) -> IO(Result<&1, &1, Error, Titles>):
  do IO<Result<&1, &1, Error, Titles>>:
    raw : Result<&1, &1, Error, Process.RawBytes> <- Process.capture(["/bin/sh", "-c", fetch_script(), "sh", title], "", 20000, 1048576)
    return captured(raw)

# ---- List helpers -----------------------------------------------------------

def has(xs: Titles, +x: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{h, t}:
      String.eq(h, x) || has(t, x)

def unvisited(xs: Titles, +visited: Titles) -> Titles:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+h, t}:
      +kept : Titles = unvisited(t, visited)
      Bool.pick(Titles, has(visited, h), kept, Con{h, kept})

def chunks(fuel: Nat, xs: Titles) -> List<&2, Titles>:
  match fuel xs:
    case fuel Nil{}:
      Nil{}
    case 0n Con{h, t}:
      [Con{h, t}]
    case 1n+left Con{h, t}:
      +all : Titles = Con{h, t}
      Con{List.take(&2, String, all, 255n), chunks(left, List.drop(&2, String, all, 255n))}

def joined(path: Titles) -> String:
  String.join(List.reverse(&2, String, path), " -> ")

# ---- Asking Jev -------------------------------------------------------------

def criteria(options: Titles) -> String:
  match options:
    case Nil{}:
      ""
    case Con{h, Nil{}}:
      Json.quote(h) ++ ":null"
    case Con{h, t}:
      Json.quote(h) ++ ":null," ++ criteria(t)

def request(+target: String, context: String, options: Titles) -> String:
  "{\"state\":" ++ Json.quote(context) ++
  ",\"questions\":{\"next\":{\"type\":\"choice\",\"instructions\":" ++
  Json.quote("Which of these Wikipedia links is most likely to reach the article \"" ++ target ++ "\" in the fewest further clicks? Pick the target itself if present; otherwise prefer a closely related or broad hub article.") ++
  ",\"criteria\":{" ++ criteria(options) ++ "}}}}"

def answer(+value: Codec.Value, key: String) -> Maybe<&2, Codec.Value>:
  do Maybe<&2, Codec.Value>:
    answers : Codec.Value <- Codec.field(value, "answers")
    next : Codec.Value <- Codec.field(answers, "next")
    Codec.field(next, key)

def or_unknown(text: Result<&1, &1, Error, String>) -> String:
  match text:
    case Fail{e}:
      "?"
    case Done{s}:
      s

def shown(value: Maybe<&2, Codec.Value>) -> String:
  match value:
    case None{}:
      "?"
    case Some{v}:
      or_unknown(Codec.encode(v))

def required(text: Maybe<&2, String>) -> Result<&1, &1, Error, String>:
  match text:
    case None{}:
      Fail{(22, "Jev choice was not text")}
    case Some{s}:
      Done{s}

def chosen(value: Maybe<&2, Codec.Value>) -> Result<&1, &1, Error, String>:
  match value:
    case None{}:
      Fail{(22, "Jev answer had no choice")}
    case Some{v}:
      required(Codec.text(v))

def picked(returned: Jev.Returned, +count: Nat, +ms: Nat) -> IO(Picked):
  (client, result) = returned
  match result:
    case Fail{e}:
      IO.pure(Picked, (client, Fail{e}))
    case Done{+value}:
      do IO<Picked>:
        IO.print("    jev: " ++ shown(answer(value, "choice")) ++ " of " ++ Nat.show(count) ++ " (confidence " ++ shown(answer(value, "confidence")) ++ ", " ++ Nat.show(ms) ++ "ms)")
        return (client, chosen(answer(value, "choice")))

def ask(client: Jev.Client, +target: String, +context: String, +options: Titles) -> IO(Picked):
  do IO<Picked>:
    +started : Nat <- IO.now()
    returned : Jev.Returned <- Jev.evaluate(client, request(target, context, options))
    +finished : Nat <- IO.now()
    picked(returned, List.length(&2, String, options), Nat.sub(finished, started))

def collect(picked: Picked, winners: Titles) -> Winners:
  (client, result) = picked
  match result:
    case Fail{e}:
      (client, Fail{e})
    case Done{w}:
      (client, Done{Con{w, winners}})

def extend(acc: Winners, +target: String, +context: String, group: Titles) -> IO(Winners):
  (client, result) = acc
  match result:
    case Fail{e}:
      IO.pure(Winners, (client, Fail{e}))
    case Done{winners}:
      do IO<Winners>:
        pair : Picked <- ask(client, target, context, group)
        return collect(pair, winners)

def round(groups: List<&2, Titles>, +target: String, +context: String, acc: Winners) -> IO(Winners):
  match groups:
    case Nil{}:
      IO.pure(Winners, acc)
    case Con{group, rest}:
      do IO<Winners>:
        next : Winners <- extend(acc, target, context, group)
        round(rest, target, context, next)

def final(acc: Winners, +target: String, +context: String) -> IO(Picked):
  (client, result) = acc
  match result:
    case Fail{e}:
      IO.pure(Picked, (client, Fail{e}))
    case Done{Con{only, Nil{}}}:
      IO.pure(Picked, (client, Done{only}))
    case Done{+winners}:
      ask(client, target, context, List.reverse(&2, String, winners))

def choose(client: Jev.Client, +target: String, +context: String, +options: Titles) -> IO(Picked):
  do IO<Picked>:
    acc : Winners <- round(chunks(List.length(&2, String, options), options), target, context, (client, Done{Nil{}}))
    final(acc, target, context)

# ---- The race ---------------------------------------------------------------

type Race is Type:
  Running{client: Jev.Client, path: Titles}
  Finished{client: Jev.Client, path: Titles, outcome: String}

def moved(picked: Picked, +path: Titles) -> Race:
  (client, result) = picked
  match result:
    case Fail{(code, message)}:
      Finished{client, path, "stopped: " ++ message}
    case Done{next}:
      Running{client, Con{next, path}}

def explore(client: Jev.Client, +target: String, +path: Titles, +current: String, +options: Titles) -> IO(Race):
  match options:
    case Nil{}:
      IO.pure(Race, Finished{client, path, "dead end: every link was already visited"})
    case Con{h, t}:
      do IO<Race>:
        IO.print("  " ++ current ++ ": " ++ Nat.show(List.length(&2, String, options)) ++ " unvisited links")
        context : String = "Wikipedia race. Target article: \"" ++ target ++ "\". Current article: \"" ++ current ++ "\". Path so far: " ++ joined(path) ++ "."
        pair : Picked <- choose(client, target, context, options)
        return moved(pair, path)

def found(client: Jev.Client, +target: String, +path: Titles, +current: String, titles: Titles, reached: Bool) -> IO(Race):
  match reached:
    case True{}:
      IO.pure(Race, Finished{client, Con{target, path}, "reached"})
    case False{}:
      explore(client, target, path, current, unvisited(titles, path))

def arrived(client: Jev.Client, +target: String, +path: Titles, +current: String, links: Result<&1, &1, Error, Titles>) -> IO(Race):
  match links:
    case Fail{(code, message)}:
      IO.pure(Race, Finished{client, path, "could not read \"" ++ current ++ "\": " ++ message})
    case Done{+titles}:
      found(client, target, path, current, titles, has(titles, target))

def current_of(path: Titles) -> String:
  match path:
    case Nil{}:
      ""
    case Con{h, t}:
      h

def step(client: Jev.Client, +target: String, +path: Titles) -> IO(Race):
  do IO<Race>:
    +current : String = current_of(path)
    links : Result<&1, &1, Error, Titles> <- fetch(current)
    arrived(client, target, path, current, links)

def race(fuel: Nat, +target: String, state: Race) -> IO(Race):
  match fuel state:
    case fuel Finished{client, path, outcome}:
      IO.pure(Race, Finished{client, path, outcome})
    case 0n Running{client, path}:
      IO.pure(Race, Finished{client, path, "click limit reached"})
    case 1n+left Running{client, +path}:
      do IO<Race>:
        next : Race <- step(client, target, path)
        race(left, target, next)

def report(state: Race, +started: Nat, +finished: Nat) -> IO(Unit):
  match state:
    case Running{client, path}:
      IO.print("unfinished: " ++ joined(path))
    case Finished{client, +path, outcome}:
      do IO<Unit>:
        IO.print(outcome ++ " in " ++ Nat.show(Nat.sub(List.length(&2, String, path), 1n)) ++ " clicks, " ++ Nat.show(Nat.sub(finished, started)) ++ "ms")
        IO.print(joined(path))

def start(args: List<String>) -> IO(Unit):
  match args:
    case Con{+source, Con{+target, rest}}:
      do IO<Unit>:
        client : Jev.Client <- IO.try(Jev.Client, Jev.connect(120, 2000000))
        +started : Nat <- IO.now()
        IO.print("race: " ++ source ++ " -> " ++ target)
        state : Race <- race(12n, target, Running{client, [source]})
        +finished : Nat <- IO.now()
        report(state, started, finished)
    case other:
      IO.die(Unit, 2, "usage: wikirace -- <start article> <target article>")

# Opt-in network demo: reads Wikipedia with curl + jq and makes billed Jev calls
# (at most 120). Usage: jev-fabric -- run examples/native/wikirace.bend <from> <to>
def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args() starts with the program as invoked (Bend 2.0.32+).
    invoked : List<String> <- IO.args()
    args : List<String> = List.drop(&1, String, invoked, 1n)
    start(args)
