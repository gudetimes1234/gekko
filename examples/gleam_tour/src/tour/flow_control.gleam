import gleam/float
import gleam/int
import gleam/io
import gleam/list

pub fn run() -> String {
  io.println("=== Flow Control: Case Expressions & Variable Patterns ===")
  let rand_i = int.random(5)
  assert rand_i >= 0 && rand_i < 5
  echo rand_i
  let rand_f = float.random()
  assert rand_f >=. 0.0 && rand_f <. 1.0
  echo rand_f

  assert classify_zero_one(0) == "Zero"
  assert classify_zero_one(1) == "One"
  assert classify_zero_one(4) == "It is 4"
  echo classify_zero_one(0)
  echo classify_zero_one(1)
  echo classify_zero_one(4)

  io.println("=== Flow Control: String & List Patterns ===")
  assert get_name("Hello, Joe") == "Joe"
  assert get_name("Hello, Mike") == "Mike"
  assert get_name("System still working?") == "Unknown"
  io.println(get_name("Hello, Joe"))
  io.println(get_name("Hello, Mike"))
  io.println(get_name("System still working?"))

  assert describe_list([]) == "Empty list"
  assert describe_list([1]) == "List of just 1"
  assert describe_list([4, 9, 10]) == "List starting with 4"
  assert describe_list([2, 3]) == "List of 2 elements"
  assert describe_list([7, 8, 9]) == "Some other list"
  echo describe_list([])
  echo describe_list([1])
  echo describe_list([4, 9, 10])
  echo describe_list([2, 3])
  echo describe_list([7, 8, 9])

  io.println("=== Flow Control: Recursion & Tail Calls ===")
  assert factorial(5) == 120
  assert factorial(7) == 5040
  assert factorial_tail(5) == 120
  assert factorial_tail(7) == 5040
  assert sum_list([18, 56, 35, 85, 91], 0) == 285
  echo factorial(5)
  echo factorial_tail(7)
  echo sum_list([18, 56, 35, 85, 91], 0)

  io.println(
    "=== Flow Control: Multi-Subject, Alternatives, Aliases & Guards ===",
  )
  assert check_pair(0, 0) == "Both are zero"
  assert check_pair(0, 3) == "First is zero"
  assert check_pair(2, 0) == "Second is zero"
  assert check_pair(2, 3) == "Neither are zero"
  echo check_pair(0, 0)
  echo check_pair(2, 3)

  assert parity_label(4) == "This is an even number"
  assert parity_label(7) == "This is an odd number"
  assert parity_label(9) == "I'm not sure"
  echo parity_label(4)
  echo parity_label(7)
  echo parity_label(9)

  assert get_first_non_empty([[], [1, 2, 3], [4, 5]]) == [1, 2, 3]
  assert get_first_non_empty([[1, 2], [3, 4, 5], []]) == [1, 2]
  assert get_first_non_empty([[], [], []]) == []
  echo get_first_non_empty([[], [1, 2, 3], [4, 5]])
  echo get_first_non_empty([[], [], []])

  let numbers = [1, 2, 3, 4, 5]
  assert get_first_larger(numbers, 3) == 4
  assert get_first_larger(numbers, 5) == 0
  echo get_first_larger(numbers, 3)
  echo get_first_larger(numbers, 5)

  let repeated = list.repeat(1, times: 2)
  assert repeated == [1, 1]
  echo repeated

  "fact7="
  <> int.to_string(factorial_tail(7))
  <> " sum="
  <> int.to_string(sum_list([18, 56, 35, 85, 91], 0))
  <> " name="
  <> get_name("Hello, Joe")
  <> " guard="
  <> int.to_string(get_first_larger(numbers, 3))
}

fn classify_zero_one(x: Int) -> String {
  case x {
    0 -> "Zero"
    1 -> "One"
    other -> "It is " <> int.to_string(other)
  }
}

fn get_name(x: String) -> String {
  case x {
    "Hello, " <> name -> name
    _ -> "Unknown"
  }
}

fn describe_list(xs: List(Int)) -> String {
  case xs {
    [] -> "Empty list"
    [1] -> "List of just 1"
    [4, ..] -> "List starting with 4"
    [_, _] -> "List of 2 elements"
    _ -> "Some other list"
  }
}

pub fn factorial(x: Int) -> Int {
  case x {
    0 -> 1
    1 -> 1
    _ -> x * factorial(step_towards_zero(x))
  }
}

fn step_towards_zero(x: Int) -> Int {
  case x >= 0 {
    True -> x - 1
    False -> x + 1
  }
}

pub fn factorial_tail(x: Int) -> Int {
  factorial_loop(x, 1)
}

fn factorial_loop(x: Int, accumulator: Int) -> Int {
  case x {
    0 -> accumulator
    1 -> accumulator
    _ -> factorial_loop(x - 1, accumulator * x)
  }
}

fn sum_list(xs: List(Int), total: Int) -> Int {
  case xs {
    [first, ..rest] -> sum_list(rest, total + first)
    [] -> total
  }
}

fn check_pair(x: Int, y: Int) -> String {
  case x, y {
    0, 0 -> "Both are zero"
    0, _ -> "First is zero"
    _, 0 -> "Second is zero"
    _, _ -> "Neither are zero"
  }
}

fn parity_label(number: Int) -> String {
  case number {
    2 | 4 | 6 | 8 -> "This is an even number"
    1 | 3 | 5 | 7 -> "This is an odd number"
    _ -> "I'm not sure"
  }
}

fn get_first_non_empty(lists: List(List(t))) -> List(t) {
  case lists {
    [[_, ..] as first, ..] -> first
    [_, ..rest] -> get_first_non_empty(rest)
    [] -> []
  }
}

fn get_first_larger(numbers: List(Int), limit: Int) -> Int {
  case numbers {
    [first, ..] if first > limit -> first
    [_, ..rest] -> get_first_larger(rest, limit)
    [] -> 0
  }
}
