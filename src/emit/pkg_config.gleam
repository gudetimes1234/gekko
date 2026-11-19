import gleam/dict
import gleam/list
import gleam/string

/// Map a Gleam module path (`"my_app/auth/token"`) into a MoonBit package
/// directory name under the workspace root (`"my_app_auth_token"`).
pub fn module_to_pkg_dir(module_name: String) -> String {
  let base = string.replace(module_name, "/", "_")
  case base {
    "gprelude" | "prelude" -> "mod_" <> base
    _ -> base
  }
}

/// Generate the root `moon.mod` file for the transpiled MoonBit workspace.
pub fn emit_moon_mod(project_name: String, version: String) -> String {
  "name = \""
  <> project_name
  <> "\"\n"
  <> "version = \""
  <> version
  <> "\"\n"
  <> "warnings = \"-implicit_impl_as_method-unused_rest_mark-unused_package-unused_value-unresolved_type_variable-unused_loop_variable-unused_constructor-guard_redundant_else-unused_trait_bound-deprecated_syntax\"\n"
}

/// Generate a declarative `moon.pkg` file for a package given `#(pkg_or_dir, alias)`
/// pairs and an optional `is-main` entrypoint flag.
pub fn emit_moon_pkg(
  project_name: String,
  imports: List(#(String, String)),
  is_main: Bool,
) -> String {
  let deduped = deduplicate_imports(project_name, imports)

  let import_block = case deduped {
    [] -> ""
    entries -> {
      let lines =
        list.map(entries, fn(entry) {
          let #(pkg_path, alias) = entry
          "  \"" <> pkg_path <> "\" @" <> alias <> ","
        })
        |> string.join("\n")
      "import {\n" <> lines <> "\n}\n"
    }
  }

  let options_block = case is_main {
    False -> ""
    True -> {
      let prefix = case import_block {
        "" -> ""
        _ -> "\n"
      }
      prefix <> "options(\n  \"is-main\": true,\n)\n"
    }
  }

  import_block <> options_block
}

fn deduplicate_imports(
  project_name: String,
  imports: List(#(String, String)),
) -> List(#(String, String)) {
  imports
  |> list.fold(dict.new(), fn(acc, entry) {
    let #(pkg_or_dir, alias) = entry
    let full_pkg = case string.contains(pkg_or_dir, "/") {
      True -> pkg_or_dir
      False -> project_name <> "/" <> pkg_or_dir
    }
    dict.insert(acc, alias, full_pkg)
  })
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.1, pair.0) })
  |> list.sort(fn(a, b) { string.compare(a.1, b.1) })
}
