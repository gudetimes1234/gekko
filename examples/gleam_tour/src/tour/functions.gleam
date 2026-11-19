//// Functions & Closures module matching the Gleam Language Tour.

import gleam/float
import gleam/int
import gleam/io
import gleam/string

/// A type where the value can never be constructed.
pub type Never {
  Never(Never)
}

pub fn run() -> String {
  io.println("=== Functions: Named & Higher-Order ===")
  assert double(10) == 20
  echo double(10)

  assert twice_int(1, add_one) == 3
  let my_function = add_one
  assert my_function(100) == 101
  echo twice_int(1, add_one)
  echo my_function(100)

  io.println("=== Functions: Anonymous & Captures ===")
  let anon_add_one = fn(a) { a + 1 }
  assert twice_int(1, anon_add_one) == 3
  assert twice_int(1, fn(a) { a * 2 }) == 4
  let secret_number = 42
  let secret = fn() { secret_number }
  assert secret() == 42
  echo twice_int(1, anon_add_one)
  echo twice_int(1, fn(a) { a * 2 })
  echo secret()

  let add_one_v1 = fn(x) { add(1, x) }
  let add_one_v2 = add(1, _)
  assert add_one_v1(10) == 11
  assert add_one_v2(10) == 11
  echo add_one_v1(10)
  echo add_one_v2(10)

  io.println("=== Functions: Generics & Pipelines ===")
  assert twice(10, fn(x) { x + 1 }) == 12
  assert twice("Hello", fn(x) { x <> "!" }) == "Hello!!"
  assert thrice(1, fn(x) { x + 2 }) == 7
  echo twice(10, fn(x) { x + 1 })
  echo twice("Hello", fn(x) { x <> "!" })
  echo thrice(1, fn(x) { x + 2 })

  "Hello, Mike!"
  |> string.drop_end(1)
  |> string.drop_start(7)
  |> io.println
  let piped1_val =
    "Hello, Mike!"
    |> string.drop_end(1)
    |> string.drop_start(7)
  let piped2 =
    "1"
    |> string.append("2")
    |> string.append("3", _)
    |> echo
  assert piped1_val == "Mike"
  assert piped2 == "312"

  io.println("=== Functions: Labelled Arguments, Shorthand & Deprecations ===")
  assert calculate(1, 2, 3) == 5
  assert calculate(1, add: 2, multiply: 3) == 5
  assert calculate(1, multiply: 3, add: 2) == 5
  echo calculate(1, 2, 3)
  echo calculate(1, multiply: 3, add: 2)

  let quantity = 5.0
  let unit_price = 10.0
  let discount = 0.2
  let cost1 =
    calculate_total_cost(
      quantity: quantity,
      unit_price: unit_price,
      discount: discount,
    )
  let cost2 = calculate_total_cost(quantity:, unit_price:, discount:)
  assert cost1 == 40.0
  assert cost2 == 40.0
  echo cost1
  echo cost2

  assert new_function() == "v2"
  echo new_function()

  "double="
  <> int.to_string(double(10))
  <> " piped="
  <> piped1_val
  <> "/"
  <> piped2
  <> " cost="
  <> float.to_string(cost2)
}

fn double(a: Int) -> Int {
  multiply(a, 2)
}

fn multiply(a: Int, b: Int) -> Int {
  a * b
}

fn twice_int(argument: Int, passed_function: fn(Int) -> Int) -> Int {
  passed_function(passed_function(argument))
}

fn add_one(argument: Int) -> Int {
  argument + 1
}

fn add(a: Int, b: Int) -> Int {
  a + b
}

/// Call a function twice with an initial value.
pub fn twice(argument: value, my_function: fn(value) -> value) -> value {
  my_function(my_function(argument))
}

/// Call a function three times with an initial value.
pub fn thrice(argument: value, my_function: fn(value) -> value) -> value {
  my_function(my_function(my_function(argument)))
}

fn calculate(value: Int, add addend: Int, multiply multiplier: Int) -> Int {
  value * multiplier + addend
}

fn calculate_total_cost(
  quantity quantity: Float,
  unit_price price: Float,
  discount discount: Float,
) -> Float {
  let subtotal = quantity *. price
  let discount_amt = subtotal *. discount
  subtotal -. discount_amt
}

@deprecated("Use new_function instead")
pub fn old_function() -> Nil {
  Nil
}

fn new_function() -> String {
  "v2"
}
