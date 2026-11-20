import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/prepass.{type FfiKind, PackageCall, WasmImport}
import simplifile
import tom.{type Toml}

/// Parse FFI overrides from a `gekko.toml` file string (`[overrides."..."]`).
pub fn parse_gekko_toml(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["overrides"]) {
    Ok(table) -> collect_overrides(table, [])
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Parse FFI overrides from a `gleam.toml` file string (`[tools.gekko.overrides."..."]`).
pub fn parse_gleam_toml_overrides(
  content: String,
) -> Result(Dict(String, FfiKind), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  case tom.get_table(parsed, ["tools", "gekko", "overrides"]) {
    Ok(table) -> collect_overrides(table, [])
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
  }
}

/// Load and merge FFI overrides from `<project_root>/gleam.toml` (`[tools.gekko.overrides]`)
/// and `<project_root>/gekko.toml` (`[overrides]`), with `gekko.toml` taking precedence.
pub fn load_project_overrides(
  project_root: String,
) -> Result(Dict(String, FfiKind), String) {
  use #(from_gleam, from_gekko) <- result.try(load_toml_pair(
    project_root,
    dict.new(),
    parse_gleam_toml_overrides,
    parse_gekko_toml,
  ))
  Ok(dict.merge(from_gleam, from_gekko))
}

/// Parse MoonBit third-party dependencies from `gekko.toml` (`[moonbit.deps]`).
pub fn parse_moonbit_deps_gekko_toml(
  content: String,
) -> Result(List(#(String, String)), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  use dep_map <- result.try(extract_string_table(parsed, ["moonbit", "deps"]))
  Ok(sort_dep_pairs(dep_map))
}

/// Parse MoonBit third-party dependencies from `gleam.toml`
/// (`[tools.gekko.moonbit.deps]` or `[gekko.moonbit.deps]`).
pub fn parse_moonbit_deps_gleam_toml(
  content: String,
) -> Result(List(#(String, String)), String) {
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(format_parse_error),
  )
  use tools_map <- result.try(
    extract_string_table(parsed, ["tools", "gekko", "moonbit", "deps"]),
  )
  use gekko_map <- result.try(
    extract_string_table(parsed, ["gekko", "moonbit", "deps"]),
  )
  Ok(sort_dep_pairs(dict.merge(tools_map, gekko_map)))
}

/// Load and merge MoonBit dependencies from `<project_root>/gleam.toml`,
/// `<project_root>/gekko.toml`, and `<project_root>/moonbit/moon.mod`, with
/// `moonbit/moon.mod` taking highest precedence.
pub fn load_project_moonbit_deps(
  project_root: String,
) -> Result(List(#(String, String)), String) {
  use #(from_gleam, from_gekko) <- result.try(load_toml_pair(
    project_root,
    [],
    parse_moonbit_deps_gleam_toml,
    parse_moonbit_deps_gekko_toml,
  ))
  let moon_mod_path = filepath.join(project_root, "moonbit/moon.mod")
  use from_moon_mod <- result.try(case simplifile.read(moon_mod_path) {
    Ok(content) -> parse_moon_mod_deps(content)
    Error(simplifile.Enoent) -> Ok([])
    Error(err) ->
      Error(
        "Failed to read "
        <> moon_mod_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })
  let insert_all = fn(acc, pairs) {
    list.fold(pairs, acc, fn(d, p) {
      let #(k, v) = p
      dict.insert(d, k, v)
    })
  }
  dict.new()
  |> insert_all(from_gleam)
  |> insert_all(from_gekko)
  |> insert_all(from_moon_mod)
  |> sort_dep_pairs
  |> Ok
}

/// Parse MoonBit third-party dependencies from the `import { ... }` block of
/// a native `moon.mod` file (such as `<project_root>/moonbit/moon.mod`).
pub fn parse_moon_mod_deps(
  content: String,
) -> Result(List(#(String, String)), String) {
  let stripped = strip_line_comments(content)
  use import_bodies <- result.try(
    extract_import_blocks(
      string.to_graphemes(stripped),
      0,
      False,
      False,
      "",
      "",
      False,
      [],
      [],
    ),
  )
  use dep_map <- result.try(
    list.try_fold(import_bodies, dict.new(), fn(acc, body) {
      parse_import_block_entries(body, acc)
    }),
  )
  Ok(sort_dep_pairs(dep_map))
}

fn strip_line_comments(content: String) -> String {
  content
  |> string.split("\n")
  |> list.map(fn(line) {
    strip_comment_in_line(string.to_graphemes(line), False, False, [])
  })
  |> string.join("\n")
}

fn strip_comment_in_line(
  chars: List(String),
  in_string: Bool,
  escaped: Bool,
  acc: List(String),
) -> String {
  case chars {
    [] -> acc |> list.reverse |> string.concat
    [ch, ..rest] ->
      case in_string {
        True ->
          case escaped {
            True -> strip_comment_in_line(rest, True, False, [ch, ..acc])
            False ->
              case ch {
                "\\" -> strip_comment_in_line(rest, True, True, [ch, ..acc])
                "\"" -> strip_comment_in_line(rest, False, False, [ch, ..acc])
                _ -> strip_comment_in_line(rest, True, False, [ch, ..acc])
              }
          }
        False ->
          case ch, rest {
            "\"", _ -> strip_comment_in_line(rest, True, False, [ch, ..acc])
            "/", ["/", ..] -> acc |> list.reverse |> string.concat
            _, _ -> strip_comment_in_line(rest, False, False, [ch, ..acc])
          }
      }
  }
}

fn extract_import_blocks(
  chars: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
  current_ident: String,
  prev_ident: String,
  capturing: Bool,
  captured_rev: List(String),
  blocks_rev: List(String),
) -> Result(List(String), String) {
  case chars {
    [] ->
      case capturing {
        True -> Error("Unclosed import block in moon.mod")
        False -> Ok(list.reverse(blocks_rev))
      }
    [ch, ..rest] ->
      case in_string {
        True -> {
          let next_captured = case capturing {
            True -> [ch, ..captured_rev]
            False -> captured_rev
          }
          let #(next_in_str, next_esc) = case escaped {
            True -> #(True, False)
            False ->
              case ch {
                "\\" -> #(True, True)
                "\"" -> #(False, False)
                _ -> #(True, False)
              }
          }
          extract_import_blocks(
            rest,
            depth,
            next_in_str,
            next_esc,
            "",
            "",
            capturing,
            next_captured,
            blocks_rev,
          )
        }
        False ->
          case depth {
            0 ->
              case ch {
                "\"" ->
                  extract_import_blocks(
                    rest,
                    0,
                    True,
                    False,
                    "",
                    "",
                    False,
                    [],
                    blocks_rev,
                  )
                "{" -> {
                  let keyword = case current_ident {
                    "" -> prev_ident
                    _ -> current_ident
                  }
                  let start_capture = keyword == "import"
                  extract_import_blocks(
                    rest,
                    1,
                    False,
                    False,
                    "",
                    "",
                    start_capture,
                    [],
                    blocks_rev,
                  )
                }
                _ ->
                  case is_ident_char(ch), is_whitespace_char(ch) {
                    True, _ ->
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        current_ident <> ch,
                        prev_ident,
                        False,
                        [],
                        blocks_rev,
                      )
                    False, True -> {
                      let next_prev = case current_ident {
                        "" -> prev_ident
                        _ -> current_ident
                      }
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        next_prev,
                        False,
                        [],
                        blocks_rev,
                      )
                    }
                    False, False ->
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        "",
                        False,
                        [],
                        blocks_rev,
                      )
                  }
              }
            _ ->
              case ch {
                "\"" -> {
                  let next_captured = case capturing {
                    True -> [ch, ..captured_rev]
                    False -> captured_rev
                  }
                  extract_import_blocks(
                    rest,
                    depth,
                    True,
                    False,
                    "",
                    "",
                    capturing,
                    next_captured,
                    blocks_rev,
                  )
                }
                "{" -> {
                  let next_captured = case capturing {
                    True -> [ch, ..captured_rev]
                    False -> captured_rev
                  }
                  extract_import_blocks(
                    rest,
                    depth + 1,
                    False,
                    False,
                    "",
                    "",
                    capturing,
                    next_captured,
                    blocks_rev,
                  )
                }
                "}" -> {
                  let next_depth = depth - 1
                  case next_depth == 0 && capturing {
                    True -> {
                      let body = captured_rev |> list.reverse |> string.concat
                      extract_import_blocks(
                        rest,
                        0,
                        False,
                        False,
                        "",
                        "",
                        False,
                        [],
                        [body, ..blocks_rev],
                      )
                    }
                    False -> {
                      let next_captured = case capturing {
                        True -> [ch, ..captured_rev]
                        False -> captured_rev
                      }
                      extract_import_blocks(
                        rest,
                        next_depth,
                        False,
                        False,
                        "",
                        "",
                        capturing,
                        next_captured,
                        blocks_rev,
                      )
                    }
                  }
                }
                _ -> {
                  let next_captured = case capturing {
                    True -> [ch, ..captured_rev]
                    False -> captured_rev
                  }
                  extract_import_blocks(
                    rest,
                    depth,
                    False,
                    False,
                    "",
                    "",
                    capturing,
                    next_captured,
                    blocks_rev,
                  )
                }
              }
          }
      }
  }
}

fn parse_import_block_entries(
  body: String,
  acc: Dict(String, String),
) -> Result(Dict(String, String), String) {
  let items =
    body
    |> string.replace("\n", ",")
    |> string.split(",")
  list.try_fold(items, acc, fn(d, raw_item) {
    let item = string.trim(raw_item)
    case item {
      "" -> Ok(d)
      _ -> {
        use #(pkg, ver) <- result.try(parse_moon_mod_dep_item(item))
        Ok(dict.insert(d, pkg, ver))
      }
    }
  })
}

fn parse_moon_mod_dep_item(item: String) -> Result(#(String, String), String) {
  case string.starts_with(item, "\"") {
    False -> Error("Invalid dependency entry in moon.mod: " <> item)
    True -> {
      let after_open = string.drop_start(item, 1)
      case string.split_once(after_open, "\"") {
        Error(_) -> Error("Invalid dependency entry in moon.mod: " <> item)
        Ok(#("", _)) -> Error("Invalid dependency entry in moon.mod: " <> item)
        Ok(#(spec, after_close)) -> {
          let rest = string.trim(after_close)
          let valid_trailing =
            rest == ""
            || string.starts_with(rest, "as ")
            || string.starts_with(rest, "as\t")
          case valid_trailing {
            False -> Error("Invalid dependency entry in moon.mod: " <> item)
            True ->
              case string.split_once(spec, "@") {
                Ok(#("", _)) ->
                  Error("Invalid dependency entry in moon.mod: " <> item)
                Ok(#(pkg, ver)) -> Ok(#(pkg, ver))
                Error(_) -> Ok(#(spec, ""))
              }
          }
        }
      }
    }
  }
}

fn is_ident_char(ch: String) -> Bool {
  case ch {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "_" -> True
    _ -> False
  }
}

fn is_whitespace_char(ch: String) -> Bool {
  case ch {
    " " | "\t" | "\n" | "\r" -> True
    _ -> False
  }
}

fn load_toml_pair(
  project_root: String,
  empty: a,
  parse_gleam: fn(String) -> Result(a, String),
  parse_gekko: fn(String) -> Result(a, String),
) -> Result(#(a, a), String) {
  let gleam_toml_path = filepath.join(project_root, "gleam.toml")
  let gekko_toml_path = filepath.join(project_root, "gekko.toml")

  use from_gleam <- result.try(case simplifile.read(gleam_toml_path) {
    Ok(content) -> parse_gleam(content)
    Error(simplifile.Enoent) -> Ok(empty)
    Error(err) ->
      Error(
        "Failed to read "
        <> gleam_toml_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })

  use from_gekko <- result.try(case simplifile.read(gekko_toml_path) {
    Ok(content) -> parse_gekko(content)
    Error(simplifile.Enoent) -> Ok(empty)
    Error(err) ->
      Error(
        "Failed to read "
        <> gekko_toml_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })

  Ok(#(from_gleam, from_gekko))
}

fn extract_string_table(
  parsed: Dict(String, Toml),
  key_path: List(String),
) -> Result(Dict(String, String), String) {
  case tom.get_table(parsed, key_path) {
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(format_get_error(err))
    Ok(table) ->
      dict.to_list(table)
      |> list.try_fold(dict.new(), fn(acc, entry) {
        let #(pkg, val) = entry
        case val {
          tom.String(ver) -> Ok(dict.insert(acc, pkg, ver))
          _ ->
            Error("MoonBit dependency '" <> pkg <> "' version must be a string")
        }
      })
  }
}

fn sort_dep_pairs(deps: Dict(String, String)) -> List(#(String, String)) {
  deps
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn collect_overrides(
  table: Dict(String, Toml),
  prefix: List(String),
) -> Result(Dict(String, FfiKind), String) {
  dict.to_list(table)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(key, value) = entry
    case value {
      tom.Table(sub) | tom.InlineTable(sub) ->
        case extract_ffi_kind(sub, [key, ..prefix]) {
          Ok(Some(kind)) -> {
            let full_key =
              [key, ..prefix]
              |> list.reverse
              |> string.join(".")
            Ok(dict.insert(acc, full_key, kind))
          }
          Ok(None) -> {
            use nested <- result.try(collect_overrides(sub, [key, ..prefix]))
            Ok(dict.merge(acc, nested))
          }
          Error(msg) -> Error(msg)
        }
      _ -> {
        let full_key =
          [key, ..prefix]
          |> list.reverse
          |> string.join(".")
        Error("Expected table for override key '" <> full_key <> "'")
      }
    }
  })
}

fn extract_ffi_kind(
  table: Dict(String, Toml),
  rev_key_parts: List(String),
) -> Result(Option(FfiKind), String) {
  let key_name =
    rev_key_parts
    |> list.reverse
    |> string.join(".")

  case dict.get(table, "package"), dict.get(table, "wasm_module") {
    Ok(tom.String(pkg)), Error(_) ->
      case dict.get(table, "function") {
        Ok(tom.String(func)) ->
          Ok(Some(PackageCall(package: pkg, function: func)))
        Ok(_) ->
          Error("Override '" <> key_name <> "' field 'function' must be String")
        Error(_) ->
          Error(
            "Override '"
            <> key_name
            <> "' with 'package' must also specify 'function'",
          )
      }

    Error(_), Ok(tom.String(wasm_mod)) ->
      case dict.get(table, "import_name") {
        Ok(tom.String(imp)) ->
          Ok(Some(WasmImport(wasm_module: wasm_mod, import_name: imp)))
        Ok(_) ->
          Error(
            "Override '" <> key_name <> "' field 'import_name' must be String",
          )
        Error(_) ->
          Error(
            "Override '"
            <> key_name
            <> "' with 'wasm_module' must also specify 'import_name'",
          )
      }

    Ok(_), Ok(_) ->
      Error(
        "Override '"
        <> key_name
        <> "' cannot specify both 'package' and 'wasm_module'",
      )

    Ok(_), Error(_) ->
      Error("Override '" <> key_name <> "' field 'package' must be String")

    Error(_), Ok(_) ->
      Error("Override '" <> key_name <> "' field 'wasm_module' must be String")

    Error(_), Error(_) ->
      case dict.get(table, "function"), dict.get(table, "import_name") {
        Ok(_), _ ->
          Error(
            "Override '"
            <> key_name
            <> "' specifies 'function' without 'package'",
          )
        _, Ok(_) ->
          Error(
            "Override '"
            <> key_name
            <> "' specifies 'import_name' without 'wasm_module'",
          )
        Error(_), Error(_) -> Ok(None)
      }
  }
}

fn format_parse_error(err: tom.ParseError) -> String {
  case err {
    tom.Unexpected(got:, expected:) ->
      "TOML parse error: unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key:) ->
      "TOML parse error: duplicate key '" <> string.join(key, ".") <> "'"
  }
}

fn format_get_error(err: tom.GetError) -> String {
  case err {
    tom.NotFound(key:) -> "TOML missing key '" <> string.join(key, ".") <> "'"
    tom.WrongType(key:, expected:, got:) ->
      "TOML type error at '"
      <> string.join(key, ".")
      <> "': expected "
      <> expected
      <> ", got "
      <> got
  }
}
