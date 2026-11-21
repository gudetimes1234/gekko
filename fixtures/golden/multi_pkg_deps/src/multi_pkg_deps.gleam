import mini_ffi/kv
import mini_ffi/option.{type Option, None, Some}
import mini_ffi/text
import tiny_slug

pub type User {
  User(name: String, score: Int, nickname: Option(String), tags: List(String))
}

pub fn format_user(user: User) -> String {
  let nick = case user.nickname {
    Some(n) -> n
    None -> "none"
  }
  user.name <> ":" <> text.int_to_string(user.score) <> ":" <> nick
}

pub fn count_tags(tags: List(String)) -> kv.MiniMap(String, Int) {
  count_tags_loop(tags, kv.new())
}

fn count_tags_loop(
  tags: List(String),
  acc: kv.MiniMap(String, Int),
) -> kv.MiniMap(String, Int) {
  case tags {
    [] -> acc
    [tag, ..rest] ->
      count_tags_loop(
        rest,
        kv.upsert(in: acc, update: tag, with: fn(prev) {
          case prev {
            Some(n) -> n + 1
            None -> 1
          }
        }),
      )
  }
}

pub fn format_badge(name: String, active: Bool, score: Int) -> String {
  let flag = case active {
    True -> "True"
    False -> "False"
  }
  tiny_slug.slugify(name) <> ":" <> flag <> ":" <> text.int_to_string(score)
}

pub fn check_bytes(input: String) -> Result(String, Nil) {
  let bits = text.to_bits(input)
  case text.from_bits(bits) {
    Ok(decoded) ->
      Some(decoded)
      |> option.map(text.uppercase)
      |> option.to_result(Nil)
    Error(Nil) -> Error(Nil)
  }
}

pub fn reverse_through_dep(items: List(Int)) -> List(Int) {
  tiny_slug.reverse_list(items)
}
