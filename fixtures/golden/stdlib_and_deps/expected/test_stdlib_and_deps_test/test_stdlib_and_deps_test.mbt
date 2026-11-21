///|
pub fn json_roundtrip_test() -> Unit {
  let u = @stdlib_and_deps.User(name="Akira", score=42L, nickname=Some("Aki"), tags=@gprelude.Cons("gleam", @gprelude.Cons("wasm", @gprelude.Nil)))
  let encoded = @stdlib_and_deps.encode_user(u)
  if !((@stdlib_and_deps.decode_user(encoded) == Ok(u))) {
    @prelude.abort("assertion failed")
  }
  let u2 = @stdlib_and_deps.User(name="Rei", score=7L, nickname=None, tags=@gprelude.Nil)
  let encoded2 = @stdlib_and_deps.encode_user(u2)
  if !((@stdlib_and_deps.decode_user(encoded2) == Ok(u2))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "json_roundtrip_test" {
  @prelude.ignore(json_roundtrip_test())
}

///|
pub fn list_bool_and_int_test() -> Unit {
  if !((@stdlib_and_deps.summarize_scores(@gprelude.Cons("bad", @gprelude.Cons("3", @gprelude.Cons("15", @gprelude.Cons("7", @gprelude.Cons("20", @gprelude.Nil)))))) == (45L, 15L))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "list_bool_and_int_test" {
  @prelude.ignore(list_bool_and_int_test())
}

///|
pub fn dict_upsert_and_fold_test() -> Unit {
  let counts = @stdlib_and_deps.count_tags(@gprelude.Cons("a", @gprelude.Cons("b", @gprelude.Cons("a", @gprelude.Cons("c", @gprelude.Cons("a", @gprelude.Nil))))))
  if !((@dict.get(counts, "a") == Ok(3L))) {
    @prelude.abort("assertion failed")
  }
  if !((@dict.get(counts, "b") == Ok(1L))) {
    @prelude.abort("assertion failed")
  }
  if !((@dict.get(counts, "missing") == Err(()))) {
    @prelude.abort("assertion failed")
  }
  let sum = @dict.fold(counts, 0L, fn(acc : Int64, _, v : Int64) {
  (acc + v)
})
  if !((sum == 5L)) {
    @prelude.abort("assertion failed")
  }
}

///|
test "dict_upsert_and_fold_test" {
  @prelude.ignore(dict_upsert_and_fold_test())
}

///|
pub fn dep_slug_tree_and_bits_test() -> Unit {
  if !((@stdlib_and_deps.format_badge("  Hello Gleam  ", true, 0.75) == "hello-gleam:True:lt")) {
    @prelude.abort("assertion failed")
  }
  if !((@stdlib_and_deps.format_badge("Hi", false, 1.0) == "hi:False:eq")) {
    @prelude.abort("assertion failed")
  }
  if !((@stdlib_and_deps.check_bytes_and_log("moonbeam") == Ok("MOONBEAM"))) {
    @prelude.abort("assertion failed")
  }
  if !((@stdlib_and_deps.reverse_through_dep(@gprelude.Cons(1L, @gprelude.Cons(2L, @gprelude.Cons(3L, @gprelude.Nil)))) == @list.reverse(@gprelude.Cons(1L, @gprelude.Cons(2L, @gprelude.Cons(3L, @gprelude.Nil)))))) {
    @prelude.abort("assertion failed")
  }
}

///|
test "dep_slug_tree_and_bits_test" {
  @prelude.ignore(dep_slug_tree_and_bits_test())
}
