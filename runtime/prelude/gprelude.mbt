///|
#derive(Eq, Debug, Hash)
pub(all) enum GList[T] {
  Nil
  Cons(T, GList[T])
}

///|
pub fn[T] GList::to_array(self : GList[T]) -> Array[T] {
  let out : Array[T] = []
  for cur = self {
    match cur {
      Nil => break out
      Cons(head, tail) => {
        out.push(head)
        continue tail
      }
    }
  }
}

///|
pub fn[T] GList::from_array(arr : ArrayView[T]) -> GList[T] {
  let mut acc : GList[T] = Nil
  let mut i = arr.length() - 1
  while i >= 0 {
    acc = Cons(arr[i], acc)
    i = i - 1
  }
  acc
}

///|
pub fn[T] GList::length(self : GList[T]) -> Int64 {
  for cur = self, count = 0L {
    match cur {
      Nil => break count
      Cons(_, tail) => continue tail, count + 1L
    }
  }
}

///|
pub fn[T] GList::reverse(self : GList[T]) -> GList[T] {
  for cur = self, acc = Nil {
    match cur {
      Nil => break acc
      Cons(head, tail) => continue tail, Cons(head, acc)
    }
  }
}

///|
#derive(Eq, Debug, Hash)
pub(all) enum Order {
  Lt
  Eq
  Gt
}

///|
#derive(Eq, Debug, Hash)
pub(all) struct UtfCodepoint {
  code : Int64
}

///|
pub impl GleamInspect for UtfCodepoint with gleam_inspect(self) {
  "UtfCodepoint(" + self.code.to_string() + ")"
}

///|
#derive(Eq, Debug, Hash)
pub(all) struct BitArray {
  data : Bytes
}

///|
pub fn BitArray::empty() -> BitArray {
  { data: b"" }
}

///|
pub fn BitArray::from_bytes(b : Bytes) -> BitArray {
  { data: b }
}

///|
pub fn BitArray::from_string(s : String) -> BitArray {
  { data: @utf8.encode(s) }
}

///|
pub fn BitArray::byte_size(self : BitArray) -> Int64 {
  self.data.length().to_int64()
}

///|
pub fn BitArray::concat(parts : ArrayView[BitArray]) -> BitArray {
  let buf = @buffer.Buffer()
  for part in parts {
    buf.write_bytesview(part.data[:])
  }
  { data: buf.to_bytes() }
}

///|
pub fn bit_array_from_segments(parts : ArrayView[BitArray]) -> BitArray {
  BitArray::concat(parts)
}

///|
pub fn BitArray::int_segment(
  val : Int64,
  bits : Int64,
  big_endian : Bool,
) -> BitArray {
  let buf = @buffer.Buffer()
  if bits == 8L {
    buf.write_byte(val.to_byte())
  } else if bits == 16L {
    let hi = (val >> 8).to_byte()
    let lo = val.to_byte()
    if big_endian {
      buf.write_byte(hi)
      buf.write_byte(lo)
    } else {
      buf.write_byte(lo)
      buf.write_byte(hi)
    }
  } else if bits == 32L {
    if big_endian {
      buf.write_int_be(val.to_int())
    } else {
      buf.write_int_le(val.to_int())
    }
  } else if bits == 64L {
    if big_endian {
      buf.write_int64_be(val)
    } else {
      buf.write_int64_le(val)
    }
  } else {
    @prelude.abort("unsupported non-byte-aligned bit segment width in Tier 1 BitArray")
  }
  { data: buf.to_bytes() }
}

///|
pub fn BitArray::float_segment(
  val : Double,
  bits : Int64,
  big_endian : Bool,
) -> BitArray {
  let buf = @buffer.Buffer()
  if bits == 32L {
    let f = Float::from_double(val)
    if big_endian {
      buf.write_float_be(f)
    } else {
      buf.write_float_le(f)
    }
  } else if bits == 64L {
    if big_endian {
      buf.write_double_be(val)
    } else {
      buf.write_double_le(val)
    }
  } else {
    @prelude.abort("unsupported float bit segment width in BitArray")
  }
  { data: buf.to_bytes() }
}

///|
pub fn BitArray::slice(
  self : BitArray,
  at : Int64,
  take : Int64,
) -> Result[BitArray, Unit] {
  let len = self.data.length().to_int64()
  let start = if at < 0L { len + at } else { at }
  if start < 0L || take < 0L || start + take > len {
    Err(())
  } else {
    let view = self.data[start.to_int():(start + take).to_int()]
    Ok({ data: Bytes::from_iter(view.iter()) })
  }
}

///|
#derive(Eq, Debug)
pub(all) enum Dynamic {
  DynNull
  DynBool(Bool)
  DynInt(Int64)
  DynFloat(Double)
  DynString(String)
  DynBitArray(BitArray)
  DynList(GList[Dynamic])
  DynArray(Array[Dynamic])
  DynMap(Map[Dynamic, Dynamic])
}

///|
pub impl Hash for Dynamic with hash_combine(self, hasher) {
  match self {
    DynNull => hasher.combine_int(0)
    DynBool(b) => {
      hasher.combine_int(1)
      hasher.combine(b)
    }
    DynInt(i) => {
      hasher.combine_int(2)
      hasher.combine(i)
    }
    DynFloat(f) => {
      hasher.combine_int(3)
      hasher.combine(f)
    }
    DynString(s) => {
      hasher.combine_int(4)
      hasher.combine(s)
    }
    DynBitArray(ba) => {
      hasher.combine_int(5)
      hasher.combine(ba)
    }
    DynList(xs) => {
      hasher.combine_int(6)
      hasher.combine(xs)
    }
    DynArray(arr) => {
      hasher.combine_int(7)
      hasher.combine_int(arr.length())
      for item in arr {
        hasher.combine(item)
      }
    }
    DynMap(m) => {
      hasher.combine_int(8)
      hasher.combine_int(m.length())
      m.each(fn(k, v) {
        hasher.combine(k)
        hasher.combine(v)
      })
    }
  }
}

///|
pub fn int_div(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    0L
  } else {
    a / b
  }
}

///|
pub fn int_rem(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    0L
  } else {
    a % b
  }
}

///|
pub fn float_div(a : Double, b : Double) -> Double {
  if b == 0.0 {
    0.0
  } else {
    a / b
  }
}

///|
pub fn string_has_prefix(s : String, prefix : String) -> Bool {
  s.has_prefix(prefix)
}

///|
pub fn string_drop_prefix(s : String, prefix : String) -> String {
  if s.has_prefix(prefix) {
    s.unsafe_substring(start=prefix.length(), end=s.length())
  } else {
    s
  }
}

///|
pub(open) trait GleamInspect {
  gleam_inspect(Self) -> String
}

///|
fn escape_gleam_string(s : String) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for ch in s {
    match ch {
      '\\' => buf.write_string("\\\\")
      '"' => buf.write_string("\\\"")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(ch)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
pub impl GleamInspect for Int64 with gleam_inspect(self) {
  self.to_string()
}

///|
pub impl GleamInspect for Double with gleam_inspect(self) {
  let s = self.to_string()
  if s.contains(".") || s.contains("e") || s.contains("E") {
    s
  } else {
    s + ".0"
  }
}

///|
pub impl GleamInspect for Bool with gleam_inspect(self) {
  if self {
    "True"
  } else {
    "False"
  }
}

///|
pub impl GleamInspect for Unit with gleam_inspect(_) {
  "Nil"
}

///|
pub impl GleamInspect for String with gleam_inspect(self) {
  escape_gleam_string(self)
}

///|
pub impl GleamInspect for BitArray with gleam_inspect(self) {
  let buf = StringBuilder()
  buf.write_string("<<")
  let mut i = 0
  while i < self.data.length() {
    if i > 0 {
      buf.write_string(", ")
    }
    buf.write_string(self.data[i].to_int().to_string())
    i = i + 1
  }
  buf.write_string(">>")
  buf.to_string()
}

///|
pub impl[T : GleamInspect] GleamInspect for GList[T] with gleam_inspect(self) {
  let buf = StringBuilder()
  buf.write_char('[')
  for cur = self, first = true {
    match cur {
      Nil => break
      Cons(head, tail) => {
        if !first {
          buf.write_string(", ")
        }
        buf.write_string(GleamInspect::gleam_inspect(head))
        continue tail, false
      }
    }
  }
  buf.write_char(']')
  buf.to_string()
}

///|
pub impl[T : GleamInspect, E : GleamInspect] GleamInspect for Result[T, E] with gleam_inspect(
  self,
) {
  match self {
    Ok(v) => "Ok(" + GleamInspect::gleam_inspect(v) + ")"
    Err(e) => "Error(" + GleamInspect::gleam_inspect(e) + ")"
  }
}

///|
pub impl[T : GleamInspect] GleamInspect for Option[T] with gleam_inspect(self) {
  match self {
    Some(v) => "Some(" + GleamInspect::gleam_inspect(v) + ")"
    None => "None"
  }
}

///|
pub impl[A : GleamInspect, B : GleamInspect] GleamInspect for (A, B) with gleam_inspect(
  self,
) {
  "#(" + GleamInspect::gleam_inspect(self.0) + ", " + GleamInspect::gleam_inspect(self.1) + ")"
}

///|
pub impl[A : GleamInspect, B : GleamInspect, C : GleamInspect] GleamInspect for (
  A,
  B,
  C,
) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ")"
}

///|
pub impl[A : GleamInspect, B : GleamInspect, C : GleamInspect, D : GleamInspect] GleamInspect for (
  A,
  B,
  C,
  D,
) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ")"
}

///|
pub impl[
  A : GleamInspect,
  B : GleamInspect,
  C : GleamInspect,
  D : GleamInspect,
  E : GleamInspect,
] GleamInspect for (A, B, C, D, E) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ", " +
  GleamInspect::gleam_inspect(self.4) +
  ")"
}

///|
pub impl[
  A : GleamInspect,
  B : GleamInspect,
  C : GleamInspect,
  D : GleamInspect,
  E : GleamInspect,
  F : GleamInspect,
] GleamInspect for (A, B, C, D, E, F) with gleam_inspect(self) {
  "#(" +
  GleamInspect::gleam_inspect(self.0) +
  ", " +
  GleamInspect::gleam_inspect(self.1) +
  ", " +
  GleamInspect::gleam_inspect(self.2) +
  ", " +
  GleamInspect::gleam_inspect(self.3) +
  ", " +
  GleamInspect::gleam_inspect(self.4) +
  ", " +
  GleamInspect::gleam_inspect(self.5) +
  ")"
}

///|
pub impl GleamInspect for Dynamic with gleam_inspect(self) {
  match self {
    DynNull => "Nil"
    DynBool(b) => GleamInspect::gleam_inspect(b)
    DynInt(i) => GleamInspect::gleam_inspect(i)
    DynFloat(f) => GleamInspect::gleam_inspect(f)
    DynString(s) => GleamInspect::gleam_inspect(s)
    DynBitArray(ba) => GleamInspect::gleam_inspect(ba)
    DynList(xs) => GleamInspect::gleam_inspect(xs)
    DynArray(arr) => {
      let buf = StringBuilder()
      buf.write_char('[')
      for i = 0; i < arr.length(); i = i + 1 {
        if i > 0 {
          buf.write_string(", ")
        }
        buf.write_string(GleamInspect::gleam_inspect(arr[i]))
      }
      buf.write_char(']')
      buf.to_string()
    }
    DynMap(m) => {
      let buf = StringBuilder()
      buf.write_string("dict.from_list([")
      let mut first = true
      m.each(fn(k, v) {
        if !first {
          buf.write_string(", ")
        }
        first = false
        buf.write_string("#(")
        buf.write_string(GleamInspect::gleam_inspect(k))
        buf.write_string(", ")
        buf.write_string(GleamInspect::gleam_inspect(v))
        buf.write_char(')')
      })
      buf.write_string("])")
      buf.to_string()
    }
  }
}

///|
pub(open) trait ToDynamic {
  to_dynamic(Self) -> Dynamic
}

///|
pub impl ToDynamic for Dynamic with to_dynamic(self) {
  self
}

///|
pub impl ToDynamic for String with to_dynamic(self) {
  DynString(self)
}

///|
pub impl ToDynamic for Int64 with to_dynamic(self) {
  DynInt(self)
}

///|
pub impl ToDynamic for Double with to_dynamic(self) {
  DynFloat(self)
}

///|
pub impl ToDynamic for Bool with to_dynamic(self) {
  DynBool(self)
}

///|
pub impl ToDynamic for Unit with to_dynamic(_) {
  DynNull
}

///|
pub impl ToDynamic for BitArray with to_dynamic(self) {
  DynBitArray(self)
}

///|
pub impl ToDynamic for UtfCodepoint with to_dynamic(self) {
  DynInt(self.code)
}

///|
pub impl[T : ToDynamic] ToDynamic for Option[T] with to_dynamic(self) {
  match self {
    Some(v) => ToDynamic::to_dynamic(v)
    None => DynNull
  }
}

///|
pub impl[T : ToDynamic] ToDynamic for GList[T] with to_dynamic(self) {
  let rev = for cur = self, acc = (Nil : GList[Dynamic]) {
    match cur {
      Nil => break acc
      Cons(x, rest) => continue rest, Cons(ToDynamic::to_dynamic(x), acc)
    }
  }
  DynList(rev.reverse())
}

///|
pub fn[T : GleamInspect] echo_val(val : T, loc : String, msg : String) -> T {
  let header = if msg == "" { loc } else { loc + " " + msg }
  @prelude.eprintln(header)
  @prelude.eprintln(GleamInspect::gleam_inspect(val))
  val
}
