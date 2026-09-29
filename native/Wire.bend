import Base
import ./Codec.bend as Codec
import ./vendor/strict-json/json.bend as J

def from_maybe(value: Maybe<&2, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match value:
    case Some{v}:
      Done{v}
    case None{}:
      Fail{(22, "missing wire field")}

def need(value: J.JSON, key: String) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    found : J.JSON <- from_maybe(Codec.field(value, key))
    return found

def object(value: J.JSON) -> Result<&1, &1, U32 & String, List<&2, J.JSON>>:
  match value:
    case J.Obj{fields}:
      Done{fields}
    case other:
      Fail{(22, "expected wire object")}

def string(value: J.JSON) -> Result<&1, &1, U32 & String, String>:
  match value:
    case J.Str{s}:
      Done{s}
    case other:
      Fail{(22, "expected wire string")}

def array(value: J.JSON) -> Result<&1, &1, U32 & String, List<&2, J.JSON>>:
  match value:
    case J.Arr{items}:
      Done{items}
    case other:
      Fail{(22, "expected wire array")}

def utf16_length(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{Chr{code}, tail}:
      Nat.add(Bool.pick(Nat, U32.is_gt(code, 65535), 2n, 1n), utf16_length(tail))

def label(+s: String, limit: Nat) -> Bool:
  Bool.not(String.is_empty(s)) && Nat.is_le(utf16_length(s), limit)

def description(value: J.JSON) -> Bool:
  match value:
    case J.Str{s}:
      True{}
    case J.Arr{items}:
      True{}
    case J.Obj{fields}:
      True{}
    case other:
      False{}

def described_or_null(value: J.JSON) -> Bool:
  match value:
    case J.Null{}:
      True{}
    case other:
      description(other)

def only(fields: List<&2, J.JSON>, +keys: List<&2, String>) -> Bool:
  match fields:
    case Nil{}:
      True{}
    case Con{J.Member{key, value}, tail}:
      Codec.contains(keys, key) && only(tail, keys)
    case other:
      False{}

def descriptions(items: List<&2, J.JSON>) -> Bool:
  match items:
    case Nil{}:
      True{}
    case Con{head, tail}:
      description(head) && descriptions(tail)

def choices(fields: List<&2, J.JSON>) -> Bool:
  match fields:
    case Nil{}:
      True{}
    case Con{J.Member{key, value}, tail}:
      label(key, 256n) && described_or_null(value) && choices(tail)
    case other:
      False{}

def noul_fields(fields: List<&2, J.JSON>) -> Bool:
  match fields:
    case Nil{}:
      True{}
    case Con{J.Member{+key, value}, tail}:
      (String.eq(key, "true") || String.eq(key, "false"))
        && description(value)
        && noul_fields(tail)
    case other:
      False{}

def noul_criteria(value: Maybe<&2, J.JSON>) -> Result<&1, &1, U32 & String, Unit>:
  match value:
    case None{}:
      Done{Unit{}}
    case Some{v}:
      do Result<&1, &1, U32 & String, Unit>:
        fields : List<&2, J.JSON> <- object(v)
        Codec.guard(noul_fields(fields), "invalid Noul criteria")

def question_kind(kind: String, +q: J.JSON) -> Result<&1, &1, U32 & String, Unit>:
  match kind:
    case "choice":
      do Result<&1, &1, U32 & String, Unit>:
        c : J.JSON <- need(q, "criteria")
        +fields : List<&2, J.JSON> <- object(c)
        +n : Nat = List.length(&2, J.JSON, fields)
        Codec.guard(
          Nat.is_ge(n, 1n) && Nat.is_le(n, 255n) && choices(fields),
          "invalid Choice criteria",
        )
    case "score":
      do Result<&1, &1, U32 & String, Unit>:
        c : J.JSON <- need(q, "criteria")
        +items : List<&2, J.JSON> <- array(c)
        +n : Nat = List.length(&2, J.JSON, items)
        Codec.guard(
          Nat.is_ge(n, 2n) && Nat.is_le(n, 10n) && descriptions(items),
          "invalid Score criteria",
        )
    case "noul":
      noul_criteria(Codec.field(q, "criteria"))
    case other:
      Fail{(22, "unknown Jev question type")}

def question(+q: J.JSON) -> Result<&1, &1, U32 & String, Unit>:
  do Result<&1, &1, U32 & String, Unit>:
    fields : List<&2, J.JSON> <- object(q)
    Codec.guard(only(fields, ["type", "instructions", "criteria"]), "unknown question field")
    instruction : J.JSON <- need(q, "instructions")
    Codec.guard(description(instruction), "invalid instructions")
    kind_value : J.JSON <- need(q, "type")
    kind : String <- string(kind_value)
    question_kind(kind, q)

def questions(fields: List<&2, J.JSON>) -> Result<&1, &1, U32 & String, Unit>:
  match fields:
    case Nil{}:
      Done{Unit{}}
    case Con{J.Member{id, q}, tail}:
      do Result<&1, &1, U32 & String, Unit>:
        Codec.guard(label(id, 128n), "invalid question id")
        question(q)
        questions(tail)
    case other:
      Fail{(22, "invalid questions")}

def model(value: J.JSON) -> Result<&1, &1, U32 & String, Unit>:
  do Result<&1, &1, U32 & String, Unit>:
    s : String <- string(value)
    Codec.guard(label(s, 128n), "invalid model label")

def optional_model(value: Maybe<&2, J.JSON>) -> Result<&1, &1, U32 & String, Unit>:
  match value:
    case None{}:
      Done{Unit{}}
    case Some{v}:
      model(v)

def validate_request(+value: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    checked : J.JSON <- Codec.validate(value)
    fields : List<&2, J.JSON> <- object(checked)
    Codec.guard(only(fields, ["state", "questions", "model"]), "unknown request field")
    state : J.JSON <- need(value, "state")
    Codec.guard(description(state), "invalid Jev state")
    qs : J.JSON <- need(value, "questions")
    +qfields : List<&2, J.JSON> <- object(qs)
    +n : Nat = List.length(&2, J.JSON, qfields)
    Codec.guard(Nat.is_ge(n, 1n) && Nat.is_le(n, 128n), "invalid question count")
    questions(qfields)
    optional_model(Codec.field(value, "model"))
    return value

def request(text: String) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    value : J.JSON <- Codec.read(text)
    validate_request(value)

def defaulted(
  value: Maybe<&2, J.JSON>,
  fields: List<&2, J.JSON>,
  fallback: String,
) -> Result<&1, &1, U32 & String, String>:
  match value:
    case Some{v}:
      Codec.encode(J.Obj{fields})
    case None{}:
      do Result<&1, &1, U32 & String, String>:
        +m : J.JSON = J.Str{fallback}
        model(m)
        Codec.encode(J.Obj{Con{J.Member{"model", m}, fields}})

def body(value: J.JSON, default_model: String) -> Result<&1, &1, U32 & String, String>:
  do Result<&1, &1, U32 & String, String>:
    +checked : J.JSON <- validate_request(value)
    fields : List<&2, J.JSON> <- object(checked)
    defaulted(Codec.field(checked, "model"), fields, default_model)

# Fixed-scale conversion is used for integer token accounting (scale zero).
# Discarding fractional digits is forbidden; exponent work is bounded first.
def zeros(s: String) -> String:
  match s:
    case SCon{'0', tail}:
      zeros(tail)
    case other:
      other

def nat_result(value: Maybe<&2, Nat>) -> Result<&1, &1, U32 & String, Nat>:
  match value:
    case Some{n}:
      Done{n}
    case None{}:
      Fail{(22, "wire integer overflow")}

def exponent_digits(+s: String) -> Result<&1, &1, U32 & String, Nat>:
  do Result<&1, &1, U32 & String, Nat>:
    +digits : String = zeros(s)
    Codec.guard(Nat.is_le(String.length(digits), 4n), "wire exponent limit")
    +n : Nat <- nat_result(Nat.read("0" ++ digits))
    Codec.guard(Nat.is_le(n, 4096n), "wire exponent limit")
    return n

type Exponent is Data:
  Exponent{positive: Nat, negative: Nat}

def exponent(s: String) -> Result<&1, &1, U32 & String, Exponent>:
  match s:
    case SCon{'-', tail}:
      do Result<&1, &1, U32 & String, Exponent>:
        n : Nat <- exponent_digits(tail)
        return Exponent{0n, n}
    case SCon{'+', tail}:
      do Result<&1, &1, U32 & String, Exponent>:
        n : Nat <- exponent_digits(tail)
        return Exponent{n, 0n}
    case other:
      do Result<&1, &1, U32 & String, Exponent>:
        n : Nat <- exponent_digits(other)
        return Exponent{n, 0n}

type Mantissa is Data:
  Mantissa{digits: String, fractional: Nat, negative: Bool}

def mantissa(s: String, rev: String, frac: Nat, +after: Bool, negative: Bool) -> Mantissa:
  match s:
    case SNil{}:
      Mantissa{String.reverse(rev), frac, negative}
    case SCon{'-', tail}:
      mantissa(tail, rev, frac, after, True{})
    case SCon{'.', tail}:
      mantissa(tail, rev, frac, True{}, negative)
    case SCon{c, tail}:
      mantissa(tail, SCon{c, rev}, Nat.add(frac, Bool.pick(Nat, after, 1n, 0n)), after, negative)

def trailing(s: String, count: Nat) -> String & Nat:
  match s:
    case SCon{'0', tail}:
      trailing(tail, 1n+count)
    case other:
      (String.reverse(other), count)

# A lexeme's value is digits * 10^(up - down): up counts the requested scale, a
# positive exponent and trimmed trailing zeros; down counts fractional digits and a
# negative exponent.
def scaled_digits(
  +digits: String,
  +up: Nat,
  +down: Nat,
  negative: Bool,
  +maximum: Nat,
) -> Result<&1, &1, U32 & String, Nat>:
  match digits:
    case SNil{}:
      Done{0n}
    case other:
      do Result<&1, &1, U32 & String, Nat>:
        Codec.guard(Bool.not(negative), "negative wire scalar")
        Codec.guard(Nat.is_ge(up, down), "wire scalar exceeds twelve decimal places")
        +shift : Nat = Nat.sub(up, down)
        Codec.guard(Nat.is_le(Nat.add(String.length(other), shift), 15n), "wire scalar overflow")
        +n : Nat <- nat_result(Nat.read(other ++ String.repeat("0", shift)))
        Codec.guard(Nat.is_le(n, maximum), "wire scalar out of range")
        return n

def scaled_trimmed(
  pair: String & Nat,
  scale: Nat,
  exp_up: Nat,
  fractional: Nat,
  exp_down: Nat,
  negative: Bool,
  maximum: Nat,
) -> Result<&1, &1, U32 & String, Nat>:
  (trimmed, zeroes) = pair
  up = Nat.add(scale, Nat.add(exp_up, zeroes))
  scaled_digits(trimmed, up, Nat.add(fractional, exp_down), negative, maximum)

# Strip leading zeros, then count trailing zeros so they can move into the exponent.
def significant(digits: String) -> String & Nat:
  trailing(String.reverse(zeros(digits)), 0n)

def scaled_mantissa(
  m: Mantissa,
  e: Exponent,
  scale: Nat,
  maximum: Nat,
) -> Result<&1, &1, U32 & String, Nat>:
  match m e:
    case Mantissa{digits, fractional, negative} Exponent{exp_up, exp_down}:
      scaled_trimmed(significant(digits), scale, exp_up, fractional, exp_down, negative, maximum)

def plain_mantissa(text: String) -> Mantissa:
  mantissa(text, SNil{}, 0n, False{}, False{})

def scaled_parts(
  parts: List<&2, String>,
  scale: Nat,
  maximum: Nat,
) -> Result<&1, &1, U32 & String, Nat>:
  match parts:
    case Con{m, Nil{}}:
      scaled_mantissa(plain_mantissa(m), Exponent{0n, 0n}, scale, maximum)
    case Con{m, Con{e, Nil{}}}:
      do Result<&1, &1, U32 & String, Nat>:
        exp : Exponent <- exponent(e)
        scaled_mantissa(plain_mantissa(m), exp, scale, maximum)
    case other:
      Fail{(22, "invalid numeric scalar")}

def unit() -> Nat:
  Nat.mul(1000000n, 1000000n)

def scalar(value: J.JSON, scale: Nat, maximum: Nat) -> Result<&1, &1, U32 & String, Nat>:
  match value:
    case J.Num{lex}:
      scaled_parts(String.split(String.to_lower(lex), 'e'), scale, maximum)
    case other:
      Fail{(22, "expected numeric wire scalar")}

# Exact decimal fractions use digit strings, so small positives are not rounded
# away and sums are compared to 0.98 and 1.02 without binary floating point.
type Decimal is Data:
  Decimal{whole: Nat, fraction: String}

def decimal_checked(
  +whole: Nat,
  +fraction: String,
  +maximum: Nat,
) -> Result<&1, &1, U32 & String, Decimal>:
  do Result<&1, &1, U32 & String, Decimal>:
    Codec.guard(
      Nat.is_lt(whole, maximum) || (Nat.is_eq(whole, maximum) && String.is_empty(fraction)),
      "wire scalar out of range",
    )
    return Decimal{whole, fraction}

# len(digits) + up - down digits precede the decimal point. whole_side holds when
# that count is non-negative; otherwise the fraction needs leading zeros.
def decimal_split(
  +digits: String,
  +up: Nat,
  +down: Nat,
  maximum: Nat,
  whole_side: Bool,
) -> Result<&1, &1, U32 & String, Decimal>:
  match whole_side:
    case True{}:
      do Result<&1, &1, U32 & String, Decimal>:
        +count : Nat = Nat.sub(Nat.add(String.length(digits), up), down)
        Codec.guard(Nat.is_le(count, 1n), "wire scalar out of range")
        padding : String = String.repeat("0", Nat.sub(count, String.length(digits)))
        whole : Nat <- nat_result(Nat.read("0" ++ String.take(digits, count) ++ padding))
        decimal_checked(whole, String.drop(digits, count), maximum)
    case False{}:
      leading = String.repeat("0", Nat.sub(down, Nat.add(up, String.length(digits))))
      decimal_checked(0n, leading ++ digits, maximum)

def decimal_digits(
  digits: String,
  +up: Nat,
  +down: Nat,
  negative: Bool,
  maximum: Nat,
) -> Result<&1, &1, U32 & String, Decimal>:
  match digits:
    case SNil{}:
      Done{Decimal{0n, ""}}
    case +other:
      do Result<&1, &1, U32 & String, Decimal>:
        Codec.guard(Bool.not(negative), "negative wire scalar")
        whole_side : Bool = Nat.is_ge(Nat.add(String.length(other), up), down)
        decimal_split(other, up, down, maximum, whole_side)

def decimal_trimmed(
  pair: String & Nat,
  exp_up: Nat,
  fractional: Nat,
  exp_down: Nat,
  negative: Bool,
  maximum: Nat,
) -> Result<&1, &1, U32 & String, Decimal>:
  (trimmed, zeroes) = pair
  decimal_digits(trimmed, Nat.add(exp_up, zeroes), Nat.add(fractional, exp_down), negative, maximum)

def decimal_mantissa(
  m: Mantissa,
  e: Exponent,
  maximum: Nat,
) -> Result<&1, &1, U32 & String, Decimal>:
  match m e:
    case Mantissa{digits, fractional, negative} Exponent{exp_up, exp_down}:
      decimal_trimmed(significant(digits), exp_up, fractional, exp_down, negative, maximum)

def decimal_parts(parts: List<&2, String>, maximum: Nat) -> Result<&1, &1, U32 & String, Decimal>:
  match parts:
    case Con{m, Nil{}}:
      decimal_mantissa(plain_mantissa(m), Exponent{0n, 0n}, maximum)
    case Con{m, Con{e, Nil{}}}:
      do Result<&1, &1, U32 & String, Decimal>:
        exp : Exponent <- exponent(e)
        decimal_mantissa(plain_mantissa(m), exp, maximum)
    case other:
      Fail{(22, "invalid numeric scalar")}

def decimal(value: J.JSON, maximum: Nat) -> Result<&1, &1, U32 & String, Decimal>:
  match value:
    case J.Num{lex}:
      decimal_parts(String.split(String.to_lower(lex), 'e'), maximum)
    case other:
      Fail{(22, "expected numeric wire scalar")}

def probability(value: J.JSON) -> Result<&1, &1, U32 & String, Decimal>:
  decimal(value, 1n)

# Prepend the low decimal digit of a column sum (digits plus carry) as a character.
def push_digit(+sum: U32, acc: String) -> String:
  SCon{Chr{U32.add(48, U32.mod(sum, 10))}, acc}

# Adds two reversed fraction digit strings; the result drops trailing zeros.
def fraction_add(a: String, b: String, carry: U32, acc: String) -> Decimal:
  match a b:
    case SNil{} SNil{}:
      Decimal{U32.to_nat(carry), String.reverse(zeros(String.reverse(acc)))}
    case SCon{Chr{x}, at} SCon{Chr{y}, bt}:
      +sum = U32.add(U32.sub(U32.add(x, y), 96), carry)
      fraction_add(at, bt, U32.div(sum, 10), push_digit(sum, acc))
    case SCon{Chr{x}, at} SNil{}:
      +sum = U32.add(U32.sub(x, 48), carry)
      fraction_add(at, SNil{}, U32.div(sum, 10), push_digit(sum, acc))
    case SNil{} SCon{Chr{y}, bt}:
      +sum = U32.add(U32.sub(y, 48), carry)
      fraction_add(SNil{}, bt, U32.div(sum, 10), push_digit(sum, acc))

def decimal_carry(fraction: Decimal, a: Nat, b: Nat) -> Decimal:
  match fraction:
    case Decimal{carry, digits}:
      Decimal{Nat.add(carry, Nat.add(a, b)), digits}

# Right-pads fraction digits with zeros to width (unchanged when already that long).
def pad_fraction(+digits: String, width: Nat) -> String:
  digits ++ String.repeat("0", Nat.sub(width, String.length(digits)))

def decimal_add(a: Decimal, b: Decimal) -> Decimal:
  match a b:
    case Decimal{aw, +af} Decimal{bw, +bf}:
      a_reversed = String.reverse(pad_fraction(af, String.length(bf)))
      b_reversed = String.reverse(pad_fraction(bf, String.length(af)))
      decimal_carry(fraction_add(a_reversed, b_reversed, 0, ""), aw, bw)

def decimal_le(a: Decimal, b: Decimal) -> Bool:
  match a b:
    case Decimal{+aw, +af} Decimal{+bw, +bf}:
      a_fraction = pad_fraction(af, String.length(bf))
      b_fraction = pad_fraction(bf, String.length(af))
      Nat.is_lt(aw, bw) || (Nat.is_eq(aw, bw) && String.is_le(a_fraction, b_fraction))

# The native Nat cap, 2^48 - 1 (281474976710655). Base's Nat.read.max was
# removed in Bend 2.0.28; the bound itself is unchanged.
def nat_max() -> Nat:
  Nat.mul(U32.to_nat(16777215), U32.to_nat(16777217))

# Token counts of a response that has already passed Codec.validate.
def usage_counts(value: J.JSON) -> Result<&1, &1, U32 & String, Nat & Nat>:
  do Result<&1, &1, U32 & String, Nat & Nat>:
    u : J.JSON <- need(value, "usage")
    +fields : List<&2, J.JSON> <- object(u)
    i : J.JSON <- need(J.Obj{fields}, "input_tokens")
    o : J.JSON <- need(J.Obj{fields}, "output_tokens")
    input : Nat <- scalar(i, 0n, nat_max())
    output : Nat <- scalar(o, 0n, nat_max())
    return (input, output)

def usage(value: J.JSON) -> Result<&1, &1, U32 & String, Nat & Nat>:
  do Result<&1, &1, U32 & String, Nat & Nat>:
    checked : J.JSON <- Codec.validate(value)
    usage_counts(checked)

def named(fields: List<&2, J.JSON>, +key: String) -> Bool:
  match fields:
    case Nil{}:
      False{}
    case Con{J.Member{name, value}, tail}:
      String.eq(name, key) || named(tail, key)
    case other:
      False{}

def indexed(items: List<&2, J.JSON>, +index: Nat) -> List<&2, J.JSON>:
  match items:
    case Nil{}:
      Nil{}
    case Con{head, tail}:
      Con{J.Member{Nat.show(index), head}, indexed(tail, 1n+index)}

def probability_sum(
  expected: List<&2, J.JSON>,
  +actual: J.JSON,
  acc: Decimal,
) -> Result<&1, &1, U32 & String, Decimal>:
  match expected:
    case Nil{}:
      Done{acc}
    case Con{J.Member{key, description}, tail}:
      do Result<&1, &1, U32 & String, Decimal>:
        value : J.JSON <- need(actual, key)
        n : Decimal <- probability(value)
        probability_sum(tail, actual, decimal_add(acc, n))
    case other:
      Fail{(22, "invalid probability keys")}

def ordered(
  expected: List<&2, J.JSON>,
  +actual: J.JSON,
) -> Result<&1, &1, U32 & String, List<&2, J.JSON>>:
  match expected:
    case Nil{}:
      Done{Nil{}}
    case Con{J.Member{+key, description}, tail}:
      do Result<&1, &1, U32 & String, List<&2, J.JSON>>:
        value : J.JSON <- need(actual, key)
        rest : List<&2, J.JSON> <- ordered(tail, actual)
        return Con{J.Member{key, value}, rest}
    case other:
      Fail{(22, "invalid probability keys")}

type Common is Data:
  Common{confidence: J.JSON, probabilities: J.JSON}

def common(+answer: J.JSON, +expected: List<&2, J.JSON>) -> Result<&1, &1, U32 & String, Common>:
  do Result<&1, &1, U32 & String, Common>:
    +confidence : J.JSON <- need(answer, "confidence")
    confidence_n : Decimal <- probability(confidence)
    +p : J.JSON <- need(answer, "probabilities")
    fields : List<&2, J.JSON> <- object(p)
    Codec.guard(
      Nat.is_eq(List.length(&2, J.JSON, fields), List.length(&2, J.JSON, expected)),
      "probability key count mismatch",
    )
    +sum : Decimal <- probability_sum(expected, p, Decimal{0n, ""})
    Codec.guard(
      decimal_le(Decimal{0n, "98"}, sum) && decimal_le(sum, Decimal{1n, "02"}),
      "probability mass outside tolerance",
    )
    rows : List<&2, J.JSON> <- ordered(expected, p)
    return Common{confidence, J.Obj{rows}}

def choice_answer(fields: Common, selected: J.JSON) -> J.JSON:
  match fields:
    case Common{confidence, probabilities}:
      J.Obj{[
        J.Member{"type", J.Str{"choice"}},
        J.Member{"choice", selected},
        J.Member{"confidence", confidence},
        J.Member{"probabilities", probabilities},
      ]}

def score_answer(fields: Common, score: J.JSON, legend: List<&2, J.JSON>) -> J.JSON:
  match fields:
    case Common{confidence, probabilities}:
      J.Obj{[
        J.Member{"type", J.Str{"score"}},
        J.Member{"score", score},
        J.Member{"confidence", confidence},
        J.Member{"probabilities", probabilities},
        J.Member{"legend", J.Obj{legend}},
      ]}

def answer_kind(kind: String, q: J.JSON, +a: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  match kind:
    case "noul":
      do Result<&1, &1, U32 & String, J.JSON>:
        +n : J.JSON <- need(a, "noul")
        checked : Decimal <- probability(n)
        return J.Obj{[J.Member{"type", J.Str{"noul"}}, J.Member{"noul", n}]}
    case "choice":
      do Result<&1, &1, U32 & String, J.JSON>:
        c : J.JSON <- need(q, "criteria")
        +expected : List<&2, J.JSON> <- object(c)
        +selected : J.JSON <- need(a, "choice")
        key : String <- string(selected)
        Codec.guard(named(expected, key), "unknown selected choice")
        fields : Common <- common(a, expected)
        return choice_answer(fields, selected)
    case "score":
      do Result<&1, &1, U32 & String, J.JSON>:
        c : J.JSON <- need(q, "criteria")
        +levels : List<&2, J.JSON> <- array(c)
        +expected : List<&2, J.JSON> = indexed(levels, 0n)
        +score : J.JSON <- need(a, "score")
        top_level : Nat = Nat.sub(List.length(&2, J.JSON, levels), 1n)
        checked : Decimal <- decimal(score, top_level)
        fields : Common <- common(a, expected)
        return score_answer(fields, score, expected)
    case other:
      Fail{(22, "unknown answer type")}

def answer(+q: J.JSON, +a: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    fields : List<&2, J.JSON> <- object(a)
    kind_value : J.JSON <- need(q, "type")
    +kind : String <- string(kind_value)
    actual_value : J.JSON <- need(a, "type")
    actual : String <- string(actual_value)
    Codec.guard(String.eq(kind, actual), "answer type mismatch")
    answer_kind(kind, q, a)

def answers(
  questions: List<&2, J.JSON>,
  +actual: J.JSON,
) -> Result<&1, &1, U32 & String, List<&2, J.JSON>>:
  match questions:
    case Nil{}:
      Done{Nil{}}
    case Con{J.Member{+id, q}, tail}:
      do Result<&1, &1, U32 & String, List<&2, J.JSON>>:
        raw : J.JSON <- need(actual, id)
        safe : J.JSON <- answer(q, raw)
        rest : List<&2, J.JSON> <- answers(tail, actual)
        return Con{J.Member{id, safe}, rest}
    case other:
      Fail{(22, "invalid question object")}

# A normalized reply together with the token counts parsed from its usage.
type Reply is Data:
  Reply{value: J.JSON, input: Nat, output: Nat}

def reply_of(value: J.JSON, counts: Nat & Nat) -> Reply:
  (input, output) = counts
  Reply{value, input, output}

def reply_value(reply: Reply) -> J.JSON:
  match reply:
    case Reply{value, input, output}:
      value

# `value` must already have passed Codec.validate (Codec.read does), so its usage
# counts are parsed without validating the whole response a second time.
def normalize(+value: J.JSON, request: J.JSON) -> Result<&1, &1, U32 & String, Reply>:
  do Result<&1, &1, U32 & String, Reply>:
    fields : List<&2, J.JSON> <- object(value)
    +m : J.JSON <- need(value, "model")
    model(m)
    counts : Nat & Nat <- usage_counts(value)
    +u : J.JSON <- need(value, "usage")
    input : J.JSON <- need(u, "input_tokens")
    output : J.JSON <- need(u, "output_tokens")
    qs : J.JSON <- need(request, "questions")
    +qfields : List<&2, J.JSON> <- object(qs)
    +raw_answers : J.JSON <- need(value, "answers")
    afields : List<&2, J.JSON> <- object(raw_answers)
    Codec.guard(
      Nat.is_eq(List.length(&2, J.JSON, qfields), List.length(&2, J.JSON, afields)),
      "answer key count mismatch",
    )
    safe : List<&2, J.JSON> <- answers(qfields, raw_answers)
    tokens : J.JSON = J.Obj{[J.Member{"input_tokens", input}, J.Member{"output_tokens", output}]}
    normalized : J.JSON = J.Obj{[
      J.Member{"model", m},
      J.Member{"answers", J.Obj{safe}},
      J.Member{"usage", tokens},
    ]}
    return reply_of(normalized, counts)

def reply(text: String, request: J.JSON) -> Result<&1, &1, U32 & String, Reply>:
  do Result<&1, &1, U32 & String, Reply>:
    req : J.JSON <- validate_request(request)
    value : J.JSON <- Codec.read(text)
    normalize(value, req)

def response(text: String, request: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  do Result<&1, &1, U32 & String, J.JSON>:
    normalized : Reply <- reply(text, request)
    return reply_value(normalized)

# The counts normalize parsed, once the normalized reply itself passes Codec.validate.
# This matches usage(value) on that reply without re-reading its usage object. The
# validation stays: a score legend copies request criteria, so a valid response can
# still normalize past the JSON size limits.
def reply_usage(reply: Reply) -> Result<&1, &1, U32 & String, Nat & Nat>:
  match reply:
    case Reply{value, input, output}:
      do Result<&1, &1, U32 & String, Nat & Nat>:
        checked : J.JSON <- Codec.validate(value)
        return (input, output)
