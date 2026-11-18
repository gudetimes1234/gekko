import gleeunit
import pure_gleam
import pure_gleam/math
import pure_gleam/models.{Admin, Point}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn golden_math_and_tco_test() {
  assert math.safe_div(10, 0) == 0
  assert math.safe_rem(10, 0) == 0
  assert math.safe_fdiv(5.0, 0.0) == 0.0
  assert math.factorial(6, 1) == 720
  assert math.reverse_list([1, 2, 3], []) == [3, 2, 1]

  // Stress TCO on a 10,000-element list (would overflow stack without for-loop TCO)
  let big = math.build_range(10_000, [])
  assert math.sum_list(big, 0) == 50_005_000
}

pub fn golden_pipeline_use_and_strings_test() {
  // private_pair_double(4, 3) -> (8, 6); 8 + 6 + 10 + loop(1)=4 -> 28
  assert pure_gleam.run_pipeline(4) == 28
  assert pure_gleam.parse_command("cmd:build") == Ok("[cmd]:build")
  assert pure_gleam.parse_command("cmd:") == Error("empty")
  assert pure_gleam.parse_command("other") == Error("unknown")
}

pub fn golden_models_getters_and_updates_test() {
  let admin = models.make_admin(7, "Ada")
  let p = Point(x: 1.5, y: 2.5)
  let #(id, name, shifted, hook_val) = pure_gleam.check_user(admin, p)
  assert id == 7
  assert name == "Ada"
  assert shifted.x == 6.5
  assert shifted.y == 2.5
  assert hook_val == 50

  let promoted = models.promote(admin, 99)
  assert promoted == Admin(id: 7, name: "Ada", level: 99)
}

pub fn golden_assert_and_bits_test() {
  assert pure_gleam.check_assert_and_bits(Ok(21)) == 21
}
