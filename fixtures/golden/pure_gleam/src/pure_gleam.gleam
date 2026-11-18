import pure_gleam/math
import pure_gleam/models.{type Point, type User, Box, Hook}

fn private_pair_double(a, b) {
  #(a * 2, b * 2)
}

fn with_tag(tag: String, next: fn(String) -> b) -> b {
  next("[" <> tag <> "]")
}

fn loop(x: Int) -> Int {
  let match = x + 1
  match * 2
}

pub fn run_pipeline(x: Int) -> Int {
  let add_ten = math.add(10, _)
  let #(d1, d2) = private_pair_double(x, 3)
  let base =
    d1
    |> math.add(d2)
    |> add_ten
  base + loop(1)
}

pub fn parse_command(input: String) -> Result(String, String) {
  use prefix <- with_tag("cmd")
  case input {
    "cmd:" <> rest if rest != "" -> Ok(prefix <> ":" <> rest)
    "cmd:" <> _ -> Error("empty")
    _ -> Error("unknown")
  }
}

pub fn check_user(user: User, p: Point) -> #(Int, String, Point, Int) {
  let promoted = models.promote(user, 10)
  let shifted = models.shift_x(p, 5.0)
  let b = Box(value: 42, label: "ok")
  let h = Hook(cb: fn(n) { n + b.value })
  let Hook(cb: f) = h
  #(promoted.id, promoted.name, shifted, f(8))
}

pub fn check_assert_and_bits(res: Result(Int, String)) -> Int {
  let assert Ok(v) = res
  let _bits = <<"gekko":utf8, 1:size(8)>>
  v + math.safe_div(10, 0) + math.safe_rem(10, 0)
}
