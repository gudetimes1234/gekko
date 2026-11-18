import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import stdlib_and_deps.{User}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn json_roundtrip_test() {
  let u =
    User(name: "Akira", score: 42, nickname: Some("Aki"), tags: [
      "gleam",
      "wasm",
    ])
  let encoded = stdlib_and_deps.encode_user(u)
  assert stdlib_and_deps.decode_user(encoded) == Ok(u)

  let u2 = User(name: "Rei", score: 7, nickname: None, tags: [])
  let encoded2 = stdlib_and_deps.encode_user(u2)
  assert stdlib_and_deps.decode_user(encoded2) == Ok(u2)
}

pub fn list_bool_and_int_test() {
  assert stdlib_and_deps.summarize_scores(["bad", "3", "15", "7", "20"])
    == #(45, 15)
}

pub fn dict_upsert_and_fold_test() {
  let counts = stdlib_and_deps.count_tags(["a", "b", "a", "c", "a"])
  assert dict.get(counts, "a") == Ok(3)
  assert dict.get(counts, "b") == Ok(1)
  assert dict.get(counts, "missing") == Error(Nil)
  let sum = dict.fold(over: counts, from: 0, with: fn(acc, _k, v) { acc + v })
  assert sum == 5
}

pub fn dep_slug_tree_and_bits_test() {
  assert stdlib_and_deps.format_badge("  Hello Gleam  ", True, 0.75)
    == "hello-gleam:True:lt"
  assert stdlib_and_deps.format_badge("Hi", False, 1.0) == "hi:False:eq"
  assert stdlib_and_deps.check_bytes_and_log("moonbeam") == Ok("MOONBEAM")
  assert stdlib_and_deps.reverse_through_dep([1, 2, 3])
    == list.reverse([1, 2, 3])
}
