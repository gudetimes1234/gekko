import filepath
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import index/symbol_table
import project/interface.{type PackageInterface}
import project/prepass.{type FfiKind, type PrepassResult}
import project/staging
import simplifile
import tom

/// A discovered, validated, and parsed third-party Hex package dependency
/// loaded from `build/packages/<package>`.
pub type LoadedDependency {
  LoadedDependency(
    package_name: String,
    version: String,
    package_root: String,
    modules: List(#(String, glance.Module, PrepassResult)),
    interface: Option(PackageInterface),
  )
}

type DiscoveredPkg {
  DiscoveredPkg(
    package_name: String,
    version: String,
    package_root: String,
    deps: List(String),
  )
}

/// Return True if `pkg_name` is handled directly by `gekko`'s built-in MoonBit
/// runtime shims or target-specific test/runtime packages that must not be
/// transpiled from Erlang/JS sources.
pub fn is_intercepted_package(pkg_name: String) -> Bool {
  case pkg_name {
    "gleam_stdlib"
    | "gleam_json"
    | "gleeunit"
    | "gleam_erlang"
    | "gleam_javascript" -> True
    _ -> False
  }
}

/// Read `(name, version)` from `<project_root>/gleam.toml`.
pub fn read_project_meta(
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

/// Recursively discover and parse all `.gleam` modules under `base_dir`.
pub fn discover_and_parse(
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

/// Discover, topologically sort, parse, validate externals, and extract
/// compiler interfaces for all non-intercepted Hex dependencies in
/// `<project_root>/build/packages/`.
pub fn load_dependencies(
  project_root: String,
  ffi_overrides: Dict(String, FfiKind),
) -> Result(List(LoadedDependency), String) {
  use #(root_name, _) <- result.try(read_project_meta(project_root))
  let packages_dir =
    project_root
    |> filepath.join("build")
    |> filepath.join("packages")

  case simplifile.is_directory(packages_dir) {
    Ok(True) -> {
      use discovered <- result.try(discover_packages(packages_dir, root_name))
      let ordered = topo_sort_packages(discovered)
      list.try_map(ordered, fn(pkg) {
        load_single_dependency(project_root, pkg, ffi_overrides)
      })
    }
    _ -> Ok([])
  }
}

fn discover_packages(
  packages_dir: String,
  root_name: String,
) -> Result(List(DiscoveredPkg), String) {
  use entries <- result.try(
    simplifile.read_directory(at: packages_dir)
    |> result.map_error(fn(err) {
      "Failed to read packages directory "
      <> packages_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  let sorted_entries = list.sort(entries, string.compare)
  list.try_fold(sorted_entries, [], fn(acc, entry) {
    let pkg_root = filepath.join(packages_dir, entry)
    let toml_path = filepath.join(pkg_root, "gleam.toml")
    let src_dir = filepath.join(pkg_root, "src")
    case
      simplifile.is_directory(pkg_root),
      simplifile.is_file(toml_path),
      simplifile.is_directory(src_dir)
    {
      Ok(True), Ok(True), Ok(True) -> {
        use #(name, version, deps) <- result.try(read_package_manifest(
          toml_path,
          entry,
        ))
        case name == root_name || is_intercepted_package(name) {
          True -> Ok(acc)
          False ->
            Ok([
              DiscoveredPkg(
                package_name: name,
                version:,
                package_root: pkg_root,
                deps:,
              ),
              ..acc
            ])
        }
      }
      _, _, _ -> Ok(acc)
    }
  })
  |> result.map(list.reverse)
}

fn read_package_manifest(
  toml_path: String,
  fallback_name: String,
) -> Result(#(String, String, List(String)), String) {
  use content <- result.try(
    simplifile.read(toml_path)
    |> result.map_error(fn(err) {
      "Failed to read " <> toml_path <> ": " <> simplifile.describe_error(err)
    }),
  )
  use parsed <- result.try(
    tom.parse(content)
    |> result.map_error(fn(_) { "Failed to parse " <> toml_path <> " as TOML" }),
  )
  let name = case tom.get_string(parsed, ["name"]) {
    Ok(n) -> n
    Error(_) -> fallback_name
  }
  let version = case tom.get_string(parsed, ["version"]) {
    Ok(v) -> v
    Error(_) -> "0.1.0"
  }
  let deps = case tom.get_table(parsed, ["dependencies"]) {
    Ok(tbl) ->
      tbl
      |> dict.keys
      |> list.sort(string.compare)
    Error(_) -> []
  }
  Ok(#(name, version, deps))
}

fn topo_sort_packages(pkgs: List(DiscoveredPkg)) -> List(DiscoveredPkg) {
  let by_name =
    list.fold(pkgs, dict.new(), fn(acc, pkg) {
      dict.insert(acc, pkg.package_name, pkg)
    })

  let #(_, rev_ordered) =
    list.fold(pkgs, #(set.new(), []), fn(state, pkg) {
      visit_pkg(pkg.package_name, by_name, set.new(), state)
    })
  list.reverse(rev_ordered)
}

fn visit_pkg(
  name: String,
  by_name: Dict(String, DiscoveredPkg),
  visiting: Set(String),
  state: #(Set(String), List(DiscoveredPkg)),
) -> #(Set(String), List(DiscoveredPkg)) {
  let #(visited, acc) = state
  case set.contains(visited, name) || set.contains(visiting, name) {
    True -> state
    False ->
      case dict.get(by_name, name) {
        Error(_) -> state
        Ok(pkg) -> {
          let next_visiting = set.insert(visiting, name)
          let #(visited1, acc1) =
            list.fold(pkg.deps, #(visited, acc), fn(st, dep) {
              visit_pkg(dep, by_name, next_visiting, st)
            })
          #(set.insert(visited1, name), [pkg, ..acc1])
        }
      }
  }
}

fn load_single_dependency(
  project_root: String,
  pkg: DiscoveredPkg,
  ffi_overrides: Dict(String, FfiKind),
) -> Result(LoadedDependency, String) {
  let src_dir = filepath.join(pkg.package_root, "src")
  use modules <- result.try(discover_and_parse(src_dir, None))
  use _ <- result.try(validate_dependency_externals(
    pkg.package_name,
    modules,
    ffi_overrides,
  ))

  let dep_staging =
    project_root
    |> filepath.join("build")
    |> filepath.join(".gekko_staging_deps")
    |> filepath.join(pkg.package_name)
  use iface <- result.try(staging.extract_package_interface_with_deps(
    pkg.package_root,
    project_root,
    dep_staging,
  ))

  Ok(LoadedDependency(
    package_name: pkg.package_name,
    version: pkg.version,
    package_root: pkg.package_root,
    modules:,
    interface: Some(iface),
  ))
}

fn validate_dependency_externals(
  pkg_name: String,
  modules: List(#(String, glance.Module, PrepassResult)),
  ffi_overrides: Dict(String, FfiKind),
) -> Result(Nil, String) {
  list.try_each(modules, fn(entry) {
    let #(mod_name, ast_mod, prepass_res) = entry
    list.try_each(ast_mod.functions, fn(fn_def) {
      case symbol_table.is_excluded_target(fn_def.attributes) {
        True -> Ok(Nil)
        False -> {
          let fn_name = fn_def.definition.name
          let has_erl_or_js = has_erlang_or_js_external(fn_def.attributes)
          let has_ffi_mapping =
            symbol_table.resolve_function_ffi(
              pkg_name,
              mod_name,
              fn_name,
              prepass_res,
              ffi_overrides,
            )
            != None
          let has_fallback_body = fn_def.definition.body != []
          case has_erl_or_js && !has_ffi_mapping && !has_fallback_body {
            True ->
              Error(
                "Unmapped external function "
                <> pkg_name
                <> ":"
                <> mod_name
                <> "."
                <> fn_name
                <> " (add an override in gekko.toml)",
              )
            False -> Ok(Nil)
          }
        }
      }
    })
  })
}

fn has_erlang_or_js_external(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attr) {
    case attr.name, attr.arguments {
      "external", [glance.Variable(name: "erlang", ..), ..]
      | "external", [glance.Variable(name: "javascript", ..), ..]
      -> True
      _, _ -> False
    }
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

fn format_glance_error(err: glance.Error) -> String {
  case err {
    glance.UnexpectedEndOfInput -> "unexpected end of input"
    glance.UnexpectedToken(token: _, position:) ->
      "unexpected token at byte offset " <> string.inspect(position.byte_offset)
  }
}
