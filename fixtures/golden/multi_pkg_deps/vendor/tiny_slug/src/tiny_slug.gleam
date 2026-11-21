import mini_ffi/text

/// Turn a title string into a URL-friendly slug.
pub fn slugify(title: String) -> String {
  text.trim_lower_dash(title)
}

/// Reverse a list, falling back to pure Gleam when Erlang BIFs are unavailable.
@external(erlang, "lists", "reverse")
pub fn reverse_list(items: List(a)) -> List(a) {
  do_reverse(items, [])
}

fn do_reverse(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [head, ..tail] -> do_reverse(tail, [head, ..acc])
  }
}

@target(javascript)
pub fn js_only_note() -> String {
  "js"
}
