import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/io
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
  io.println("=== Standard Library: List Module ===")
  let ints = [0, 1, 2, 3, 4, 5]
  let doubled = list.map(ints, fn(x) { x * 2 })
  let evens = list.filter(ints, fn(x) { x % 2 == 0 })
  let folded = list.fold(ints, 0, fn(count, e) { count + e })
  let found = list.find(ints, fn(x) { x > 3 })
  let missing = list.find(ints, fn(x) { x > 13 })
  let sorted = list.sort([3, 1, 2], int.compare)
  assert doubled == [0, 2, 4, 6, 8, 10]
  assert evens == [0, 2, 4]
  assert folded == 15
  assert found == Ok(4)
  assert missing == Error(Nil)
  assert sorted == [1, 2, 3]
  echo doubled
  echo evens
  echo folded
  echo found
  echo missing
  echo sorted

  io.println("=== Standard Library: Result Module ===")
  assert result.map(Ok(1), fn(x) { x * 2 }) == Ok(2)
  assert result.map(Error(1), fn(x) { x * 2 }) == Error(1)
  assert result.try(Ok("1"), int.parse) == Ok(1)
  assert result.unwrap(Error(Nil), "default") == "default"
  let rem_res =
    int.parse("-1234")
    |> result.map(int.absolute_value)
    |> result.try(int.remainder(_, 42))
  assert rem_res == Ok(16)
  echo result.map(Ok(1), fn(x) { x * 2 })
  echo result.map(Error(1), fn(x) { x * 2 })
  echo result.try(Ok("1"), int.parse)
  echo result.unwrap(Error(Nil), "default")
  echo rem_res

  io.println("=== Standard Library: Dict & Option Modules ===")
  let single_dict = dict.from_list([#("Lucy", 13)])
  echo single_dict
  let scores =
    dict.from_list([#("Lucy", 13), #("Drew", 15)])
    |> dict.insert("Bushra", 16)
    |> dict.insert("Darius", 14)
    |> dict.delete("Drew")
  assert dict.size(scores) == 3
  assert dict.get(scores, "Bushra") == Ok(16)
  assert dict.get(scores, "Drew") == Error(Nil)
  echo dict.size(scores)
  echo dict.get(scores, "Bushra")
  echo dict.get(scores, "Drew")

  let opt: Option(String) = Some("Nubi")
  let empty: Option(String) = None
  assert option.unwrap(option.map(opt, fn(s) { s <> "!" }), "") == "Nubi!"
  assert option.is_none(empty)
  echo opt
  echo empty
  echo option.map(opt, fn(s) { s <> "!" })

  io.println("=== Standard Library: Trees, Order, Pair, Json & Decode ===")
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
  echo st
  echo bt
  echo order.negate(order.Lt)
  echo pair.swap(#("left", 1))

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
  let parsed_acc = json.parse(from: encoded, using: acc_decoder)
  assert parsed_acc == Ok(Account(username: "alice", role: "admin"))
  io.println(encoded)
  echo parsed_acc

  "list_fold=15 rem="
  <> int.to_string(result.unwrap(rem_res, -1))
  <> " dict_size="
  <> int.to_string(dict.size(scores))
}

pub fn run_advanced() -> String {
  io.println("=== Advanced Features: Use, Assert & Echo ===")
  assert with_use() == without_use()
  assert with_use() == Ok("Welcome, alice")
  echo with_use()
  echo without_use()

  let first_el = unsafely_get_first_element([123, 456])
  assert first_el == 123
  assert add(1, 2) == 3
  assert add(1, 2) < add(1, 3)
  assert add(6, 2) == add(2, 6) as "Addition should be commutative"
  echo first_el

  echo "Echoing a string"
  echo 1 + 2 as "Sum with custom message"
  let _ =
    [1, 2, 3]
    |> list.map(fn(x) { x * 10 })
    |> echo

  io.println("=== Advanced Features: Externals & Safe Panic/Todo Branches ===")
  let rev_nums = reverse_list([1, 2, 3, 4, 5])
  assert rev_nums == [5, 4, 3, 2, 1]
  assert reverse_list(["a", "b", "c"]) == ["c", "b", "a"]
  echo rev_nums as "Reversed via external fallback"
  echo reverse_list(["a", "b", "c"])

  assert check_score(100_000) == "High score!"
  assert check_score(10) == "Still working on it"
  echo check_score(100_000)
  echo check_score(10)

  "use=Welcome, alice first="
  <> int.to_string(first_el)
  <> " rev="
  <> string_join_ints(rev_nums)
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

fn string_join_ints(xs: List(Int)) -> String {
  case xs {
    [] -> ""
    [x] -> int.to_string(x)
    [x, ..rest] -> int.to_string(x) <> "," <> string_join_ints(rest)
  }
}
