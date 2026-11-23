import emit/moonbit
import emit/pkg_config
import emit/prelude_runtime
import emit/trait_bounds
import filepath
import glance
import gleam/dict.{type Dict}
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
import project/cmd
import project/diagnostics
import project/ffi_config
import project/interface.{type PackageInterface, PackageInterface}
import project/loader.{type LoadedDependency}
import project/moonbit_ffi
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
    local_moonbit_packages: List(String),
    module_pkg_dirs: Dict(String, String),
  )
}

/// Transpile a Gleam project at `project_root` (including `test/` modules) into
/// a complete MoonBit workspace at `out_dir`.
pub fn transpile_project(
  project_root: String,
  out_dir: String,
) -> Result(TranspileSummary, String) {
  transpile_project_with_tests(project_root, out_dir, True)
}

/// Transpile a Gleam project at `project_root` into a complete MoonBit workspace
/// at `out_dir`, optionally including `test/` modules.
pub fn transpile_project_with_tests(
  project_root: String,
  out_dir: String,
  include_tests: Bool,
) -> Result(TranspileSummary, String) {
  use #(project_name, version) <- result.try(loader.read_project_meta(
    project_root,
  ))
  use _ <- result.try(ensure_deps_downloaded(project_root, include_tests))
  use packages_hash <- result.try(staging.compute_packages_dir_hash(
    project_root,
  ))
  use ffi_overrides <- result.try(ffi_config.load_project_overrides(
    project_root,
  ))
  use root_moonbit_deps <- result.try(ffi_config.load_project_moonbit_deps(
    project_root,
  ))
  use loaded_deps <- result.try(loader.load_dependencies_with_packages_hash(
    project_root,
    ffi_overrides,
    include_tests,
    Some(packages_hash),
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
  use root_iface <- result.try(
    staging.extract_project_interface_with_packages_hash(
      project_root,
      staging_dir,
      include_tests,
      Some(packages_hash),
    ),
  )
  let merged_iface = merge_package_interfaces(root_iface, loaded_deps)

  let src_dir = filepath.join(project_root, "src")
  use src_modules <- result.try(loader.discover_and_parse(src_dir, None))

  let test_dir = filepath.join(project_root, "test")
  use test_modules <- result.try(
    case include_tests, simplifile.is_directory(test_dir) {
      True, Ok(True) -> {
        use parsed <- result.try(loader.discover_and_parse(
          test_dir,
          Some("test"),
        ))
        Ok(list.map(parsed, strip_gleeunit_harness))
      }
      _, _ -> Ok([])
    },
  )

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

  let resolved_pkg_dirs =
    all_modules
    |> list.map(fn(entry) { entry.1 })
    |> pkg_config.resolve_module_pkg_dirs

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

  let module_pkg_dirs =
    list.map(all_modules, fn(entry) {
      dict.get(resolved_pkg_dirs, entry.1)
      |> result.unwrap(pkg_config.module_to_pkg_dir(entry.1))
    })
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
  let local_pkg_set = set.from_list(local_moonbit_packages)

  let ir_modules =
    list.map(all_modules, fn(entry) {
      let #(_, mod_name, ast_mod, _) = entry
      desugar.desugar_module(ast_mod, table, mod_name)
      |> tco.optimize_module
    })

  let project_bounds =
    trait_bounds.analyze_project(ir_modules, Some(table), ffi_metadata)

  let module_meta_by_name =
    list.fold(all_modules, dict.new(), fn(acc, entry) {
      let #(pkg_name, mod_name, ast_mod, pre) = entry
      dict.insert(acc, mod_name, #(pkg_name, ast_mod, pre.cleaned_source))
    })

  use #(rev_emitted, rev_origins) <- result.try(
    list.try_fold(ir_modules, #([], []), fn(acc, ir_mod) {
      let #(names_acc, origins_acc) = acc
      let mod_name = ir_mod.module_name
      let #(mbt_src, imports) =
        moonbit.emit_module_with_pkg_dirs(
          ir_mod,
          Some(table),
          ffi_metadata,
          project_bounds,
          resolved_pkg_dirs,
        )
      let is_main = moonbit.module_has_main(ir_mod)
      let pkg_dir =
        dict.get(resolved_pkg_dirs, mod_name)
        |> result.unwrap(pkg_config.module_to_pkg_dir(mod_name))
      let target_dir = filepath.join(out_dir, pkg_dir)
      let mbt_rel = pkg_dir <> "/" <> pkg_dir <> ".mbt"

      use _ <- result.try(write_text_file(
        filepath.join(target_dir, "moon.pkg"),
        pkg_config.emit_moon_pkg_with_local_pkgs(
          project_name,
          imports,
          is_main,
          local_pkg_set,
        ),
      ))
      use _ <- result.try(write_text_file(
        filepath.join(target_dir, pkg_dir <> ".mbt"),
        mbt_src,
      ))
      let mod_origins = case dict.get(module_meta_by_name, mod_name) {
        Ok(#(pkg_name, ast_mod, gleam_src)) ->
          diagnostics.collect_module_origins(
            project_name,
            pkg_name,
            mod_name,
            ast_mod,
            gleam_src,
            mbt_rel,
            mbt_src,
          )
        Error(_) -> []
      }
      Ok(#(
        [mod_name, ..names_acc],
        list.append(list.reverse(mod_origins), origins_acc),
      ))
    }),
  )

  use _ <- result.try(write_text_file(
    filepath.join(out_dir, diagnostics.sourcemap_filename),
    diagnostics.format_sourcemap(list.reverse(rev_origins)),
  ))

  let local_top_dirs =
    list.map(local_moonbit_packages, fn(pkg) {
      case string.split_once(pkg, "/") {
        Ok(#(top, _)) -> top
        Error(_) -> pkg
      }
    })
  let new_generated_dirs =
    list.append(module_pkg_dirs, local_top_dirs)
    |> list.filter(fn(d) { d != "" && d != "gprelude" })
    |> set.from_list
    |> set.to_list
    |> list.sort(string.compare)

  use _ <- result.try(clean_stale_generated_dirs(
    out_dir,
    new_generated_dirs,
    include_tests,
  ))

  Ok(TranspileSummary(
    project_name:,
    version:,
    out_dir:,
    emitted_modules: list.reverse(rev_emitted),
    local_moonbit_packages:,
    module_pkg_dirs: resolved_pkg_dirs,
  ))
}

fn clean_stale_generated_dirs(
  out_dir: String,
  new_generated_dirs: List(String),
  include_tests: Bool,
) -> Result(Nil, String) {
  let manifest_path = filepath.join(out_dir, ".gekko_generated")
  let from_manifest = case simplifile.read(from: manifest_path) {
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.map(string.trim)
      |> list.filter(fn(line) { line != "" })
    Error(_) -> []
  }

  let legacy_test_dirs = case include_tests {
    True -> []
    False ->
      case simplifile.read_directory(at: out_dir) {
        Ok(entries) ->
          list.filter(entries, fn(entry) {
            case string.starts_with(entry, "test_") {
              False -> False
              True -> {
                let entry_dir = filepath.join(out_dir, entry)
                let pkg_file = filepath.join(entry_dir, "moon.pkg")
                simplifile.is_directory(entry_dir) == Ok(True)
                && simplifile.is_file(pkg_file) == Ok(True)
              }
            }
          })
        Error(_) -> []
      }
  }

  let protected =
    [
      "", ".", "..", "_build", ".mooncakes", "gprelude", ".gekko_generated",
      diagnostics.sourcemap_filename,
    ]
    |> set.from_list
  let keep = set.union(protected, set.from_list(new_generated_dirs))

  let stale =
    list.append(from_manifest, legacy_test_dirs)
    |> set.from_list
    |> set.to_list
    |> list.filter(fn(dir) { !set.contains(keep, dir) })

  use _ <- result.try(
    list.try_each(stale, fn(dir) {
      let path = filepath.join(out_dir, dir)
      case simplifile.is_directory(path) {
        Ok(True) ->
          simplifile.delete(file_or_dir_at: path)
          |> result.map_error(fn(err) {
            "Failed to clean stale package directory "
            <> path
            <> ": "
            <> simplifile.describe_error(err)
          })
        _ -> Ok(Nil)
      }
    }),
  )

  let manifest_body = case new_generated_dirs {
    [] -> ""
    _ -> string.join(new_generated_dirs, "\n") <> "\n"
  }
  write_text_file(manifest_path, manifest_body)
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

fn ensure_deps_downloaded(
  project_root: String,
  include_tests: Bool,
) -> Result(Nil, String) {
  let packages_dir = filepath.join(project_root, "build/packages")
  case simplifile.is_directory(packages_dir) {
    Ok(True) -> Ok(Nil)
    _ -> {
      let toml_path = filepath.join(project_root, "gleam.toml")
      case simplifile.read(toml_path) {
        Error(_) -> Ok(Nil)
        Ok(content) ->
          case tom.parse(content) {
            Error(_) -> Ok(Nil)
            Ok(parsed) -> {
              let has_remote_in = fn(section) {
                case tom.get_table(parsed, [section]) {
                  Error(_) -> False
                  Ok(tbl) ->
                    dict.values(tbl)
                    |> list.any(fn(val) {
                      case val {
                        tom.InlineTable(dep_tbl) | tom.Table(dep_tbl) ->
                          case tom.get_string(dep_tbl, ["path"]) {
                            Ok(_) -> False
                            Error(_) -> True
                          }
                        _ -> True
                      }
                    })
                }
              }
              let needs_download =
                has_remote_in("dependencies")
                || { include_tests && has_remote_in("dev-dependencies") }
              case needs_download {
                False -> Ok(Nil)
                True -> {
                  let res =
                    cmd.run(
                      command: "gleam",
                      args: ["deps", "download"],
                      cwd: project_root,
                    )
                  case res.exit_code {
                    0 -> Ok(Nil)
                    _ ->
                      Error(
                        "`gleam deps download` failed while fetching missing dependencies:\n"
                        <> res.output,
                      )
                  }
                }
              }
            }
          }
      }
    }
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
  case simplifile.read(from: path) {
    Ok(existing) if existing == contents -> Ok(Nil)
    _ -> {
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
  }
}
