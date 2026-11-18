import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string

fn reserved_keywords() -> Set(String) {
  set.from_list([
    "match",
    "loop",
    "for",
    "while",
    "break",
    "continue",
    "nobreak",
    "struct",
    "enum",
    "trait",
    "impl",
    "guard",
    "async",
    "test",
    "init",
    "main",
    "pub",
    "priv",
    "fn",
    "let",
    "mut",
    "const",
    "type",
    "typealias",
    "traitalias",
    "suberror",
    "raise",
    "try",
    "catch",
    "noraise",
    "nocancel",
    "errdefer",
    "defer",
    "derive",
    "extend",
    "import",
    "using",
    "as",
    "is",
    "in",
    "if",
    "else",
    "return",
    "throw",
    "and",
    "dyn",
    "true",
    "false",
    "Self",
    "self",
    "super",
    "where",
    "with",
    "readonly",
  ])
}

fn builtin_moonbit_types() -> Set(String) {
  set.from_list([
    "Int",
    "Int16",
    "Int64",
    "UInt",
    "UInt16",
    "UInt64",
    "Double",
    "Float",
    "String",
    "Bool",
    "Unit",
    "Bytes",
    "Byte",
    "Char",
    "Array",
    "ArrayView",
    "FixedArray",
    "ReadOnlyArray",
    "Result",
    "Option",
    "Error",
    "Json",
    "Map",
    "Self",
  ])
}

/// Return True if `name` collides with a MoonBit reserved keyword.
pub fn is_reserved_keyword(name: String) -> Bool {
  set.contains(reserved_keywords(), name)
}

/// Escape MoonBit reserved keywords by appending `_`.
pub fn mangle_ident(name: String) -> String {
  case is_reserved_keyword(name) {
    True -> name <> "_"
    False -> name
  }
}

/// Convert a Gleam `snake_case` type parameter into MoonBit `UpperCamelCase`,
/// prefixing `T_` if it would collide with a MoonBit builtin type name.
pub fn mangle_type_param(name: String) -> String {
  let camel =
    name
    |> string.split("_")
    |> list.filter(fn(part) { part != "" })
    |> list.map(uppercase_first)
    |> string.concat

  let base = case camel {
    "" -> "T"
    _ -> camel
  }

  case set.contains(builtin_moonbit_types(), base) {
    True -> "T_" <> base
    False -> base
  }
}

/// Format a numeric Hindley-Milner variable ID from `package-interface` into
/// a valid MoonBit UpperCamelCase generic parameter name (`T0`, `T1`, ...).
pub fn type_var_id_to_name(id: Int) -> String {
  "T" <> int.to_string(id)
}

/// Convert a Gleam module path (`"my_app/auth/token"`) into a valid MoonBit
/// package import alias (`"my_app_auth_token"`).
pub fn module_to_alias(module_path: String) -> String {
  module_path
  |> string.replace("/", "_")
  |> mangle_ident
}

fn uppercase_first(segment: String) -> String {
  case string.pop_grapheme(segment) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> ""
  }
}
