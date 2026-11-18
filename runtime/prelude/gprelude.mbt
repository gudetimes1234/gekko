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
    abort("unsupported non-byte-aligned bit segment width in Tier 1 BitArray")
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
    abort("unsupported float bit segment width in BitArray")
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
  DynMap(Map[String, Dynamic])
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
pub fn[T] echo_val(val : T, msg : String) -> T {
  if msg != "" {
    println(msg)
  }
  val
}
