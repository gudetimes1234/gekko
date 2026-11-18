import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Eq, Gt, Lt}
import gleam/pair
import gleam/result
import gleam/string
import gleam/string_tree
import tiny_slug

pub type User {
  User(name: String, score: Int, nickname: Option(String), tags: List(String))
}

pub fn encode_user(user: User) -> String {
  json.object([
    #("name", json.string(user.name)),
    #("score", json.int(user.score)),
    #("nickname", json.nullable(user.nickname, json.string)),
    #("tags", json.array(user.tags, json.string)),
  ])
  |> json.to_string
}

pub fn decode_user(raw: String) -> Result(User, json.DecodeError) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use score <- decode.field("score", decode.int)
    use nickname <- decode.field("nickname", decode.optional(decode.string))
    use tags <- decode.field("tags", decode.list(decode.string))
    decode.success(User(name:, score:, nickname:, tags:))
  }
  json.parse(from: raw, using: decoder)
}

pub fn summarize_scores(raw_values: List(String)) -> #(Int, Int) {
  let parsed =
    raw_values
    |> list.filter_map(int.parse)
    |> list.sort(by: int.compare)
  let total = list.fold(over: parsed, from: 0, with: fn(acc, x) { acc + x })
  let first_large =
    list.find_map(parsed, fn(x) {
      use <- bool.guard(when: x < 10, return: Error(Nil))
      Ok(x)
    })
    |> result.unwrap(0)
  #(total, first_large)
}

pub fn count_tags(tags: List(String)) -> dict.Dict(String, Int) {
  list.fold(over: tags, from: dict.new(), with: fn(acc, tag) {
    dict.upsert(acc, tag, fn(prev) {
      case prev {
        Some(n) -> n + 1
        None -> 1
      }
    })
  })
}

pub fn format_badge(name: String, active: Bool, ratio: Float) -> String {
  let flag = bool.and(active, ratio >. 0.5)
  let cmp = case float.compare(ratio, 1.0) {
    Lt -> "lt"
    Eq -> "eq"
    Gt -> "gt"
  }
  let p =
    pair.new(tiny_slug.slugify(name), flag)
    |> pair.map_second(bool.to_string)
  string_tree.new()
  |> string_tree.append(pair.first(p))
  |> string_tree.append(":")
  |> string_tree.append(pair.second(p))
  |> string_tree.append(":")
  |> string_tree.append(cmp)
  |> string_tree.to_string
}

pub fn check_bytes_and_log(text: String) -> Result(String, Nil) {
  let bits = bit_array.from_string(text)
  let _ = io.println
  use decoded <- result.try(bit_array.to_string(bits))
  let opt = option.Some(decoded) |> option.map(string.uppercase)
  option.to_result(opt, Nil)
}

pub fn reverse_through_dep(items: List(Int)) -> List(Int) {
  tiny_slug.reverse_list(items)
}
