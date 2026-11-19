import gleam/bit_array
import gleam/float
import gleam/int
import gleam/io

pub type Season {
  Spring
  Summer
  Autumn
  Winter
}

pub type Person {
  Person(name: String, age: Int, needs_glasses: Bool)
}

pub type SchoolPerson {
  Teacher(name: String, subject: String)
  Student(name: String)
}

pub type TeacherCard {
  TeacherCard(name: String, subject: String, floor: Int, room: Int)
}

pub type Entry {
  AdminEntry(name: String, level: Int)
  GuestEntry(name: String, room: Int)
}

pub type Fish {
  Starfish(name: String, favourite_colour: String)
  Jellyfish(name: String, jiggly: Bool)
}

pub type IceCream {
  IceCream(flavour: String)
}

pub type Box(inner) {
  Full(inner)
  Empty
}

pub const default_name: Box(String) = Full("Annah")

pub const default_level: Box(Int) = Full(10)

pub type PurchaseError {
  NotEnoughMoney(required: Int)
  NotLuckyEnough
}

pub opaque type PositiveInt {
  PositiveInt(inner: Int)
}

pub fn new_positive(i: Int) -> PositiveInt {
  case i >= 0 {
    True -> PositiveInt(i)
    False -> PositiveInt(0)
  }
}

pub fn to_int(i: PositiveInt) -> Int {
  i.inner
}

pub fn run() -> String {
  io.println("=== Data Types: Tuples & Custom Types ===")
  let triple = #(1, 2.2, "three")
  let #(a, _, c) = triple
  assert a == 1
  assert triple.1 == 2.2
  assert c == "three"
  echo triple
  echo triple.1
  echo a
  echo c

  assert weather(Spring) == "Mild"
  assert weather(Autumn) == "Windy"
  echo Spring
  io.println(weather(Spring))
  io.println(weather(Autumn))

  io.println("=== Data Types: Records, Accessors & Updates ===")
  let amy = Person("Amy", 26, True)
  let jared = Person(name: "Jared", age: 31, needs_glasses: True)
  let tom = Person("Tom", 28, needs_glasses: False)
  assert amy.age == 26
  assert jared.name == "Jared"
  assert !tom.needs_glasses
  echo amy
  echo jared.name
  echo tom.needs_glasses

  let teacher = Teacher("Mr Schofield", "Physics")
  let student = Student("Koushiar")
  assert teacher.name == "Mr Schofield"
  assert student.name == "Koushiar"
  echo teacher
  echo student

  assert handle_fish(Starfish("Lucy", "Pink")) == "Pink"
  assert handle_fish(Jellyfish("Blob", True)) == "Blob"
  let IceCream(flavour) = IceCream("strawberry")
  assert flavour == "strawberry"
  echo handle_fish(Starfish("Lucy", "Pink"))
  echo handle_fish(Jellyfish("Blob", True))
  echo IceCream(flavour)

  let t1 = TeacherCard(name: "Mr Dodd", subject: "ICT", floor: 2, room: 2)
  let t2 = TeacherCard(..t1, subject: "PE", room: 6)
  assert t1.room == 2
  assert t2.subject == "PE"
  assert t2.room == 6
  assert t2.name == "Mr Dodd"
  echo t2

  let admin1 = AdminEntry(name: "Ada", level: 1)
  let admin2 = AdminEntry(..admin1, level: 9)
  assert admin2.name == "Ada"
  assert admin2 == AdminEntry(name: "Ada", level: 9)
  echo admin2

  io.println("=== Data Types: Generic Types, Nil, Results & Bit Arrays ===")
  assert default_name == Full("Annah")
  assert default_level == Full(10)
  let empty_box: Box(String) = Empty
  assert empty_box == Empty
  echo default_name
  echo default_level
  echo empty_box

  let nothing = Nil
  assert nothing == Nil
  echo nothing

  assert buy_pastry(10, lucky: True) == Ok(5)
  assert buy_pastry(8, lucky: False) == Error(NotLuckyEnough)
  assert buy_pastry(3, lucky: True) == Error(NotEnoughMoney(required: 5))
  echo buy_pastry(10, lucky: True)
  echo buy_pastry(8, lucky: False)
  echo buy_pastry(3, lucky: True)

  assert <<3>> == <<3:size(8)>>
  let bits16 = <<6147:size(16)>>
  let utf = <<"Hello, Joe!":utf8>>
  let first = <<4>>
  let second = <<2>>
  let joined = <<first:bits, second:bits>>
  assert bit_array.byte_size(bits16) == 2
  assert bit_array.to_string(utf) == Ok("Hello, Joe!")
  assert joined == <<4, 2>>
  echo <<3>>
  echo bits16
  echo joined
  echo bit_array.to_string(utf)

  "tuple1="
  <> float.to_string(triple.1)
  <> " season="
  <> weather(Winter)
  <> " room="
  <> int.to_string(t2.room)
  <> " bits="
  <> int.to_string(bit_array.byte_size(joined))
}

fn weather(season: Season) -> String {
  case season {
    Spring -> "Mild"
    Summer -> "Hot"
    Autumn -> "Windy"
    Winter -> "Cold"
  }
}

fn handle_fish(fish: Fish) -> String {
  case fish {
    Starfish(_, favourite_colour) -> favourite_colour
    Jellyfish(name, ..) -> name
  }
}

fn buy_pastry(money: Int, lucky lucky: Bool) -> Result(Int, PurchaseError) {
  case money >= 5 {
    True ->
      case lucky {
        True -> Ok(money - 5)
        False -> Error(NotLuckyEnough)
      }
    False -> Error(NotEnoughMoney(required: 5))
  }
}
