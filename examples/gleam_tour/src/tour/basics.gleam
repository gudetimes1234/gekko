import gleam/bool
import gleam/bytes_tree
import gleam/float
import gleam/int
import gleam/string
import gleam/string.{reverse} as text
import gleam/string_tree.{type StringTree}

pub type Number =
  Int

const ints: List(Int) = [1, 2, 3]

const floats = [1.1, 2.2, 3.3]

pub fn run() -> String {
  // Int arithmetic & comparisons
  assert 1 + 1 == 2
  assert 5 - 1 == 4
  assert 5 / 2 == 2
  assert 3 * 3 == 9
  assert 5 % 2 == 1
  assert 3 > 1 + 1
  assert !{ 2 < 1 - 1 }
  assert 8 >= 1 + 3
  assert !{ 8 <= 5 - 3 }
  assert 2 == 1 + 1
  assert !{ 2 == 1 - 1 }
  assert int.max(42, 77) == 77
  assert int.clamp(5, 10, 20) == 10

  // Float arithmetic, comparisons & divide-by-zero
  assert 1.0 +. 1.5 == 2.5
  assert 5.0 -. 1.5 == 3.5
  assert 5.0 /. 2.5 == 2.0
  assert 3.0 *. 3.5 == 10.5
  let one = 1.0
  assert 2.2 >. one
  assert !{ 2.2 <. one }
  assert 2.2 >=. one
  assert !{ 2.2 <=. one }
  assert 3.0 == 1.5 *. 2.0
  assert 3.14 /. 0.0 == 0.0
  assert float.max(2.0, 9.5) == 9.5
  assert float.ceiling(5.4) == 6.0

  // Number formats
  let million = 1_000_000
  let dec = 10_000.01
  assert million == 1_000_000
  assert dec == 10_000.01
  assert 0b00001111 == 15
  assert 0o17 == 15
  assert 0xF == 15
  assert 7.0e7 == 70_000_000.0
  assert 3.0e-4 == 0.0003
  assert 100 == 50 + 50
  assert 1.5 != 0.1 *. 10.0

  // Strings, Unicode, multiline, escapes, concat, module alias & unqualified import
  let unicode = "👩‍💻 こんにちは Gleam 🏳️‍🌈"
  let multiline =
    "multi
line
string"
  let smiley = "\u{1F600}"
  let quoted = "\"X\" marks the spot"
  let combined = "One " <> "Two"
  assert string.contains(unicode, "Gleam")
  assert string.contains(multiline, "line")
  assert string.length(smiley) == 1
  assert quoted == "\"X\" marks the spot"
  assert combined == "One Two"
  assert text.reverse("1 2 3 4 5") == "5 4 3 2 1"
  assert reverse("abc") == "cba"
  assert string.append("abc", "def") == "abcdef"

  // Bools
  assert !{ True && False }
  assert True && True
  assert !{ False || False }
  assert False || True
  assert bool.to_string(True) == "True"
  assert bool.and(True, True)
  assert bool.or(False, True)
  assert bool.guard(when: False, return: "no", otherwise: fn() { "yes" })
    == "yes"

  // Assignments, shadowing & discard pattern
  let x = "Original"
  let y = x
  let x = "New"
  assert x == "New"
  assert y == "Original"
  let _score = 1000

  // Type annotations & qualified/unqualified type imports & aliases
  let _name: String = "Gleam"
  let _is_cool: Bool = True
  let _version: Int = 1
  let bytes: bytes_tree.BytesTree =
    bytes_tree.new() |> bytes_tree.append_string("hi")
  let stree: StringTree = string_tree.from_string("ok")
  assert bytes_tree.byte_size(bytes) == 2
  assert string_tree.to_string(stree) == "ok"

  let num_one: Number = 1
  let num_two: Int = 2
  assert num_one + num_two == 3

  // Blocks
  let fahrenheit = {
    let degrees = 64
    degrees
  }
  let celsius = { fahrenheit - 32 } * 5 / 9
  assert celsius == 17

  // Lists & Constants
  let prepended = [-1, 0, ..ints]
  assert ints == [1, 2, 3]
  assert prepended == [-1, 0, 1, 2, 3]
  assert floats == [1.1, 2.2, 3.3]

  "celsius="
  <> int.to_string(celsius)
  <> " combined="
  <> combined
  <> " rev="
  <> reverse("cba")
  <> " "
  <> smiley
}
