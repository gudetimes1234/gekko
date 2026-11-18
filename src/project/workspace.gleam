import emit/moonbit
import emit/pkg_config
import emit/prelude_runtime
import filepath
import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import index/symbol_table
import lower/desugar
import lower/tco
import project/ffi_config
import project/prepass.{type PrepassResult}
import project/staging
import simplifile
import tom

/// Summary returned after transpiling a Gleam project into a MoonBit workspace.
pub type TranspileSummary {
  TranspileSummary(
    project_name: String,
    version: String,
    out_dir: String,
    emitted_modules: List(String),
  )
}

/// Transpile a Gleam project at `project_root` into a complete MoonBit
/// workspace at `out_dir`.
pub fn transpile_project(
  project_root: String,
  out_dir: String,
) -> Result(TranspileSummary, String) {
  use #(project_name, version) <- result.try(read_project_meta(project_root))
  use ffi_overrides <- result.try(ffi_config.load_project_overrides(
    project_root,
  ))

  let staging_dir = filepath.join(project_root, "build/.gekko_staging")
  use pkg_iface <- result.try(staging.extract_project_interface(
    project_root,
    staging_dir,
  ))

  let src_dir = filepath.join(project_root, "src")
  use src_modules <- result.try(discover_and_parse(src_dir, None))

  let test_dir = filepath.join(project_root, "test")
  use test_modules <- result.try(case simplifile.is_directory(test_dir) {
    Ok(True) -> {
      use parsed <- result.try(discover_and_parse(test_dir, Some("test")))
      Ok(list.map(parsed, strip_gleeunit_harness))
    }
    _ -> Ok([])
  })

  let all_modules = list.append(src_modules, test_modules)
  let table =
    symbol_table.index_project(
      project_name,
      all_modules,
      Some(pkg_iface),
      ffi_overrides,
    )

  use _ <- result.try(
    simplifile.create_directory_all(out_dir)
    |> result.map_error(fn(err) {
      "Failed to create output workspace "
      <> out_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  use _ <- result.try(write_text_file(
    filepath.join(out_dir, "moon.mod"),
    pkg_config.emit_moon_mod(project_name, version),
  ))

  let gprelude_dir = filepath.join(out_dir, "gprelude")
  use _ <- result.try(write_text_file(
    filepath.join(gprelude_dir, "moon.pkg"),
    prelude_runtime.moon_pkg(),
  ))
  use _ <- result.try(write_text_file(
    filepath.join(gprelude_dir, "gprelude.mbt"),
    prelude_runtime.gprelude_mbt(),
  ))

  use emitted_names <- result.try(
    list.try_fold(all_modules, [], fn(acc, entry) {
      let #(mod_name, ast_mod, _) = entry
      let ir_mod =
        desugar.desugar_module(ast_mod, table, mod_name)
        |> tco.optimize_module
      let #(mbt_src, imports) = moonbit.emit_module_with_table(ir_mod, table)
      let is_main = moonbit.module_has_main(ir_mod)
      let pkg_dir = pkg_config.module_to_pkg_dir(mod_name)
      let target_dir = filepath.join(out_dir, pkg_dir)

      use _ <- result.try(write_text_file(
        filepath.join(target_dir, "moon.pkg"),
        pkg_config.emit_moon_pkg(project_name, imports, is_main),
      ))
      use _ <- result.try(write_text_file(
        filepath.join(target_dir, pkg_dir <> ".mbt"),
        mbt_src,
      ))
      Ok([mod_name, ..acc])
    }),
  )

  Ok(TranspileSummary(
    project_name:,
    version:,
    out_dir:,
    emitted_modules: list.reverse(emitted_names),
  ))
}

fn read_project_meta(
  project_root: String,
) -> Result(#(String, String), String) {
  let path = filepath.join(project_root, "gleam.toml")
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "Failed to read " <> path <> ": " <> simplifile.describe_error(err)
    }),
  )
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(fn(_) { "Failed to parse " <> path <> " as TOML" }),
  )
  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "Missing or invalid 'name' field in " <> path }),
  )
  let version = case tom.get_string(parsed, ["version"]) {
    Ok(v) -> v
    Error(_) -> "0.1.0"
  }
  Ok(#(name, version))
}

fn discover_and_parse(
  base_dir: String,
  mod_prefix: Option(String),
) -> Result(List(#(String, glance.Module, PrepassResult)), String) {
  use rel_paths <- result.try(collect_gleam_files(base_dir, ""))
  let sorted_paths = list.sort(rel_paths, string.compare)
  list.try_map(sorted_paths, fn(rel) {
    let full_path = filepath.join(base_dir, rel)
    let mod_base = filepath.strip_extension(rel)
    let mod_name = case mod_prefix {
      Some(pfx) -> pfx <> "/" <> mod_base
      None -> mod_base
    }
    use source <- result.try(
      simplifile.read(full_path)
      |> result.map_error(fn(err) {
        "Failed to read " <> full_path <> ": " <> simplifile.describe_error(err)
      }),
    )
    prepass.parse_module(mod_name, source)
    |> result.map(fn(pair) { #(mod_name, pair.0, pair.1) })
    |> result.map_error(fn(err) {
      "Failed to parse " <> full_path <> ": " <> format_glance_error(err)
    })
  })
}

fn collect_gleam_files(
  base_dir: String,
  rel_prefix: String,
) -> Result(List(String), String) {
  let current = case rel_prefix {
    "" -> base_dir
    _ -> filepath.join(base_dir, rel_prefix)
  }
  use entries <- result.try(
    simplifile.read_directory(at: current)
    |> result.map_error(fn(err) {
      "Failed to read directory "
      <> current
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    let rel = case rel_prefix {
      "" -> entry
      _ -> filepath.join(rel_prefix, entry)
    }
    let full = filepath.join(base_dir, rel)
    case simplifile.is_directory(full) {
      Ok(True) -> {
        use nested <- result.try(collect_gleam_files(base_dir, rel))
        Ok(list.append(acc, nested))
      }
      Ok(False) ->
        case filepath.extension(rel) {
          Ok("gleam") -> Ok([rel, ..acc])
          _ -> Ok(acc)
        }
      Error(err) ->
        Error(
          "Failed to stat " <> full <> ": " <> simplifile.describe_error(err),
        )
    }
  })
}

fn strip_gleeunit_harness(
  entry: #(String, glance.Module, PrepassResult),
) -> #(String, glance.Module, PrepassResult) {
  let #(mod_name, mod, pre) = entry
  let has_gleeunit_import =
    list.any(mod.imports, fn(def) { def.definition.module == "gleeunit" })
  case has_gleeunit_import {
    False -> entry
    True -> {
      let filtered_imports =
        list.filter(mod.imports, fn(def) { def.definition.module != "gleeunit" })
      let filtered_functions =
        list.filter(mod.functions, fn(def) {
          let func = def.definition
          case func.name == "main" && func.parameters == [] {
            True -> !calls_gleeunit_main(func.body)
            False -> True
          }
        })
      let cleaned_mod =
        glance.Module(
          ..mod,
          imports: filtered_imports,
          functions: filtered_functions,
        )
      #(mod_name, cleaned_mod, pre)
    }
  }
}

fn calls_gleeunit_main(stmts: List(glance.Statement)) -> Bool {
  case stmts {
    [
      glance.Expression(glance.Call(
        function: glance.FieldAccess(
          container: glance.Variable(name: "gleeunit", ..),
          label: "main",
          ..,
        ),
        ..,
      )),
    ] -> True
    _ -> False
  }
}

fn write_text_file(path: String, contents: String) -> Result(Nil, String) {
  let dir = filepath.directory_name(path)
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(err) {
      "Failed to create directory "
      <> dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  simplifile.write(to: path, contents:)
  |> result.map_error(fn(err) {
    "Failed to write " <> path <> ": " <> simplifile.describe_error(err)
  })
}

fn format_glance_error(err: glance.Error) -> String {
  case err {
    glance.UnexpectedEndOfInput -> "unexpected end of input"
    glance.UnexpectedToken(token: _, position:) ->
      "unexpected token at byte offset " <> string.inspect(position.byte_offset)
  }
}
