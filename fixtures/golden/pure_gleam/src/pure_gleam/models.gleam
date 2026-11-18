pub type User {
  Admin(id: Int, name: String, level: Int)
  Guest(id: Int, name: String)
}

pub type Point {
  Point(x: Float, y: Float)
}

pub type Box(a) {
  Box(value: a, label: String)
}

pub type Hook {
  Hook(cb: fn(Int) -> Int)
}

pub fn make_admin(id: Int, name: String) -> User {
  Admin(id:, name:, level: 1)
}

pub fn promote(user: User, new_level: Int) -> User {
  case user {
    Admin(..) -> Admin(..user, level: new_level)
    Guest(id:, name:) -> Admin(id:, name:, level: new_level)
  }
}

pub fn shift_x(p: Point, dx: Float) -> Point {
  Point(..p, x: p.x +. dx)
}
