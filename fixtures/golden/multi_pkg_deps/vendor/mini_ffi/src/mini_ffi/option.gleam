/// @external_type(moonbit, "builtin", "Option")
pub type Option(a) {
  Some(a)
  None
}

pub fn map(over option: Option(a), with fun: fn(a) -> b) -> Option(b) {
  case option {
    Some(value) -> Some(fun(value))
    None -> None
  }
}

pub fn to_result(option: Option(a), or error: e) -> Result(a, e) {
  case option {
    Some(value) -> Ok(value)
    None -> Error(error)
  }
}
