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
  let gleam_toml_path = filepath.join(project_root, "gleam.toml")
  let gekko_toml_path = filepath.join(project_root, "gekko.toml")

  use from_gleam <- result.try(case simplifile.read(gleam_toml_path) {
    Ok(content) -> parse_gleam_toml_overrides(content)
    Error(simplifile.Enoent) -> Ok(dict.new())
    Error(err) ->
      Error(
        "Failed to read "
        <> gleam_toml_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })

  use from_gekko <- result.try(case simplifile.read(gekko_toml_path) {
    Ok(content) -> parse_gekko_toml(content)
    Error(simplifile.Enoent) -> Ok(dict.new())
    Error(err) ->
      Error(
        "Failed to read "
        <> gekko_toml_path
        <> ": "
        <> simplifile.describe_error(err),
      )
  })

  Ok(dict.merge(from_gleam, from_gekko))
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
