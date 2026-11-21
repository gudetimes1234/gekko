import emit/moonbit
import emit/pkg_config
import emit/prelude_runtime
import emit/trait_bounds
import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import index/symbol_table
import lower/desugar
import lower/tco
import lower/validate
import moonbit/ffi_meta
import project/ffi_config
import project/interface.{type PackageInterface, PackageInterface}
import project/loader.{type LoadedDependency}
import project/moonbit_ffi
import project/prepass.{type PrepassResult}
import project/staging
import simplifile

/// Summary returned after transpiling a Gleam project into a MoonBit workspace.
pub type TranspileSummary {
  TranspileSummary(
    project_name: String,
    version: String,
    out_dir: String,
    emitted_modules: List(String),
    local_moonbit_packages: List(String),
  )
}

/// Transpile a Gleam project at `project_root` into a complete MoonBit
/// workspace at `out_dir`.
pub fn transpile_project(
  project_root: String,
  out_dir: String,
) -> Result(TranspileSummary, String) {
  use #(project_name, version) <- result.try(loader.read_project_meta(
    project_root,
  ))
  use ffi_overrides <- result.try(ffi_config.load_project_overrides(
    project_root,
  ))
  use root_moonbit_deps <- result.try(ffi_config.load_project_moonbit_deps(
    project_root,
  ))
  use loaded_deps <- result.try(loader.load_dependencies(
    project_root,
    ffi_overrides,
  ))
  use dep_moonbit_deps <- result.try(
    list.try_map(loaded_deps, fn(dep) {
      ffi_config.load_project_moonbit_deps(dep.package_root)
    }),
  )
  let moonbit_deps =
    list.flatten(dep_moonbit_deps)
    |> list.append(root_moonbit_deps)
    |> list.fold(dict.new(), fn(acc, entry) {
      dict.insert(acc, entry.0, entry.1)
    })
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })

  let staging_dir = filepath.join(project_root, "build/.gekko_staging")
  use root_iface <- result.try(staging.extract_project_interface(
    project_root,
    staging_dir,
  ))
  let merged_iface = merge_package_interfaces(root_iface, loaded_deps)

  let src_dir = filepath.join(project_root, "src")
  use src_modules <- result.try(loader.discover_and_parse(src_dir, None))

  let test_dir = filepath.join(project_root, "test")
  use test_modules <- result.try(case simplifile.is_directory(test_dir) {
    Ok(True) -> {
      use parsed <- result.try(loader.discover_and_parse(test_dir, Some("test")))
      Ok(list.map(parsed, strip_gleeunit_harness))
    }
    _ -> Ok([])
  })

  let dep_tagged =
    list.flat_map(loaded_deps, fn(dep) {
      list.map(dep.modules, fn(entry) {
        let #(mod_name, ast_mod, pre) = entry
        #(dep.package_name, mod_name, ast_mod, pre)
      })
    })
  let root_tagged =
    list.append(src_modules, test_modules)
    |> list.map(fn(entry) {
      let #(mod_name, ast_mod, pre) = entry
      #(project_name, mod_name, ast_mod, pre)
    })
  let all_modules = list.append(dep_tagged, root_tagged)

  let ffi_roots =
    list.append(list.map(loaded_deps, fn(dep) { dep.package_root }), [
      project_root,
    ])
  let ffi_metadata = ffi_meta.scan_package_roots(ffi_roots)

  let table =
    symbol_table.index_project_with_ffi_meta(
      project_name,
      all_modules,
      Some(merged_iface),
      ffi_overrides,
      ffi_metadata,
    )

  use _ <- result.try(validate_all_int_literals(all_modules, table))

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
    pkg_config.emit_moon_mod_with_deps(project_name, version, moonbit_deps),
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

  let ir_modules =
    list.map(all_modules, fn(entry) {
      let #(_, mod_name, ast_mod, _) = entry
      desugar.desugar_module(ast_mod, table, mod_name)
      |> tco.optimize_module
    })

  let project_bounds =
    trait_bounds.analyze_project(ir_modules, Some(table), ffi_metadata)

  use rev_emitted <- result.try(
    list.try_fold(ir_modules, [], fn(names_acc, ir_mod) {
      let mod_name = ir_mod.module_name
      let #(mbt_src, imports) =
        moonbit.emit_module_with_context(
          ir_mod,
          Some(table),
          ffi_metadata,
          project_bounds,
        )
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
      Ok([mod_name, ..names_acc])
    }),
  )

  let module_pkg_dirs =
    list.map(all_modules, fn(entry) { pkg_config.module_to_pkg_dir(entry.1) })
  let base_reserved =
    ["gprelude", ..module_pkg_dirs]
    |> set.from_list

  use #(copied_dep_pkgs, reserved_after_deps) <- result.try(
    list.try_fold(loaded_deps, #([], base_reserved), fn(acc, dep) {
      let #(pkgs_acc, cur_reserved) = acc
      use dep_pkgs <- result.try(moonbit_ffi.copy_local_packages_for_package(
        dep.package_root,
        dep.package_name,
        project_name,
        out_dir,
        cur_reserved,
      ))
      let next_reserved = list.fold(dep_pkgs, cur_reserved, set.insert)
      Ok(#(list.append(pkgs_acc, dep_pkgs), next_reserved))
    }),
  )

  use root_moonbit_packages <- result.try(moonbit_ffi.copy_local_packages(
    project_root,
    project_name,
    out_dir,
    reserved_after_deps,
  ))
  let local_moonbit_packages =
    list.append(copied_dep_pkgs, root_moonbit_packages)
    |> list.sort(string.compare)

  Ok(TranspileSummary(
    project_name:,
    version:,
    out_dir:,
    emitted_modules: list.reverse(rev_emitted),
    local_moonbit_packages:,
  ))
}

fn merge_package_interfaces(
  root_iface: PackageInterface,
  loaded_deps: List(LoadedDependency),
) -> PackageInterface {
  let dep_modules =
    list.fold(loaded_deps, dict.new(), fn(acc, dep) {
      case dep.interface {
        Some(iface) -> dict.merge(acc, iface.modules)
        None -> acc
      }
    })
  PackageInterface(
    ..root_iface,
    modules: dict.merge(dep_modules, root_iface.modules),
  )
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

fn validate_all_int_literals(
  all_modules: List(#(String, String, glance.Module, PrepassResult)),
  table: symbol_table.SymbolTable,
) -> Result(Nil, String) {
  let errors =
    list.filter_map(all_modules, fn(entry) {
      let #(pkg_name, mod_name, ast_mod, _) = entry
      case
        validate.validate_module_int_literals_in_package(
          pkg_name,
          ast_mod,
          table,
          mod_name,
        )
      {
        Ok(Nil) -> Error(Nil)
        Error(err) -> Ok(err)
      }
    })
  case errors {
    [] -> Ok(Nil)
    _ -> Error(string.join(errors, "\n"))
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
