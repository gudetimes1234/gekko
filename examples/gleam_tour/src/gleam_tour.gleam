import gleam/int
import gleam/io.{println}
import tour/basics
import tour/data_types.{new_positive, to_int}
import tour/flow_control
import tour/functions
import tour/stdlib_and_advanced

pub fn build_tour_report() -> String {
  let positive = new_positive(1)
  let zero = new_positive(0)
  let negative = new_positive(-1)
  assert to_int(positive) == 1
  assert to_int(zero) == 0
  assert to_int(negative) == 0

  let s1 = "[Basics] " <> basics.run()
  let s2 = "[Functions] " <> functions.run()
  let s3 = "[Flow Control] " <> flow_control.run()
  let s4 =
    "[Data Types] "
    <> data_types.run()
    <> " opaque="
    <> int.to_string(to_int(negative))
  let s5 = "[Standard Library] " <> stdlib_and_advanced.run_stdlib()
  let s6 = "[Advanced Features] " <> stdlib_and_advanced.run_advanced()
  let s7 = "[Gleam Tour Complete]"

  s1
  <> "\n"
  <> s2
  <> "\n"
  <> s3
  <> "\n"
  <> s4
  <> "\n"
  <> s5
  <> "\n"
  <> s6
  <> "\n"
  <> s7
}

pub fn main() -> Nil {
  io.println("Hello, Joe!")
  println(build_tour_report())
}
