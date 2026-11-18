pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn safe_div(a: Int, b: Int) -> Int {
  a / b
}

pub fn safe_rem(a: Int, b: Int) -> Int {
  a % b
}

pub fn safe_fdiv(a: Float, b: Float) -> Float {
  a /. b
}

pub fn sum_list(items: List(Int), acc: Int) -> Int {
  case items {
    [] -> acc
    [x, ..rest] -> sum_list(rest, acc + x)
  }
}

pub fn reverse_list(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [x, ..rest] -> reverse_list(rest, [x, ..acc])
  }
}

pub fn factorial(n: Int, acc: Int) -> Int {
  case n <= 1 {
    True -> acc
    False -> factorial(n - 1, acc * n)
  }
}

pub fn build_range(n: Int, acc: List(Int)) -> List(Int) {
  case n <= 0 {
    True -> acc
    False -> build_range(n - 1, [n, ..acc])
  }
}
