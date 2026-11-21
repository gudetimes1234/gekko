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
pub fn format_user(user : User) -> String {
  let nick = match user.nickname() {
  Some(n) => n
  None => "none"
}
  ((((user.name() + ":") + @text.int_to_string(user.score())) + ":") + nick)
}

///|
pub fn count_tags(tags : @gprelude.GList[String]) -> @kv.MiniMap[String, Int64] {
  count_tags_loop(tags, @kv.new())
}

///|
fn count_tags_loop(tags : @gprelude.GList[String], acc : @kv.MiniMap[String, Int64]) -> @kv.MiniMap[String, Int64] {
  for tags = tags, acc = acc {
    match tags {
      @gprelude.Nil => break acc
      @gprelude.Cons(tag, rest) => continue rest, @kv.upsert(acc, tag, fn(prev) {
  match prev {
    Some(n) => (n + 1L)
    None => 1L
  }
})
    }
  }
}

///|
pub fn format_badge(name : String, active : Bool, score : Int64) -> String {
  let flag = match active {
  true => "True"
  false => "False"
}
  ((((@tiny_slug.slugify(name) + ":") + flag) + ":") + @text.int_to_string(score))
}

///|
pub fn check_bytes(input : String) -> Result[String, Unit] {
  let bits = @text.to_bits(input)
  match @text.from_bits(bits) {
    Ok(decoded) => @option.to_result(@option.map(Some(decoded), @text.uppercase), ())
    Err(_) => Err(())
  }
}

///|
pub fn reverse_through_dep(items : @gprelude.GList[Int64]) -> @gprelude.GList[Int64] {
  @tiny_slug.reverse_list(items)
}
