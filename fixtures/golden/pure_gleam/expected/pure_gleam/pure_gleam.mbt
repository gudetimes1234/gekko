///|
fn private_pair_double(a : Int64, b : Int64) -> (Int64, Int64) {
  ((a * 2L), (b * 2L))
}

///|
fn[T0] with_tag(tag : String, next : (String) -> T0) -> T0 {
  next((("[" + tag) + "]"))
}

///|
fn loop_(x : Int64) -> Int64 {
  let match_ = (x + 1L)
  (match_ * 2L)
}

///|
pub fn run_pipeline(x : Int64) -> Int64 {
  let add_ten = fn(__capture_0) {
  @math.add(10L, __capture_0)
}
  let (d1, d2) = private_pair_double(x, 3L)
  let base = add_ten(@math.add(d1, d2))
  (base + loop_(1L))
}

///|
pub fn parse_command(input : String) -> Result[String, String] {
  with_tag("cmd", fn(prefix) {
  match input {
    __str_pfx_1 if (@gprelude.string_has_prefix(__str_pfx_1, "cmd:") && ({
  let rest = @gprelude.string_drop_prefix(__str_pfx_1, "cmd:")
  (rest != "")
})) => {
      let rest = @gprelude.string_drop_prefix(__str_pfx_1, "cmd:")
      Ok(((prefix + ":") + rest))
    }
    __str_pfx_2 if @gprelude.string_has_prefix(__str_pfx_2, "cmd:") => Err("empty")
    _ => Err("unknown")
  }
})
}

///|
pub fn check_user(user : @models.User, p : @models.Point) -> (Int64, String, @models.Point, Int64) {
  let promoted = @models.promote(user, 10L)
  let shifted = @models.shift_x(p, 5.0)
  let b = @models.Box(value=42L, label="ok")
  let h = @models.Hook(cb=fn(n) {
  (n + b.value())
})
  guard h is @models.Hook(cb=f) else { @prelude.abort("let pattern match failed") }
  (promoted.id(), promoted.name(), shifted, f(8L))
}

///|
pub fn check_assert_and_bits(res : Result[Int64, String]) -> Int64 {
  guard res is Ok(v) else { @prelude.abort("let assert failed") }
  let _ = @gprelude.bit_array_from_segments([@gprelude.BitArray::from_string("gekko"), @gprelude.BitArray::int_segment(1L, 8L, true)])
  ((v + @math.safe_div(10L, 0L)) + @math.safe_rem(10L, 0L))
}
