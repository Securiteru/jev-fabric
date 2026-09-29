import Base
import ./TimeCore.bend as Time

# Normalize public conveniences into the stable positional dispatcher.
# Parse only a prefix. After the command/source, all arguments remain literal.
def Error() -> Type:
  U32 & String

def version() -> String:
  "0.5.0-native"

type Options is Type:
  Options{
    args: List<String>,
    timeout: Maybe<&2, U32>,
    input: Bool,
    literal: Bool,
    label: Maybe<&2, String>,
    cwd: Maybe<&2, String>,
    pipe: Bool,
  }

# What a launch carries besides its timer: a job label, the directory the
# command starts in ("" inherits the caller's) and whether its stdin stays open
# for `write` (`start --input pipe`).
type Launch is Data:
  Launch{label: String, cwd: String, pipe: Bool}

def plain() -> Launch:
  Launch{"", "", False{}}

type Plan is Type:
  Timed{command: String, args: List<String>, timeout: Maybe<&2, U32>, input: Bool, launch: Launch}
  Pass{args: List<String>}

def max(command: String) -> U32:
  match command:
    case "watch":
      300000
    case "events":
      300000
    case "start":
      Time.job_max()
    case "serve":
      Time.job_max()
    case other:
      3600000

def unique(previous: Maybe<&2, U32>, value: U32) -> Result<&1, &1, Error, U32>:
  match previous:
    case None{}:
      Done{value}
    case Some{old}:
      Fail{(2, "specify the timeout only once")}

def input_allowed(allowed: Bool, duplicate: Bool) -> Result<&1, &1, Error, Unit>:
  match allowed duplicate:
    case True{} False{}:
      Done{Unit{}}
    case _ _:
      Fail{(2, "--stdin is supported once, for exec only")}

# A job label: 1..120 Unicode scalars, printable, on one line. C0/C1 controls,
# DEL and the Unicode line and paragraph separators are rejected.
def label_max() -> Nat:
  120n

def printable(+code: U32) -> Bool:
  U32.is_ge(code, 32)
    && U32.is_ne(code, 127)
    && (U32.is_lt(code, 128) || U32.is_gt(code, 159))
    && U32.is_ne(code, 8232)
    && U32.is_ne(code, 8233)

def printable_text(text: String) -> Bool:
  match text:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      printable(Char.to_u32(c)) && printable_text(rest)

def label_allowed(text: String, ok: Bool) -> Result<&1, &1, Error, String>:
  match ok:
    case True{}:
      Done{text}
    case False{}:
      Fail{(2, "label must be 1..120 printable characters on one line")}

def label_checked(+text: String) -> Result<&1, &1, Error, String>:
  +length = String.length(text)
  label_allowed(text, Nat.is_ge(length, 1n) && Nat.is_le(length, label_max()) && printable_text(text))

# An empty label means none; any other label must pass label_checked.
def optional_label(+text: String) -> Result<&1, &1, Error, String>:
  match text:
    case SNil{}:
      Done{""}
    case other:
      label_checked(other)

def label_once(allowed: Bool, previous: Maybe<&2, String>, value: String) -> Result<&1, &1, Error, String>:
  match allowed previous:
    case False{} _:
      Fail{(2, "--label is supported for start only")}
    case True{} Some{old}:
      Fail{(2, "specify the label only once")}
    case True{} None{}:
      label_checked(value)

# A working directory is an absolute path of at most 4096 bytes; whether it
# exists is checked when the command starts.
def cwd_max() -> Nat:
  4096n

def cwd_allowed(path: String, ok: Bool) -> Result<&1, &1, Error, String>:
  match ok:
    case True{}:
      Done{path}
    case False{}:
      Fail{(2, "cwd must be an absolute path")}

def cwd_checked(+path: String) -> Result<&1, &1, Error, String>:
  cwd_allowed(path, String.starts_with(path, "/") && Nat.is_le(String.length(path), cwd_max()))

def cwd_once(allowed: Bool, previous: Maybe<&2, String>, value: String) -> Result<&1, &1, Error, String>:
  match allowed previous:
    case False{} _:
      Fail{(2, "--cwd is supported for exec and start only")}
    case True{} Some{old}:
      Fail{(2, "specify the cwd only once")}
    case True{} None{}:
      cwd_checked(value)

# `--input pipe` keeps a `start` job's stdin open; it is the only input mode.
def pipe_once(allowed: Bool, previous: Bool, value: String) -> Result<&1, &1, Error, Bool>:
  match allowed previous:
    case False{} _:
      Fail{(2, "--input is supported for start only")}
    case True{} True{}:
      Fail{(2, "specify the input only once")}
    case True{} False{}:
      Bool.pick(Result<&1, &1, Error, Bool>, String.eq(value, "pipe"), Done{True{}}, Fail{(2, "--input takes pipe")})

def first_option(
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  label: Maybe<&2, String>,
  cwd: Maybe<&2, String>,
  pipe: Bool,
  bad: Bool,
) -> Result<&1, &1, Error, Options>:
  match bad:
    case True{}:
      Fail{(2, "unknown option; use -- before a literal command")}
    case False{}:
      Done{Options{args, timeout, input, False{}, label, cwd, pipe}}

def options(
  args: List<String>,
  timeout: Maybe<&2, U32>,
  label: Maybe<&2, String>,
  cwd: Maybe<&2, String>,
  +pipe: Bool,
  +input: Bool,
  +allow_input: Bool,
  +allow_label: Bool,
  +allow_cwd: Bool,
  +limit: U32,
) -> Result<&1, &1, Error, Options>:
  match args:
    case Con{"--timeout-ms", Con{raw, rest}}:
      do Result<&1, &1, Error, Options>:
        value : U32 <- Time.parse(raw, limit)
        chosen : U32 <- unique(timeout, value)
        options(rest, Some{chosen}, label, cwd, pipe, input, allow_input, allow_label, allow_cwd, limit)
    case Con{"--timeout-ms", Nil{}}:
      Fail{(2, "--timeout-ms requires milliseconds")}
    case Con{"--label", Con{raw, rest}}:
      do Result<&1, &1, Error, Options>:
        chosen : String <- label_once(allow_label, label, raw)
        options(rest, timeout, Some{chosen}, cwd, pipe, input, allow_input, allow_label, allow_cwd, limit)
    case Con{"--label", Nil{}}:
      Fail{(2, "--label requires text")}
    case Con{"--cwd", Con{raw, rest}}:
      do Result<&1, &1, Error, Options>:
        chosen : String <- cwd_once(allow_cwd, cwd, raw)
        options(rest, timeout, label, Some{chosen}, pipe, input, allow_input, allow_label, allow_cwd, limit)
    case Con{"--cwd", Nil{}}:
      Fail{(2, "--cwd requires a directory")}
    case Con{"--input", Con{raw, rest}}:
      do Result<&1, &1, Error, Options>:
        chosen : Bool <- pipe_once(allow_label, pipe, raw)
        options(rest, timeout, label, cwd, chosen, input, allow_input, allow_label, allow_cwd, limit)
    case Con{"--input", Nil{}}:
      Fail{(2, "--input takes pipe")}
    case Con{"--stdin", rest}:
      do Result<&1, &1, Error, Options>:
        input_allowed(allow_input, input)
        options(rest, timeout, label, cwd, pipe, True{}, allow_input, allow_label, allow_cwd, limit)
    case Con{"--", rest}:
      Done{Options{rest, timeout, input, True{}, label, cwd, pipe}}
    case Con{+first, rest}:
      first_option(Con{first, rest}, timeout, input, label, cwd, pipe, String.starts_with(first, "-"))
    case Nil{}:
      Done{Options{Nil{}, timeout, input, False{}, label, cwd, pipe}}

def digits(text: String) -> Bool:
  match text:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      Char.is_digit(c) && digits(rest)

def legacy_exec(args: List<String>, ms: U32, +input: Bool) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{"--stdin", rest}:
      do Result<&1, &1, Error, Plan>:
        input_allowed(True{}, input)
        return Timed{"exec", rest, Some{ms}, True{}, plain()}
    case other:
      Done{Timed{"exec", other, Some{ms}, input, plain()}}

def legacy_plan(
  command: String,
  args: List<String>,
  ms: U32,
  input: Bool,
  launch: Launch,
) -> Result<&1, &1, Error, Plan>:
  match command:
    case "exec":
      legacy_exec(args, ms, input)
    case other:
      Done{Timed{other, args, Some{ms}, input, launch}}

# Legacy positional syntax carries the timeout as a bare millisecond argument.
def legacy(
  +command: String,
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  launch: Launch,
  raw: String,
) -> Result<&1, &1, Error, Plan>:
  do Result<&1, &1, Error, Plan>:
    value : U32 <- Time.parse(raw, max(command))
    ms : U32 <- unique(timeout, value)
    legacy_plan(command, args, ms, input, launch)

def launch_first(
  +command: String,
  first: String,
  rest: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  launch: Launch,
  numeric: Bool,
) -> Result<&1, &1, Error, Plan>:
  match numeric:
    case True{}:
      legacy(command, rest, timeout, input, launch, first)
    case False{}:
      Done{Timed{command, Con{first, rest}, timeout, input, launch}}

def launch(
  command: String,
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  literal: Bool,
  launch: Launch,
) -> Result<&1, &1, Error, Plan>:
  match args:
    case Nil{}:
      Fail{(2, "command or file is required")}
    case Con{+first, rest}:
      numeric = Bool.not(literal) && Bool.not(String.is_empty(first)) && digits(first)
      launch_first(command, first, rest, timeout, input, launch, numeric)

def wait_args(args: List<String>, timeout: Maybe<&2, U32>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{id, Nil{}}:
      Done{Timed{"wait", [id], timeout, False{}, plain()}}
    case Con{id, Con{raw, Nil{}}}:
      legacy("wait", [id], timeout, False{}, plain(), raw)
    case other:
      Fail{(2, "usage: wait [--timeout-ms N] <id> [legacy-ms]")}

def watch_args(args: List<String>, timeout: Maybe<&2, U32>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{id, Con{text, Nil{}}}:
      Done{Timed{"watch", [id, text], timeout, False{}, plain()}}
    case Con{id, Con{raw, Con{text, Nil{}}}}:
      legacy("watch", [id, text], timeout, False{}, plain(), raw)
    case other:
      Fail{(2, "usage: watch [--timeout-ms N] <id> <literal>")}

def follow_args(args: List<String>, timeout: Maybe<&2, U32>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Con{id, Nil{}}:
      Done{Timed{"follow", [id], timeout, False{}, plain()}}
    case Con{id, Con{after, Nil{}}}:
      Done{Timed{"follow", [id, after], timeout, False{}, plain()}}
    case other:
      Fail{(2, "usage: follow [--timeout-ms N] <id> [after-sequence]")}

# Without --timeout-ms, events stays an immediate snapshot. With it, events waits
# up to that long for an event past the cursor or a terminal receipt.
def events_args(args: List<String>, timeout: Maybe<&2, U32>) -> Result<&1, &1, Error, Plan>:
  match args timeout:
    case Con{id, Nil{}} None{}:
      Done{Pass{["events", id]}}
    case Con{id, Con{after, Nil{}}} None{}:
      Done{Pass{["events", id, after]}}
    case Con{id, Nil{}} Some{ms}:
      Done{Timed{"events", [id, "0"], Some{ms}, False{}, plain()}}
    case Con{id, Con{after, Nil{}}} Some{ms}:
      Done{Timed{"events", [id, after], Some{ms}, False{}, plain()}}
    case _ _:
      Fail{(2, "usage: events [--timeout-ms N] <id> [after-sequence]")}

def select_command(
  command: String,
  args: List<String>,
  timeout: Maybe<&2, U32>,
  input: Bool,
  literal: Bool,
  launch_with: Launch,
) -> Result<&1, &1, Error, Plan>:
  match command:
    case "wait":
      wait_args(args, timeout)
    case "watch":
      watch_args(args, timeout)
    case "follow":
      follow_args(args, timeout)
    case "events":
      events_args(args, timeout)
    case "serve":
      Done{Timed{"serve", args, timeout, False{}, plain()}}
    case other:
      launch(other, args, timeout, input, literal, launch_with)

def chosen(value: Maybe<&2, String>) -> String:
  match value:
    case None{}:
      ""
    case Some{text}:
      text

def selected(parsed: Options, command: String) -> Result<&1, &1, Error, Plan>:
  match parsed:
    case Options{args, timeout, input, literal, label, cwd, pipe}:
      select_command(command, args, timeout, input, literal, Launch{chosen(label), chosen(cwd), pipe})

def parse_timed(+command: String, args: List<String>) -> Result<&1, &1, Error, Plan>:
  do Result<&1, &1, Error, Plan>:
    parsed : Options <- options(
      args,
      None{},
      None{},
      None{},
      False{},
      False{},
      String.eq(command, "exec"),
      String.eq(command, "start"),
      String.eq(command, "exec") || String.eq(command, "start"),
      max(command),
    )
    selected(parsed, command)

def route(+command: String, args: List<String>, timed: Bool) -> Result<&1, &1, Error, Plan>:
  match timed:
    case True{}:
      parse_timed(command, args)
    case False{}:
      Done{Pass{Con{command, args}}}

# Commands that accept timeout options; every other command passes through unchanged.
def accepts_timeout(command: String) -> Bool:
  match command:
    case "exec":
      True{}
    case "run":
      True{}
    case "start":
      True{}
    case "jev":
      True{}
    case "wait":
      True{}
    case "watch":
      True{}
    case "follow":
      True{}
    case "events":
      True{}
    case "serve":
      True{}
    case other:
      False{}

def parse(args: List<String>) -> Result<&1, &1, Error, Plan>:
  match args:
    case Nil{}:
      Done{Pass{Nil{}}}
    case Con{+command, rest}:
      route(command, rest, accepts_timeout(command))

def exec_args(args: List<String>, ms: U32, input: Bool) -> List<String>:
  match input:
    case True{}:
      Con{"exec", Con{U32.show(ms), Con{"--stdin", args}}}
    case False{}:
      Con{"exec", Con{U32.show(ms), args}}

def launch_label(launch: Launch) -> String:
  match launch:
    case Launch{label, cwd, pipe}:
      label

def launch_cwd(launch: Launch) -> String:
  match launch:
    case Launch{label, cwd, pipe}:
      cwd

# The worker mode `start` hands the dispatcher.
def launch_mode(launch: Launch) -> String:
  match launch:
    case Launch{label, cwd, pipe}:
      Bool.pick(String, pipe, "pipe", "batch")

# `start` always reaches the dispatcher as
# `__start <ms> <label> <cwd> <mode> <command...>`, with an empty label or cwd
# for none, so a command named like an option stays literal.
def canonical(command: String, args: List<String>, ms: U32, input: Bool, +launch: Launch) -> List<String>:
  match command:
    case "exec":
      exec_args(args, ms, input)
    case "start":
      Con{"__start", Con{U32.show(ms), Con{launch_label(launch), Con{launch_cwd(launch), Con{launch_mode(launch), args}}}}}
    case "wait":
      match args:
        case Con{id, rest}:
          ["wait", id, U32.show(ms)]
        case Nil{}:
          ["wait"]
    case "watch":
      match args:
        case Con{id, rest}:
          Con{"watch", Con{id, Con{U32.show(ms), rest}}}
        case Nil{}:
          ["watch"]
    case "events":
      match args:
        case Con{id, Con{after, rest}}:
          ["events", id, after, U32.show(ms)]
        case other:
          ["events"]
    case other:
      Con{other, Con{U32.show(ms), args}}
