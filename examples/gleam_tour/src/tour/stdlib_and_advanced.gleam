import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/pair
import gleam/result
import gleam/string_tree

/// Constructorless external type
pub type DateTime

@target(javascript)
@external(javascript, "./tour_ffi.mjs", "now")
pub fn js_only_now() -> DateTime

@external(erlang, "lists", "reverse")
pub fn reverse_list(items: List(e)) -> List(e) {
  tail_recursive_reverse(items, [])
}

fn tail_recursive_reverse(items: List(e), reversed: List(e)) -> List(e) {
  case items {
    [] -> reversed
    [first, ..rest] -> tail_recursive_reverse(rest, [first, ..reversed])
  }
}

pub type Account {
  Account(username: String, role: String)
}

pub fn run_stdlib() -> String {
  // List module
  let ints = [0, 1, 2, 3, 4, 5]
  assert list.map(ints, fn(x) { x * 2 }) == [0, 2, 4, 6, 8, 10]
  assert list.filter(ints, fn(x) { x % 2 == 0 }) == [0, 2, 4]
  assert list.fold(ints, 0, fn(count, e) { count + e }) == 15
  assert list.find(ints, fn(x) { x > 3 }) == Ok(4)
  assert list.find(ints, fn(x) { x > 13 }) == Error(Nil)
  assert list.sort([3, 1, 2], int.compare) == [1, 2, 3]

  // Result module
  assert result.map(Ok(1), fn(x) { x * 2 }) == Ok(2)
  assert result.map(Error(1), fn(x) { x * 2 }) == Error(1)
  assert result.try(Ok("1"), int.parse) == Ok(1)
  assert result.unwrap(Error(Nil), "default") == "default"
  let rem_res =
    int.parse("-1234")
    |> result.map(int.absolute_value)
    |> result.try(int.remainder(_, 42))
  assert rem_res == Ok(16)

  // Dict module
  let scores =
    dict.from_list([#("Lucy", 13), #("Drew", 15)])
    |> dict.insert("Bushra", 16)
    |> dict.insert("Darius", 14)
    |> dict.delete("Drew")
  assert dict.size(scores) == 3
  assert dict.get(scores, "Bushra") == Ok(16)
  assert dict.get(scores, "Drew") == Error(Nil)

  // Option module
  let opt: Option(String) = Some("Nubi")
  let empty: Option(String) = None
  assert option.unwrap(option.map(opt, fn(s) { s <> "!" }), "") == "Nubi!"
  assert option.is_none(empty)

  // StringTree, BytesTree, BitArray, Order, Pair, Json + Decode
  let st =
    string_tree.from_strings(["Gleam", " ", "Tour"])
    |> string_tree.uppercase
    |> string_tree.to_string
  let bt =
    bytes_tree.from_string("A")
    |> bytes_tree.append_string("B")
    |> bytes_tree.to_bit_array
  assert st == "GLEAM TOUR"
  assert bit_array.to_string(bt) == Ok("AB")
  assert order.negate(order.Lt) == order.Gt
  assert pair.swap(#("left", 1)) == #(1, "left")

  let encoded =
    json.object([
      #("username", json.string("alice")),
      #("role", json.string("admin")),
    ])
    |> json.to_string
  let acc_decoder = {
    use username <- decode.field("username", decode.string)
    use role <- decode.field("role", decode.string)
    decode.success(Account(username:, role:))
  }
  assert json.parse(from: encoded, using: acc_decoder)
    == Ok(Account(username: "alice", role: "admin"))

  "list_fold=15 rem="
  <> int.to_string(result.unwrap(rem_res, -1))
  <> " dict_size="
  <> int.to_string(dict.size(scores))
}

pub fn run_advanced() -> String {
  // Use syntax equivalence
  assert with_use() == without_use()
  assert with_use() == Ok("Welcome, alice")

  // Let assert & bool assert (with and without `as`)
  let first_el = unsafely_get_first_element([123, 456])
  assert first_el == 123
  assert add(1, 2) == 3
  assert add(1, 2) < add(1, 3)
  assert add(6, 2) == add(2, 6) as "Addition should be commutative"

  // Echo (with silent assertion of pass-through value)
  let echoed = echo_silent(77)
  assert echoed == 77

  // Fallback external body
  assert reverse_list([1, 2, 3, 4, 5]) == [5, 4, 3, 2, 1]
  assert reverse_list(["a", "b", "c"]) == ["c", "b", "a"]

  // Panic / Todo safe branch
  assert check_score(100_000) == "High score!"
  assert check_score(10) == "Still working on it"

  "use=Welcome, alice first="
  <> int.to_string(first_el)
  <> " rev="
  <> string_join_ints(reverse_list([1, 2, 3, 4, 5]))
}

pub fn with_use() -> Result(String, Nil) {
  use username <- result.try(get_username())
  use password <- result.try(get_password())
  use greeting <- result.map(log_in(username, password))
  greeting <> ", " <> username
}

pub fn without_use() -> Result(String, Nil) {
  result.try(get_username(), fn(username) {
    result.try(get_password(), fn(password) {
      result.map(log_in(username, password), fn(greeting) {
        greeting <> ", " <> username
      })
    })
  })
}

fn get_username() -> Result(String, Nil) {
  Ok("alice")
}

fn get_password() -> Result(String, Nil) {
  Ok("hunter2")
}

fn log_in(_username: String, _password: String) -> Result(String, Nil) {
  Ok("Welcome")
}

pub fn todo_with_reason() -> Int {
  todo as "I haven't written this code yet!"
}

pub fn todo_without_reason() -> Int {
  todo
}

pub fn check_score(score: Int) -> String {
  case score {
    s if s > 1000 -> "High score!"
    s if s > 0 -> "Still working on it"
    _ -> panic as "Scores should never be negative!"
  }
}

pub fn unsafely_get_first_element(items: List(a)) -> a {
  let assert [first, ..] = items as "List should not be empty"
  first
}

fn add(a: Int, b: Int) -> Int {
  a + b
}

fn echo_silent(x: Int) -> Int {
  echo x as ""
}

fn string_join_ints(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x] -> int.to_string(x)
    [x, ..rest] -> int.to_string(x) <> "," <> string_join_ints(rest)
  }
}
