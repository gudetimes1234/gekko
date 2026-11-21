///|
#derive(Eq, Debug, Hash)
pub(all) enum User {
  User(name~ : String, score~ : Int64, nickname~ : Option[String], tags~ : @gprelude.GList[String])
}

///|
pub impl @gprelude.GleamInspect for User with gleam_inspect(self) {
  match self {
    User(name=f0, score=f1, nickname=f2, tags=f3) => "User(" + @gprelude.GleamInspect::gleam_inspect(f0) + ", " + @gprelude.GleamInspect::gleam_inspect(f1) + ", " + @gprelude.GleamInspect::gleam_inspect(f2) + ", " + @gprelude.GleamInspect::gleam_inspect(f3) + ")"
  }
}

///|
pub fn User::name(self : User) -> String {
  match self {
    User(name~, ..) => name
  }
}

///|
pub fn User::nickname(self : User) -> Option[String] {
  match self {
    User(nickname~, ..) => nickname
  }
}

///|
pub fn User::score(self : User) -> Int64 {
  match self {
    User(score~, ..) => score
  }
}

///|
pub fn User::tags(self : User) -> @gprelude.GList[String] {
  match self {
    User(tags~, ..) => tags
  }
}

///|
pub fn encode_user(user : User) -> String {
  @json.to_string(@json.object(@gprelude.Cons(("name", @json.string(user.name())), @gprelude.Cons(("score", @json.int(user.score())), @gprelude.Cons(("nickname", @json.nullable(user.nickname(), @json.string)), @gprelude.Cons(("tags", @json.array(user.tags(), @json.string)), @gprelude.Nil))))))
}

///|
pub fn decode_user(raw : String) -> Result[User, @json.DecodeError] {
  let decoder = {
  @decode.field("name", @decode.string, fn(name) {
  @decode.field("score", @decode.int, fn(score) {
  @decode.field("nickname", @decode.optional(@decode.string), fn(nickname) {
  @decode.field("tags", @decode.list(@decode.string), fn(tags) {
  @decode.success(User(name=name, score=score, nickname=nickname, tags=tags))
})
})
})
})
}
  @json.parse(raw, decoder)
}

///|
pub fn summarize_scores(raw_values : @gprelude.GList[String]) -> (Int64, Int64) {
  let parsed = @list.sort(@list.filter_map(raw_values, @int.parse), @int.compare)
  let total = @list.fold(parsed, 0L, fn(acc : Int64, x : Int64) {
  (acc + x)
})
  let first_large = @result.unwrap(@list.find_map(parsed, fn(x : Int64) {
  @bool.guard_((x < 10L), Err(()), fn() {
  Ok(x)
})
}), 0L)
  (total, first_large)
}

///|
pub fn count_tags(tags : @gprelude.GList[String]) -> @dict.Dict[String, Int64] {
  @list.fold(tags, @dict.new(), fn(acc, tag) {
  @dict.upsert(acc, tag, fn(prev) {
  match prev {
    Some(n) => (n + 1L)
    None => 1L
  }
})
})
}

///|
pub fn format_badge(name : String, active : Bool, ratio : Double) -> String {
  let flag = @bool.and_(active, (ratio > 0.5))
  let cmp = match @float.compare(ratio, 1.0) {
  @order.Lt => "lt"
  @order.Eq => "eq"
  @order.Gt => "gt"
}
  let p = @pair.map_second(@pair.new(@tiny_slug.slugify(name), flag), @bool.to_string)
  @string_tree.to_string(@string_tree.append(@string_tree.append(@string_tree.append(@string_tree.append(@string_tree.append(@string_tree.new(), @pair.first(p)), ":"), @pair.second(p)), ":"), cmp))
}

///|
pub fn check_bytes_and_log(text : String) -> Result[String, Unit] {
  let bits = @bit_array.from_string(text)
  let _ = @io.println_
  @result.try_(@bit_array.to_string(bits), fn(decoded) {
  let opt = @option.map(Some(decoded), @string.uppercase)
  @option.to_result(opt, ())
})
}

///|
pub fn reverse_through_dep(items : @gprelude.GList[Int64]) -> @gprelude.GList[Int64] {
  @tiny_slug.reverse_list(items)
}
