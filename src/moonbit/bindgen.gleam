import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import moonbit/mbti.{
  type MbtiConst, type MbtiFnDecl, type MbtiPackage, type MbtiParam,
  type MbtiType, type MbtiTypeDecl, MbtiEnum, MbtiFn, MbtiNamed, MbtiOption,
  MbtiStruct, MbtiTraitObject, MbtiTuple,
}
import project/cmd
import project/ffi_config
import project/loader
import project/workspace
import simplifile

/// Output produced by generating Gleam bindings and optional MoonBit adapter
/// code for a MoonBit `.mbti` package.
pub type BindgenResult {
  BindgenResult(
    gleam_module_path: String,
    gleam_source: String,
    adapter_pkg_dir: Option(String),
    adapter_mbt_source: Option(String),
    adapter_moon_pkg: Option(String),
    skipped_items: List(#(String, String)),
  )
}

type TypeConv {
  Direct
  NarrowInt32
  NarrowUInt32
  NarrowInt16
  NarrowUInt16
  NarrowByte
  ReinterpretUInt64
  Float32
  StringViewConv
  CharConv
  BytesConv
  BytesViewConv
  ArrayConv(TypeConv)
  ArrayViewConv(TypeConv)
  FixedArrayConv(TypeConv)
  OptionConv(TypeConv)
  ResultConv(TypeConv, TypeConv)
  TupleConv(List(TypeConv))
  FnConv(List(TypeConv), TypeConv)
}

type ResolvedTypeSpec {
  ResolvedTypeSpec(
    gleam_ty: String,
    adapter_ty: String,
    mbt_ty: String,
    conv: TypeConv,
    needs_option: Bool,
    needs_gprelude: Bool,
    needs_float_pkg: Bool,
    needs_int16_pkg: Bool,
    used_external_types: Dict(String, ExternalTypeRef),
  )
}

type ExternalTypeRef {
  ExternalTypeRef(
    gleam_name: String,
    pkg_path: String,
    mbt_name: String,
    arity: Int,
  )
}

type BindContext {
  BindContext(
    mbti: MbtiPackage,
    project_name: String,
    target_alias: String,
    adapter_pkg_name: String,
    local_type_arities: Dict(String, Int),
    import_alias_to_pkg: Dict(String, String),
  )
}

type EmittedFn {
  EmittedFn(
    gleam_stub: String,
    adapter_fn: Option(String),
    needs_option: Bool,
    needs_gprelude: Bool,
    needs_float_pkg: Bool,
    needs_int16_pkg: Bool,
    helper_kinds: Set(String),
    ext_types: Dict(String, ExternalTypeRef),
    extra_imports: Dict(String, String),
  )
}

/// Generate Gleam FFI stubs (`@external_type` + `@external`) and any required
/// MoonBit adapter package from a parsed `MbtiPackage`.
pub fn generate_bindings(
  pkg: MbtiPackage,
  project_name: String,
  gleam_module_name: String,
) -> BindgenResult {
  let target_alias = pkg_to_moon_alias(pkg.package_name)
  let adapter_pkg_name = last_segment_snake(pkg.package_name) <> "_adapter"

  let local_type_arities =
    list.fold(pkg.types, dict.new(), fn(acc, td) {
      dict.insert(acc, td.name, list.length(td.type_params))
    })

  let import_alias_to_pkg =
    list.fold(pkg.imports, dict.new(), fn(acc, imp) {
      dict.insert(acc, imp.1, imp.0)
    })

  let bctx =
    BindContext(
      mbti: pkg,
      project_name:,
      target_alias:,
      adapter_pkg_name:,
      local_type_arities:,
      import_alias_to_pkg:,
    )

  let used_names0 =
    list.fold(pkg.types, set.new(), fn(acc, td) {
      set.insert(acc, to_snake_case(td.name))
    })

  // Count method/fn names to disambiguate colliding methods via `<type>_<name>`.
  let active_fns = list.filter(pkg.functions, fn(f) { !f.is_deprecated })
  let fn_name_counts = count_function_base_names(active_fns)

  let #(rev_items, skipped_fns, used_names1) =
    generate_fn_items(bctx, active_fns, fn_name_counts, used_names0, [], [])

  let skipped_deprecated_fns =
    pkg.functions
    |> list.filter(fn(f) { f.is_deprecated })
    |> list.map(fn(f) { #(format_fn_label(f), "deprecated") })

  let #(const_items, skipped_consts, used_names2) =
    generate_const_items(bctx, pkg.constants, used_names1)

  let #(struct_enum_items, skipped_struct_items, _used_names3) =
    generate_type_helper_items(bctx, pkg.types, used_names2)

  let all_items =
    list.flatten([
      list.reverse(rev_items),
      const_items,
      struct_enum_items,
    ])
  let all_skipped =
    list.flatten([
      skipped_fns,
      skipped_deprecated_fns,
      skipped_consts,
      skipped_struct_items,
    ])

  let needs_option = list.any(all_items, fn(it) { it.needs_option })
  let needs_gprelude = list.any(all_items, fn(it) { it.needs_gprelude })
  let needs_float = list.any(all_items, fn(it) { it.needs_float_pkg })
  let needs_int16 = list.any(all_items, fn(it) { it.needs_int16_pkg })

  let used_ext_types =
    list.fold(all_items, dict.new(), fn(acc, it) {
      dict.merge(acc, it.ext_types)
    })

  let ext_type_decls = build_external_type_decls(pkg, used_ext_types)

  let adapter_fns =
    list.filter_map(all_items, fn(it) {
      case it.adapter_fn {
        Some(src) -> Ok(src)
        None -> Error(Nil)
      }
    })

  let helper_kinds =
    list.fold(all_items, set.new(), fn(acc, it) {
      set.union(acc, it.helper_kinds)
    })

  let #(adapter_pkg_dir, adapter_mbt_source, adapter_moon_pkg) = case
    adapter_fns
  {
    [] -> #(None, None, None)
    _ -> {
      let extra_imports =
        list.fold(all_items, dict.new(), fn(acc, it) {
          dict.merge(acc, it.extra_imports)
        })
      let helper_defs = emit_adapter_helpers(helper_kinds)
      let mbt_body =
        list.append(helper_defs, adapter_fns)
        |> string.join("\n\n")
      let pkg_file =
        emit_adapter_moon_pkg(
          bctx,
          needs_gprelude,
          needs_float,
          needs_int16,
          extra_imports,
        )
      #(Some(adapter_pkg_name), Some(mbt_body <> "\n"), Some(pkg_file))
    }
  }

  let gleam_source =
    render_gleam_source(
      needs_option,
      ext_type_decls,
      list.map(all_items, fn(it) { it.gleam_stub }),
      all_skipped,
    )

  BindgenResult(
    gleam_module_path: gleam_module_name,
    gleam_source:,
    adapter_pkg_dir:,
    adapter_mbt_source:,
    adapter_moon_pkg:,
    skipped_items: all_skipped,
  )
}

/// Resolve `pkg` (path to `.mbti`, `moonbitlang/core/<subpath>`, or local
/// `moonbit/<pkg>`), run `moon info` if needed, generate Gleam bindings and
/// any adapter package, and write them into `project_root`.
pub fn bind_package(
  project_root: String,
  pkg: String,
  gleam_module: Option(String),
  out_dir: String,
) -> Result(BindgenResult, String) {
  use #(project_name, _) <- result.try(loader.read_project_meta(project_root))
  use #(mbti_source, inferred_default_mod) <- result.try(locate_mbti_source(
    project_root,
    pkg,
    out_dir,
  ))
  use parsed <- result.try(mbti.parse_mbti(mbti_source))
  let target_mod = case gleam_module {
    Some(m) -> normalize_module_name(m)
    None -> inferred_default_mod
  }
  let res = generate_bindings(parsed, project_name, target_mod)

  let gleam_dest =
    filepath.join(project_root, "src/" <> res.gleam_module_path <> ".gleam")
  use _ <- result.try(write_with_parents(gleam_dest, res.gleam_source))

  case res.adapter_pkg_dir, res.adapter_mbt_source, res.adapter_moon_pkg {
    Some(dir), Some(mbt_src), Some(pkg_cfg) -> {
      let adapter_dir = filepath.join(project_root, "moonbit/" <> dir)
      use _ <- result.try(write_with_parents(
        filepath.join(adapter_dir, dir <> ".mbt"),
        mbt_src,
      ))
      use _ <- result.try(write_with_parents(
        filepath.join(adapter_dir, "moon.pkg"),
        pkg_cfg,
      ))
      Ok(res)
    }
    _, _, _ -> Ok(res)
  }
}

fn locate_mbti_source(
  project_root: String,
  pkg: String,
  out_dir: String,
) -> Result(#(String, String), String) {
  case string.ends_with(pkg, ".mbti") {
    True -> {
      use src <- result.try(read_file_err(pkg))
      use parsed <- result.try(mbti.parse_mbti(src))
      Ok(#(src, "ffi/" <> last_segment_snake(parsed.package_name)))
    }
    False ->
      case string.starts_with(pkg, "moonbitlang/core/") {
        True -> {
          let subpath = string.drop_start(pkg, 17)
          use moon_home <- result.try(resolve_moon_home())
          let mbti_path =
            filepath.join(
              moon_home,
              "lib/core/" <> subpath <> "/pkg.generated.mbti",
            )
          use src <- result.try(read_file_err(mbti_path))
          Ok(#(src, "ffi/" <> last_segment_snake(pkg)))
        }
        False -> {
          let rel_pkg = case string.starts_with(pkg, "moonbit/") {
            True -> string.drop_start(pkg, 8)
            False -> pkg
          }
          let is_local_dir =
            simplifile.is_directory(filepath.join(
              project_root,
              "moonbit/" <> rel_pkg,
            ))
            == Ok(True)
          case
            !is_local_dir,
            read_mbti_from_registry_cache(project_root, rel_pkg)
          {
            True, Ok(found) -> Ok(found)
            _, _ -> {
              use _ <- result.try(workspace.transpile_project(
                project_root,
                out_dir,
              ))
              let info_res =
                cmd.run(command: "moon", args: ["info"], cwd: out_dir)
              case info_res.exit_code {
                0 -> {
                  let local_mbti =
                    filepath.join(out_dir, rel_pkg <> "/pkg.generated.mbti")
                  let cake_mbti =
                    filepath.join(
                      out_dir,
                      ".mooncakes/" <> rel_pkg <> "/pkg.generated.mbti",
                    )
                  case simplifile.is_file(local_mbti) {
                    Ok(True) -> {
                      use src <- result.try(read_file_err(local_mbti))
                      Ok(#(src, "ffi/" <> last_segment_snake(rel_pkg)))
                    }
                    _ ->
                      case simplifile.is_file(cake_mbti) {
                        Ok(True) -> {
                          use src <- result.try(read_file_err(cake_mbti))
                          Ok(#(src, "ffi/" <> last_segment_snake(rel_pkg)))
                        }
                        _ ->
                          Error(
                            "Could not find pkg.generated.mbti for package '"
                            <> pkg
                            <> "' after `moon info`",
                          )
                      }
                  }
                }
                _ ->
                  Error(
                    "`moon info` failed while inspecting package '"
                    <> pkg
                    <> "':\n"
                    <> info_res.output,
                  )
              }
            }
          }
        }
      }
  }
}

fn read_mbti_from_registry_cache(
  project_root: String,
  rel_pkg: String,
) -> Result(#(String, String), String) {
  use deps <- result.try(ffi_config.load_project_moonbit_deps(project_root))
  use #(dep_mod, dep_ver) <- result.try(
    list.find(deps, fn(entry) {
      let #(dep_mod, _) = entry
      rel_pkg == dep_mod || string.starts_with(rel_pkg, dep_mod <> "/")
    })
    |> result.map_error(fn(_) { "not found in [moonbit.deps]" }),
  )
  use moon_home <- result.try(resolve_moon_home())
  let zip_path =
    filepath.join(
      moon_home,
      "registry/cache/" <> dep_mod <> "/" <> dep_ver <> ".zip",
    )
  let inner_mbti = case rel_pkg == dep_mod {
    True -> "pkg.generated.mbti"
    False ->
      string.drop_start(rel_pkg, string.length(dep_mod) + 1)
      <> "/pkg.generated.mbti"
  }
  let unzip_res =
    cmd.run(command: "unzip", args: ["-p", zip_path, inner_mbti], cwd: ".")
  case unzip_res.exit_code == 0 && unzip_res.output != "" {
    True -> Ok(#(unzip_res.output, "ffi/" <> last_segment_snake(rel_pkg)))
    False ->
      Error(
        "failed to read '" <> inner_mbti <> "' from cached archive " <> zip_path,
      )
  }
}

fn resolve_moon_home() -> Result(String, String) {
  case cmd.get_env("MOON_HOME") {
    Ok(v) if v != "" -> Ok(v)
    _ ->
      case cmd.get_env("HOME") {
        Ok(h) if h != "" -> Ok(filepath.join(h, ".moon"))
        _ ->
          Error(
            "Could not determine MOON_HOME or HOME to locate core .mbti files",
          )
      }
  }
}

fn normalize_module_name(raw: String) -> String {
  let no_prefix = case string.starts_with(raw, "src/") {
    True -> string.drop_start(raw, 4)
    False -> raw
  }
  case string.ends_with(no_prefix, ".gleam") {
    True -> string.drop_end(no_prefix, 6)
    False -> no_prefix
  }
}

fn count_function_base_names(fns: List(MbtiFnDecl)) -> Dict(String, Int) {
  list.fold(fns, dict.new(), fn(acc, f) {
    let key = case f.owner_type {
      Some(owner) if owner == f.name -> "new_" <> to_snake_case(owner)
      _ -> f.name
    }
    let prev = dict.get(acc, key) |> result.unwrap(0)
    dict.insert(acc, key, prev + 1)
  })
}

fn generate_fn_items(
  bctx: BindContext,
  fns: List(MbtiFnDecl),
  counts: Dict(String, Int),
  used_names: Set(String),
  rev_items: List(EmittedFn),
  rev_skipped: List(#(String, String)),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  case fns {
    [] -> #(rev_items, list.reverse(rev_skipped), used_names)
    [f, ..rest] -> {
      let label = format_fn_label(f)
      let base_gleam_name = case f.owner_type {
        Some(owner) if owner == f.name -> "new_" <> to_snake_case(owner)
        Some(owner) ->
          case dict.get(counts, f.name) |> result.unwrap(1) > 1 {
            True -> to_snake_case(owner) <> "_" <> to_snake_case(f.name)
            False -> to_snake_case(f.name)
          }
        None -> to_snake_case(f.name)
      }
      case convert_fn_decl(bctx, f, base_gleam_name, used_names) {
        Ok(#(item, next_used)) ->
          generate_fn_items(
            bctx,
            rest,
            counts,
            next_used,
            [item, ..rev_items],
            rev_skipped,
          )
        Error(reason) ->
          generate_fn_items(bctx, rest, counts, used_names, rev_items, [
            #(label, reason),
            ..rev_skipped
          ])
      }
    }
  }
}

fn convert_fn_decl(
  bctx: BindContext,
  f: MbtiFnDecl,
  base_gleam_name: String,
  used_names: Set(String),
) -> Result(#(EmittedFn, Set(String)), String) {
  use _ <- result.try(case f.is_async {
    True -> Error("async functions are not supported")
    False -> Ok(Nil)
  })
  use _ <- result.try(case f.poly_raise {
    True -> Error("polymorphic raise? effects are not supported")
    False -> Ok(Nil)
  })
  use _ <- result.try(case list.find(f.type_params, fn(tp) { tp.1 != [] }) {
    Ok(#(tp, bounds)) ->
      Error(
        "bounded type parameter `"
        <> tp
        <> " : "
        <> string.join(bounds, " + ")
        <> "`",
      )
    Error(_) -> Ok(Nil)
  })

  let fn_tp_names = list.map(f.type_params, fn(tp) { tp.0 })
  let tp_map =
    list.fold(fn_tp_names, dict.new(), fn(acc, tp) {
      dict.insert(acc, tp, sanitize_gleam_type_var(tp))
    })

  let self_sub = case f.owner_type {
    Some(owner) -> {
      let arity = dict.get(bctx.local_type_arities, owner) |> result.unwrap(0)
      Some(#(owner, arity))
    }
    None -> None
  }

  let param_count = list.length(f.params)
  use #(resolved_params, param_names) <- result.try(
    resolve_fn_params(
      bctx,
      f.params,
      self_sub,
      tp_map,
      f.owner_type != None,
      0,
      param_count,
      set.new(),
      [],
      [],
    ),
  )

  let resolved_ret_mbti = substitute_self(f.return_type, self_sub)
  use resolved_ret <- result.try(resolve_type(bctx, resolved_ret_mbti, tp_map))

  let gleam_name = pick_unique_gleam_name(base_gleam_name, used_names)
  let next_used = set.insert(used_names, gleam_name)

  let any_labelled_or_opt =
    list.any(f.params, fn(p) { option.is_some(p.label) || p.is_optional })
  let all_direct_params =
    list.all(resolved_params, fn(rp) { rp.1.conv == Direct })
  let direct_ok =
    f.owner_type == None
    && !any_labelled_or_opt
    && !f.raises
    && all_direct_params
    && resolved_ret.conv == Direct
    && !is_constructor_like_direct_collision(f)

  let gleam_ret_ty = case f.raises {
    True -> "Result(" <> resolved_ret.gleam_ty <> ", String)"
    False -> resolved_ret.gleam_ty
  }

  let gleam_param_sig =
    list.zip(param_names, resolved_params)
    |> list.map(fn(pair) { pair.0 <> ": " <> pair.1.1.gleam_ty })
    |> string.join(", ")

  let target_pkg = case direct_ok {
    True -> bctx.mbti.package_name
    False -> bctx.adapter_pkg_name
  }
  let target_fn = case direct_ok {
    True -> f.name
    False -> gleam_name
  }

  let body_ignores =
    param_names
    |> list.map(fn(pn) { "  let _ = " <> pn })
    |> string.join("\n")
  let body_lines = case body_ignores {
    "" -> "  panic as \"Implemented in MoonBit\""
    _ -> body_ignores <> "\n  panic as \"Implemented in MoonBit\""
  }

  let gleam_stub =
    "/// @external(moonbit, \""
    <> target_pkg
    <> "\", \""
    <> target_fn
    <> "\")\n"
    <> "pub fn "
    <> gleam_name
    <> "("
    <> gleam_param_sig
    <> ") -> "
    <> gleam_ret_ty
    <> " {\n"
    <> body_lines
    <> "\n}"

  let #(
    adapter_fn,
    helper_kinds,
    needs_gprelude,
    needs_float,
    needs_int16,
    extra_imports,
  ) = case direct_ok {
    True -> #(None, set.new(), False, False, False, dict.new())
    False ->
      build_adapter_fn(
        bctx,
        f,
        gleam_name,
        fn_tp_names,
        param_names,
        resolved_params,
        resolved_ret,
      )
  }

  let needs_option =
    resolved_ret.needs_option
    || list.any(resolved_params, fn(rp) { rp.1.needs_option })
  let ext_types =
    list.fold(resolved_params, resolved_ret.used_external_types, fn(acc, rp) {
      dict.merge(acc, rp.1.used_external_types)
    })

  Ok(#(
    EmittedFn(
      gleam_stub:,
      adapter_fn:,
      needs_option:,
      needs_gprelude:,
      needs_float_pkg: needs_float,
      needs_int16_pkg: needs_int16,
      helper_kinds:,
      ext_types:,
      extra_imports:,
    ),
    next_used,
  ))
}

fn is_constructor_like_direct_collision(_f: MbtiFnDecl) -> Bool {
  False
}

fn resolve_fn_params(
  bctx: BindContext,
  params: List(MbtiParam),
  self_sub: Option(#(String, Int)),
  tp_map: Dict(String, String),
  has_owner: Bool,
  idx: Int,
  total: Int,
  used_names: Set(String),
  rev_resolved: List(#(MbtiParam, ResolvedTypeSpec)),
  rev_names: List(String),
) -> Result(#(List(#(MbtiParam, ResolvedTypeSpec)), List(String)), String) {
  case params {
    [] -> Ok(#(list.reverse(rev_resolved), list.reverse(rev_names)))
    [p, ..rest] -> {
      let sub_ty = substitute_self(p.param_type, self_sub)
      let effective_ty = case p.is_optional {
        True -> MbtiOption(sub_ty)
        False -> sub_ty
      }
      use spec <- result.try(resolve_type(bctx, effective_ty, tp_map))
      let raw_name = case p.label {
        Some(lbl) -> to_snake_case(lbl)
        None ->
          case idx == 0 && has_owner && is_self_type(p.param_type, self_sub) {
            True -> "self"
            False ->
              case total == 1 && !has_owner {
                True -> "x"
                False -> "arg" <> int.to_string(idx)
              }
          }
      }
      let safe_name = pick_unique_gleam_name(raw_name, used_names)
      resolve_fn_params(
        bctx,
        rest,
        self_sub,
        tp_map,
        has_owner,
        idx + 1,
        total,
        set.insert(used_names, safe_name),
        [#(p, spec), ..rev_resolved],
        [safe_name, ..rev_names],
      )
    }
  }
}

fn is_self_type(ty: MbtiType, self_sub: Option(#(String, Int))) -> Bool {
  case ty, self_sub {
    MbtiNamed(None, "Self", _), _ -> True
    MbtiNamed(None, name, _), Some(#(owner, _)) if name == owner -> True
    _, _ -> False
  }
}

fn substitute_self(ty: MbtiType, self_sub: Option(#(String, Int))) -> MbtiType {
  case self_sub {
    None -> ty
    Some(#(owner, arity)) ->
      case ty {
        MbtiNamed(None, "Self", []) -> {
          let default_args =
            int_range_names("T", arity)
            |> list.map(fn(tp) { MbtiNamed(None, tp, []) })
          case arity == 0 {
            True -> MbtiNamed(None, owner, [])
            False -> MbtiNamed(None, owner, default_args)
          }
        }
        MbtiNamed(None, "Self", args) ->
          MbtiNamed(
            None,
            owner,
            list.map(args, fn(a) { substitute_self(a, self_sub) }),
          )
        MbtiNamed(qualifier:, name:, args:) ->
          MbtiNamed(
            qualifier:,
            name:,
            args: list.map(args, fn(a) { substitute_self(a, self_sub) }),
          )
        MbtiOption(inner) -> MbtiOption(substitute_self(inner, self_sub))
        MbtiTuple(els) ->
          MbtiTuple(list.map(els, fn(e) { substitute_self(e, self_sub) }))
        MbtiFn(is_async:, params:, return_type:, raises:, poly_raise:) ->
          MbtiFn(
            is_async:,
            params: list.map(params, fn(p) { substitute_self(p, self_sub) }),
            return_type: substitute_self(return_type, self_sub),
            raises:,
            poly_raise:,
          )
        MbtiTraitObject(_) -> ty
      }
  }
}

fn resolve_type(
  bctx: BindContext,
  ty: MbtiType,
  tp_map: Dict(String, String),
) -> Result(ResolvedTypeSpec, String) {
  case ty {
    MbtiTraitObject(t) -> Error("trait object `&" <> t <> "`")

    MbtiOption(inner) -> {
      use spec <- result.try(resolve_type(bctx, inner, tp_map))
      Ok(ResolvedTypeSpec(
        gleam_ty: "Option(" <> spec.gleam_ty <> ")",
        adapter_ty: spec.adapter_ty <> "?",
        mbt_ty: spec.mbt_ty <> "?",
        conv: OptionConv(spec.conv),
        needs_option: True,
        needs_gprelude: spec.needs_gprelude,
        needs_float_pkg: spec.needs_float_pkg,
        needs_int16_pkg: spec.needs_int16_pkg,
        used_external_types: spec.used_external_types,
      ))
    }

    MbtiTuple(els) -> {
      use specs <- result.try(
        list.try_map(els, fn(e) { resolve_type(bctx, e, tp_map) }),
      )
      Ok(ResolvedTypeSpec(
        gleam_ty: "#("
          <> { list.map(specs, fn(s) { s.gleam_ty }) |> string.join(", ") }
          <> ")",
        adapter_ty: "("
          <> { list.map(specs, fn(s) { s.adapter_ty }) |> string.join(", ") }
          <> ")",
        mbt_ty: "("
          <> { list.map(specs, fn(s) { s.mbt_ty }) |> string.join(", ") }
          <> ")",
        conv: TupleConv(list.map(specs, fn(s) { s.conv })),
        needs_option: list.any(specs, fn(s) { s.needs_option }),
        needs_gprelude: list.any(specs, fn(s) { s.needs_gprelude }),
        needs_float_pkg: list.any(specs, fn(s) { s.needs_float_pkg }),
        needs_int16_pkg: list.any(specs, fn(s) { s.needs_int16_pkg }),
        used_external_types: list.fold(specs, dict.new(), fn(acc, s) {
          dict.merge(acc, s.used_external_types)
        }),
      ))
    }

    MbtiFn(is_async:, params:, return_type:, raises:, poly_raise:) -> {
      use _ <- result.try(case is_async || raises || poly_raise {
        True -> Error("effectful or async callback type")
        False -> Ok(Nil)
      })
      use p_specs <- result.try(
        list.try_map(params, fn(p) { resolve_type(bctx, p, tp_map) }),
      )
      use r_spec <- result.try(resolve_type(bctx, return_type, tp_map))
      let conv = FnConv(list.map(p_specs, fn(s) { s.conv }), r_spec.conv)
      let ext =
        list.fold(p_specs, r_spec.used_external_types, fn(acc, s) {
          dict.merge(acc, s.used_external_types)
        })
      Ok(ResolvedTypeSpec(
        gleam_ty: "fn("
          <> { list.map(p_specs, fn(s) { s.gleam_ty }) |> string.join(", ") }
          <> ") -> "
          <> r_spec.gleam_ty,
        adapter_ty: "("
          <> { list.map(p_specs, fn(s) { s.adapter_ty }) |> string.join(", ") }
          <> ") -> "
          <> r_spec.adapter_ty,
        mbt_ty: "("
          <> { list.map(p_specs, fn(s) { s.mbt_ty }) |> string.join(", ") }
          <> ") -> "
          <> r_spec.mbt_ty,
        conv:,
        needs_option: r_spec.needs_option
          || list.any(p_specs, fn(s) { s.needs_option }),
        needs_gprelude: r_spec.needs_gprelude
          || list.any(p_specs, fn(s) { s.needs_gprelude }),
        needs_float_pkg: r_spec.needs_float_pkg
          || list.any(p_specs, fn(s) { s.needs_float_pkg }),
        needs_int16_pkg: r_spec.needs_int16_pkg
          || list.any(p_specs, fn(s) { s.needs_int16_pkg }),
        used_external_types: ext,
      ))
    }

    MbtiNamed(qualifier:, name:, args:) ->
      resolve_named_type(bctx, qualifier, name, args, tp_map)
  }
}

fn resolve_named_type(
  bctx: BindContext,
  qualifier: Option(String),
  name: String,
  args: List(MbtiType),
  tp_map: Dict(String, String),
) -> Result(ResolvedTypeSpec, String) {
  case qualifier, name, args {
    None, _, [] ->
      case dict.get(tp_map, name) {
        Ok(gleam_tp) ->
          Ok(ResolvedTypeSpec(
            gleam_ty: gleam_tp,
            adapter_ty: name,
            mbt_ty: name,
            conv: Direct,
            needs_option: False,
            needs_gprelude: False,
            needs_float_pkg: False,
            needs_int16_pkg: False,
            used_external_types: dict.new(),
          ))
        Error(_) -> resolve_concrete_named(bctx, None, name, args, tp_map)
      }
    _, _, _ -> resolve_concrete_named(bctx, qualifier, name, args, tp_map)
  }
}

fn resolve_concrete_named(
  bctx: BindContext,
  qualifier: Option(String),
  name: String,
  args: List(MbtiType),
  tp_map: Dict(String, String),
) -> Result(ResolvedTypeSpec, String) {
  case qualifier, name, args {
    None, "Int64", [] -> simple_spec("Int", "Int64", "Int64", Direct)
    None, "Double", [] -> simple_spec("Float", "Double", "Double", Direct)
    None, "String", [] -> simple_spec("String", "String", "String", Direct)
    None, "Bool", [] -> simple_spec("Bool", "Bool", "Bool", Direct)
    None, "Unit", [] -> simple_spec("Nil", "Unit", "Unit", Direct)

    None, "Int", [] | None, "Int32", [] ->
      simple_spec("Int", "Int64", name, NarrowInt32)
    None, "UInt", [] | None, "UInt32", [] ->
      simple_spec("Int", "Int64", name, NarrowUInt32)
    None, "Int16", [] ->
      Ok(ResolvedTypeSpec(
        gleam_ty: "Int",
        adapter_ty: "Int64",
        mbt_ty: "Int16",
        conv: NarrowInt16,
        needs_option: False,
        needs_gprelude: False,
        needs_float_pkg: False,
        needs_int16_pkg: True,
        used_external_types: dict.new(),
      ))
    None, "UInt16", [] -> simple_spec("Int", "Int64", "UInt16", NarrowUInt16)
    None, "Byte", [] -> simple_spec("Int", "Int64", "Byte", NarrowByte)
    None, "UInt64", [] ->
      simple_spec("Int", "Int64", "UInt64", ReinterpretUInt64)
    None, "Float", [] ->
      Ok(ResolvedTypeSpec(
        gleam_ty: "Float",
        adapter_ty: "Double",
        mbt_ty: "Float",
        conv: Float32,
        needs_option: False,
        needs_gprelude: False,
        needs_float_pkg: True,
        needs_int16_pkg: False,
        used_external_types: dict.new(),
      ))
    None, "StringView", [] ->
      simple_spec("String", "String", "StringView", StringViewConv)
    None, "Char", [] -> simple_spec("String", "String", "Char", CharConv)
    None, "Bytes", [] ->
      Ok(ResolvedTypeSpec(
        gleam_ty: "BitArray",
        adapter_ty: "@gprelude.BitArray",
        mbt_ty: "Bytes",
        conv: BytesConv,
        needs_option: False,
        needs_gprelude: True,
        needs_float_pkg: False,
        needs_int16_pkg: False,
        used_external_types: dict.new(),
      ))
    None, "BytesView", [] ->
      Ok(ResolvedTypeSpec(
        gleam_ty: "BitArray",
        adapter_ty: "@gprelude.BitArray",
        mbt_ty: "BytesView",
        conv: BytesViewConv,
        needs_option: False,
        needs_gprelude: True,
        needs_float_pkg: False,
        needs_int16_pkg: False,
        used_external_types: dict.new(),
      ))

    None, "Array", [inner] -> {
      use s <- result.try(resolve_type(bctx, inner, tp_map))
      Ok(ResolvedTypeSpec(
        gleam_ty: "List(" <> s.gleam_ty <> ")",
        adapter_ty: "@gprelude.GList[" <> s.adapter_ty <> "]",
        mbt_ty: "Array[" <> s.mbt_ty <> "]",
        conv: ArrayConv(s.conv),
        needs_option: s.needs_option,
        needs_gprelude: True,
        needs_float_pkg: s.needs_float_pkg,
        needs_int16_pkg: s.needs_int16_pkg,
        used_external_types: s.used_external_types,
      ))
    }

    None, "ArrayView", [inner] -> {
      use s <- result.try(resolve_type(bctx, inner, tp_map))
      Ok(ResolvedTypeSpec(
        gleam_ty: "List(" <> s.gleam_ty <> ")",
        adapter_ty: "@gprelude.GList[" <> s.adapter_ty <> "]",
        mbt_ty: "ArrayView[" <> s.mbt_ty <> "]",
        conv: ArrayViewConv(s.conv),
        needs_option: s.needs_option,
        needs_gprelude: True,
        needs_float_pkg: s.needs_float_pkg,
        needs_int16_pkg: s.needs_int16_pkg,
        used_external_types: s.used_external_types,
      ))
    }

    None, "FixedArray", [inner] -> {
      use s <- result.try(resolve_type(bctx, inner, tp_map))
      Ok(ResolvedTypeSpec(
        gleam_ty: "List(" <> s.gleam_ty <> ")",
        adapter_ty: "@gprelude.GList[" <> s.adapter_ty <> "]",
        mbt_ty: "FixedArray[" <> s.mbt_ty <> "]",
        conv: FixedArrayConv(s.conv),
        needs_option: s.needs_option,
        needs_gprelude: True,
        needs_float_pkg: s.needs_float_pkg,
        needs_int16_pkg: s.needs_int16_pkg,
        used_external_types: s.used_external_types,
      ))
    }

    None, "Option", [inner] -> resolve_type(bctx, MbtiOption(inner), tp_map)

    None, "Result", [ok_t, err_t] -> {
      use ok_s <- result.try(resolve_type(bctx, ok_t, tp_map))
      use err_s <- result.try(resolve_type(bctx, err_t, tp_map))
      Ok(ResolvedTypeSpec(
        gleam_ty: "Result(" <> ok_s.gleam_ty <> ", " <> err_s.gleam_ty <> ")",
        adapter_ty: "Result["
          <> ok_s.adapter_ty
          <> ", "
          <> err_s.adapter_ty
          <> "]",
        mbt_ty: "Result[" <> ok_s.mbt_ty <> ", " <> err_s.mbt_ty <> "]",
        conv: ResultConv(ok_s.conv, err_s.conv),
        needs_option: ok_s.needs_option || err_s.needs_option,
        needs_gprelude: ok_s.needs_gprelude || err_s.needs_gprelude,
        needs_float_pkg: ok_s.needs_float_pkg || err_s.needs_float_pkg,
        needs_int16_pkg: ok_s.needs_int16_pkg || err_s.needs_int16_pkg,
        used_external_types: dict.merge(
          ok_s.used_external_types,
          err_s.used_external_types,
        ),
      ))
    }

    _, _, _ -> resolve_opaque_nominal(bctx, qualifier, name, args, tp_map)
  }
}

fn resolve_opaque_nominal(
  bctx: BindContext,
  qualifier: Option(String),
  name: String,
  args: List(MbtiType),
  tp_map: Dict(String, String),
) -> Result(ResolvedTypeSpec, String) {
  use arg_specs <- result.try(
    list.try_map(args, fn(a) { resolve_type(bctx, a, tp_map) }),
  )
  use _ <- result.try(case list.all(arg_specs, fn(s) { s.conv == Direct }) {
    True -> Ok(Nil)
    False -> Error("opaque type `" <> name <> "` with converted type argument")
  })
  let gleam_suffix = case arg_specs {
    [] -> ""
    _ ->
      "("
      <> { list.map(arg_specs, fn(s) { s.gleam_ty }) |> string.join(", ") }
      <> ")"
  }
  let mbt_suffix = case arg_specs {
    [] -> ""
    _ ->
      "["
      <> { list.map(arg_specs, fn(s) { s.adapter_ty }) |> string.join(", ") }
      <> "]"
  }

  use #(pkg_path, pkg_alias, gleam_name) <- result.try(case qualifier {
    Some(q) ->
      case dict.get(bctx.import_alias_to_pkg, q) {
        Ok(full_pkg) -> Ok(#(full_pkg, pkg_to_moon_alias(full_pkg), name))
        Error(_) -> Error("unknown imported package `@" <> q <> "`")
      }
    None ->
      case dict.has_key(bctx.local_type_arities, name) {
        True -> Ok(#(bctx.mbti.package_name, bctx.target_alias, name))
        False ->
          case builtin_nominal_package(name) {
            Some(builtin_pkg) ->
              Ok(#(builtin_pkg, pkg_to_moon_alias(builtin_pkg), name))
            None -> Error("unknown type `" <> name <> "`")
          }
      }
  })

  let ext_ref =
    ExternalTypeRef(
      gleam_name:,
      pkg_path:,
      mbt_name: name,
      arity: list.length(arg_specs),
    )
  let base_ext = dict.from_list([#(gleam_name, ext_ref)])
  let merged_ext =
    list.fold(arg_specs, base_ext, fn(acc, s) {
      dict.merge(acc, s.used_external_types)
    })

  Ok(ResolvedTypeSpec(
    gleam_ty: gleam_name <> gleam_suffix,
    adapter_ty: "@" <> pkg_alias <> "." <> name <> mbt_suffix,
    mbt_ty: "@" <> pkg_alias <> "." <> name <> mbt_suffix,
    conv: Direct,
    needs_option: list.any(arg_specs, fn(s) { s.needs_option }),
    needs_gprelude: list.any(arg_specs, fn(s) { s.needs_gprelude }),
    needs_float_pkg: list.any(arg_specs, fn(s) { s.needs_float_pkg }),
    needs_int16_pkg: list.any(arg_specs, fn(s) { s.needs_int16_pkg }),
    used_external_types: merged_ext,
  ))
}

fn builtin_nominal_package(name: String) -> Option(String) {
  case name {
    "Json" -> Some("moonbitlang/core/json")
    "Iter"
    | "Iter2"
    | "Map"
    | "MutArrayView"
    | "ReadOnlyArray"
    | "StringBuilder"
    | "SourceLoc"
    | "Error"
    | "ArgsLoc"
    | "Hasher"
    | "FuncRef"
    | "UninitializedArray"
    | "V128" -> Some("moonbitlang/core/builtin")
    _ -> None
  }
}

fn simple_spec(
  gleam_ty: String,
  adapter_ty: String,
  mbt_ty: String,
  conv: TypeConv,
) -> Result(ResolvedTypeSpec, String) {
  Ok(ResolvedTypeSpec(
    gleam_ty:,
    adapter_ty:,
    mbt_ty:,
    conv:,
    needs_option: False,
    needs_gprelude: False,
    needs_float_pkg: False,
    needs_int16_pkg: False,
    used_external_types: dict.new(),
  ))
}

fn build_adapter_fn(
  bctx: BindContext,
  f: MbtiFnDecl,
  gleam_name: String,
  fn_tp_names: List(String),
  param_names: List(String),
  resolved_params: List(#(MbtiParam, ResolvedTypeSpec)),
  resolved_ret: ResolvedTypeSpec,
) -> #(Option(String), Set(String), Bool, Bool, Bool, Dict(String, String)) {
  let generics = case fn_tp_names {
    [] -> ""
    tps -> "[" <> string.join(tps, ", ") <> "]"
  }

  let param_sig =
    list.zip(param_names, resolved_params)
    |> list.map(fn(pair) {
      let #(pname, #(_, spec)) = pair
      mangle_moon_ident(pname) <> " : " <> spec.adapter_ty
    })
    |> string.join(", ")

  let ret_sig = case f.raises {
    True -> "Result[" <> resolved_ret.adapter_ty <> ", String]"
    False -> resolved_ret.adapter_ty
  }

  let #(helper_kinds_params, arg_exprs) =
    list.zip(param_names, resolved_params)
    |> list.map_fold(set.new(), fn(hk, pair) {
      let #(pname, #(mbti_p, spec)) = pair
      let m_pname = mangle_moon_ident(pname)
      let #(val_expr, hk1) = expr_to_mbt(spec.conv, m_pname, hk, 0)
      let formatted = case mbti_p.label {
        None -> val_expr
        Some(lbl) ->
          case mbti_p.is_optional {
            True -> lbl <> "?=" <> val_expr
            False -> lbl <> "=" <> val_expr
          }
      }
      #(hk1, formatted)
    })

  let callee = case f.owner_type {
    Some(owner) if owner == f.name -> "@" <> bctx.target_alias <> "." <> owner
    Some(owner) -> "@" <> bctx.target_alias <> "." <> owner <> "::" <> f.name
    None -> "@" <> bctx.target_alias <> "." <> f.name
  }
  let raw_call = callee <> "(" <> string.join(arg_exprs, ", ") <> ")"

  let #(body, helper_kinds) = case f.raises {
    False -> {
      let #(ret_expr, hk_final) =
        expr_from_mbt(resolved_ret.conv, raw_call, helper_kinds_params, 0)
      #("  " <> ret_expr, hk_final)
    }
    True -> {
      let #(ok_expr, hk_final) =
        expr_from_mbt(resolved_ret.conv, "__res", helper_kinds_params, 0)
      let body_str =
        "  try {\n    let __res = "
        <> raw_call
        <> "\n    Ok("
        <> ok_expr
        <> ")\n  } catch {\n    __err => Err(Error::to_string(__err))\n  }"
      #(body_str, hk_final)
    }
  }

  let needs_gprelude =
    resolved_ret.needs_gprelude
    || list.any(resolved_params, fn(rp) { rp.1.needs_gprelude })
  let needs_float =
    resolved_ret.needs_float_pkg
    || list.any(resolved_params, fn(rp) { rp.1.needs_float_pkg })
  let needs_int16 =
    resolved_ret.needs_int16_pkg
    || list.any(resolved_params, fn(rp) { rp.1.needs_int16_pkg })

  let ext_types =
    list.fold(resolved_params, resolved_ret.used_external_types, fn(acc, rp) {
      dict.merge(acc, rp.1.used_external_types)
    })
  let extra_imports = ext_types_to_extra_imports(bctx, ext_types)

  let mbt_fn =
    "///|\npub fn"
    <> generics
    <> " "
    <> mangle_moon_ident(gleam_name)
    <> "("
    <> param_sig
    <> ") -> "
    <> ret_sig
    <> " {\n"
    <> body
    <> "\n}"

  #(
    Some(mbt_fn),
    helper_kinds,
    needs_gprelude,
    needs_float,
    needs_int16,
    extra_imports,
  )
}

fn expr_to_mbt(
  conv: TypeConv,
  expr: String,
  helpers: Set(String),
  depth: Int,
) -> #(String, Set(String)) {
  case conv {
    Direct -> #(expr, helpers)
    NarrowInt32 -> #("__to_int32(" <> expr <> ")", set.insert(helpers, "int32"))
    NarrowUInt32 -> #(
      "__to_uint32(" <> expr <> ")",
      set.insert(helpers, "uint32"),
    )
    NarrowInt16 -> #("__to_int16(" <> expr <> ")", set.insert(helpers, "int16"))
    NarrowUInt16 -> #(
      "__to_uint16(" <> expr <> ")",
      set.insert(helpers, "uint16"),
    )
    NarrowByte -> #("__to_byte(" <> expr <> ")", set.insert(helpers, "byte"))
    ReinterpretUInt64 -> #("(" <> expr <> ").reinterpret_as_uint64()", helpers)
    Float32 -> #("@float.Float::from_double(" <> expr <> ")", helpers)
    StringViewConv -> #("(" <> expr <> ").to_string_view()", helpers)
    CharConv -> #("__to_char(" <> expr <> ")", set.insert(helpers, "char"))
    BytesConv -> #("(" <> expr <> ").data", helpers)
    BytesViewConv -> #("(" <> expr <> ").data[:]", helpers)

    ArrayConv(Direct) -> #("(" <> expr <> ").to_array()", helpers)
    ArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
      #(
        "(" <> expr <> ").to_array().map(fn(" <> v <> ") { " <> inner_e <> " })",
        h1,
      )
    }

    ArrayViewConv(Direct) -> #("(" <> expr <> ").to_array()[:]", helpers)
    ArrayViewConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
      #(
        "("
          <> expr
          <> ").to_array().map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:]",
        h1,
      )
    }

    FixedArrayConv(Direct) -> #(
      "FixedArray::from_array((" <> expr <> ").to_array()[:])",
      helpers,
    )
    FixedArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
      #(
        "FixedArray::from_array(("
          <> expr
          <> ").to_array().map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:])",
        h1,
      )
    }

    OptionConv(inner) ->
      case inner {
        Direct -> #(expr, helpers)
        _ -> {
          let v = "x" <> int.to_string(depth)
          let #(inner_e, h1) = expr_to_mbt(inner, v, helpers, depth + 1)
          #("(" <> expr <> ").map(fn(" <> v <> ") { " <> inner_e <> " })", h1)
        }
      }

    ResultConv(Direct, Direct) -> #(expr, helpers)
    ResultConv(ok_c, err_c) -> {
      let ok_v = "ok_v" <> int.to_string(depth)
      let err_v = "err_v" <> int.to_string(depth)
      let #(ok_e, h1) = expr_to_mbt(ok_c, ok_v, helpers, depth + 1)
      let #(err_e, h2) = expr_to_mbt(err_c, err_v, h1, depth + 1)
      #(
        "match "
          <> expr
          <> " { Ok("
          <> ok_v
          <> ") => Ok("
          <> ok_e
          <> "); Err("
          <> err_v
          <> ") => Err("
          <> err_e
          <> ") }",
        h2,
      )
    }

    TupleConv(els) ->
      case list.all(els, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, binds_and_exprs) =
            list.index_map(els, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let v =
                "t" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(ce, next_h) = expr_to_mbt(pair.0, v, acc_h, depth + 1)
              #(next_h, #(v, ce))
            })
          let pat =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.0 })
              |> string.join(", ")
            }
            <> ")"
          let out =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          #("{ let " <> pat <> " = " <> expr <> "; " <> out <> " }", h1)
        }
      }

    FnConv(p_convs, r_conv) ->
      case r_conv == Direct && list.all(p_convs, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, params_and_args) =
            list.index_map(p_convs, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let pname =
                "cb" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(arg_e, next_h) =
                expr_from_mbt(pair.0, pname, acc_h, depth + 1)
              #(next_h, #(pname, arg_e))
            })
          let raw_call =
            "("
            <> expr
            <> ")("
            <> {
              list.map(params_and_args, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          let #(ret_e, h2) = expr_to_mbt(r_conv, raw_call, h1, depth + 1)
          let pnames =
            list.map(params_and_args, fn(p) { p.0 })
            |> string.join(", ")
          #("fn(" <> pnames <> ") { " <> ret_e <> " }", h2)
        }
      }
  }
}

fn expr_from_mbt(
  conv: TypeConv,
  expr: String,
  helpers: Set(String),
  depth: Int,
) -> #(String, Set(String)) {
  case conv {
    Direct -> #(expr, helpers)
    NarrowInt32 | NarrowUInt32 | NarrowUInt16 | NarrowByte -> #(
      "(" <> expr <> ").to_int64()",
      helpers,
    )
    NarrowInt16 -> #("@int16.Int16::to_int64(" <> expr <> ")", helpers)
    ReinterpretUInt64 -> #("(" <> expr <> ").reinterpret_as_int64()", helpers)
    Float32 -> #("@float.Float::to_double(" <> expr <> ")", helpers)
    StringViewConv | CharConv -> #("(" <> expr <> ").to_string()", helpers)
    BytesConv -> #("@gprelude.BitArray::from_bytes(" <> expr <> ")", helpers)
    BytesViewConv -> #(
      "@gprelude.BitArray::from_bytes((" <> expr <> ").to_bytes())",
      helpers,
    )

    ArrayConv(Direct) -> #(
      "@gprelude.GList::from_array((" <> expr <> ")[:])",
      helpers,
    )
    ArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:])",
        h1,
      )
    }

    ArrayViewConv(Direct) -> #(
      "@gprelude.GList::from_array(" <> expr <> ")",
      helpers,
    )
    ArrayViewConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " })[:])",
        h1,
      )
    }

    FixedArrayConv(Direct) -> #(
      "@gprelude.GList::from_array((" <> expr <> ").iter().to_array()[:])",
      helpers,
    )
    FixedArrayConv(inner) -> {
      let v = "x" <> int.to_string(depth)
      let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
      #(
        "@gprelude.GList::from_array(("
          <> expr
          <> ").iter().map(fn("
          <> v
          <> ") { "
          <> inner_e
          <> " }).to_array()[:])",
        h1,
      )
    }

    OptionConv(inner) ->
      case inner {
        Direct -> #(expr, helpers)
        _ -> {
          let v = "x" <> int.to_string(depth)
          let #(inner_e, h1) = expr_from_mbt(inner, v, helpers, depth + 1)
          #("(" <> expr <> ").map(fn(" <> v <> ") { " <> inner_e <> " })", h1)
        }
      }

    ResultConv(Direct, Direct) -> #(expr, helpers)
    ResultConv(ok_c, err_c) -> {
      let ok_v = "ok_v" <> int.to_string(depth)
      let err_v = "err_v" <> int.to_string(depth)
      let #(ok_e, h1) = expr_from_mbt(ok_c, ok_v, helpers, depth + 1)
      let #(err_e, h2) = expr_from_mbt(err_c, err_v, h1, depth + 1)
      #(
        "match "
          <> expr
          <> " { Ok("
          <> ok_v
          <> ") => Ok("
          <> ok_e
          <> "); Err("
          <> err_v
          <> ") => Err("
          <> err_e
          <> ") }",
        h2,
      )
    }

    TupleConv(els) ->
      case list.all(els, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, binds_and_exprs) =
            list.index_map(els, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let v =
                "t" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(ce, next_h) = expr_from_mbt(pair.0, v, acc_h, depth + 1)
              #(next_h, #(v, ce))
            })
          let pat =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.0 })
              |> string.join(", ")
            }
            <> ")"
          let out =
            "("
            <> {
              list.map(binds_and_exprs, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          #("{ let " <> pat <> " = " <> expr <> "; " <> out <> " }", h1)
        }
      }

    FnConv(p_convs, r_conv) ->
      case r_conv == Direct && list.all(p_convs, fn(c) { c == Direct }) {
        True -> #(expr, helpers)
        False -> {
          let #(h1, params_and_args) =
            list.index_map(p_convs, fn(c, i) { #(c, i) })
            |> list.map_fold(helpers, fn(acc_h, pair) {
              let pname =
                "cb" <> int.to_string(depth) <> "_" <> int.to_string(pair.1)
              let #(arg_e, next_h) =
                expr_to_mbt(pair.0, pname, acc_h, depth + 1)
              #(next_h, #(pname, arg_e))
            })
          let raw_call =
            "("
            <> expr
            <> ")("
            <> {
              list.map(params_and_args, fn(p) { p.1 })
              |> string.join(", ")
            }
            <> ")"
          let #(ret_e, h2) = expr_from_mbt(r_conv, raw_call, h1, depth + 1)
          let pnames =
            list.map(params_and_args, fn(p) { p.0 })
            |> string.join(", ")
          #("fn(" <> pnames <> ") { " <> ret_e <> " }", h2)
        }
      }
  }
}

fn generate_const_items(
  bctx: BindContext,
  consts: List(MbtiConst),
  used_names: Set(String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let #(rev_items, rev_skipped, next_used) =
    list.fold(consts, #([], [], used_names), fn(acc, c) {
      let #(items, skipped, used) = acc
      case c.is_deprecated {
        True -> #(items, [#(c.name, "deprecated"), ..skipped], used)
        False ->
          case resolve_type(bctx, c.const_type, dict.new()) {
            Error(reason) -> #(items, [#(c.name, reason), ..skipped], used)
            Ok(spec) -> {
              let gleam_name =
                pick_unique_gleam_name(to_snake_case(c.name), used)
              let next_u = set.insert(used, gleam_name)
              let gleam_stub =
                "/// @external(moonbit, \""
                <> bctx.adapter_pkg_name
                <> "\", \""
                <> gleam_name
                <> "\")\n"
                <> "pub fn "
                <> gleam_name
                <> "() -> "
                <> spec.gleam_ty
                <> " {\n  panic as \"Implemented in MoonBit\"\n}"
              let #(ret_e, hk) =
                expr_from_mbt(
                  spec.conv,
                  "@" <> bctx.target_alias <> "." <> c.name,
                  set.new(),
                  0,
                )
              let adapter_fn =
                "///|\npub fn "
                <> mangle_moon_ident(gleam_name)
                <> "() -> "
                <> spec.adapter_ty
                <> " {\n  "
                <> ret_e
                <> "\n}"
              let item =
                EmittedFn(
                  gleam_stub:,
                  adapter_fn: Some(adapter_fn),
                  needs_option: spec.needs_option,
                  needs_gprelude: spec.needs_gprelude,
                  needs_float_pkg: spec.needs_float_pkg,
                  needs_int16_pkg: spec.needs_int16_pkg,
                  helper_kinds: hk,
                  ext_types: spec.used_external_types,
                  extra_imports: ext_types_to_extra_imports(
                    bctx,
                    spec.used_external_types,
                  ),
                )
              #([item, ..items], skipped, next_u)
            }
          }
      }
    })
  #(list.reverse(rev_items), list.reverse(rev_skipped), next_used)
}

fn generate_type_helper_items(
  bctx: BindContext,
  types: List(MbtiTypeDecl),
  used_names: Set(String),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let #(rev_items, rev_skipped, next_used) =
    list.fold(types, #([], [], used_names), fn(acc, td) {
      case td.is_deprecated {
        True -> acc
        False ->
          case td.kind {
            MbtiStruct(public_all:, fields:, tuple_fields: _) ->
              generate_struct_helpers(bctx, td, public_all, fields, acc)
            MbtiEnum(public_all: True, variants:) ->
              generate_enum_constructors(bctx, td, variants, acc)
            _ -> acc
          }
      }
    })
  #(list.reverse(rev_items), list.reverse(rev_skipped), next_used)
}

fn generate_struct_helpers(
  bctx: BindContext,
  td: MbtiTypeDecl,
  public_all: Bool,
  fields: List(mbti.MbtiField),
  acc: #(List(EmittedFn), List(#(String, String)), Set(String)),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let tp_map =
    list.fold(td.type_params, dict.new(), fn(m, tp) {
      dict.insert(m, tp, sanitize_gleam_type_var(tp))
    })
  let owner_ty =
    MbtiNamed(
      None,
      td.name,
      list.map(td.type_params, fn(tp) { MbtiNamed(None, tp, []) }),
    )
  let self_spec_res = resolve_type(bctx, owner_ty, tp_map)

  let acc_after_ctor = case public_all && fields != [], self_spec_res {
    True, Ok(self_spec) -> {
      let #(items, skipped, used) = acc
      let ctor_base = "make_" <> to_snake_case(td.name)
      let resolved_fields =
        list.try_map(fields, fn(fld) {
          use fspec <- result.try(resolve_type(bctx, fld.field_type, tp_map))
          Ok(#(fld, fspec))
        })
      case resolved_fields {
        Error(reason) -> #(items, [#(td.name, reason), ..skipped], used)
        Ok(r_fields) -> {
          let ctor_name = pick_unique_gleam_name(ctor_base, used)
          let next_u = set.insert(used, ctor_name)
          let generics = case td.type_params {
            [] -> ""
            tps -> "[" <> string.join(tps, ", ") <> "]"
          }
          let gleam_params =
            list.map(r_fields, fn(p) {
              escape_gleam_ident(to_snake_case({ p.0 }.name))
              <> ": "
              <> { p.1 }.gleam_ty
            })
            |> string.join(", ")
          let gleam_ignores =
            list.map(r_fields, fn(p) {
              "  let _ = " <> escape_gleam_ident(to_snake_case({ p.0 }.name))
            })
            |> string.join("\n")
          let gleam_stub =
            "/// @external(moonbit, \""
            <> bctx.adapter_pkg_name
            <> "\", \""
            <> ctor_name
            <> "\")\n"
            <> "pub fn "
            <> ctor_name
            <> "("
            <> gleam_params
            <> ") -> "
            <> self_spec.gleam_ty
            <> " {\n"
            <> gleam_ignores
            <> "\n  panic as \"Implemented in MoonBit\"\n}"

          let #(hk, mbt_field_inits) =
            list.map_fold(r_fields, set.new(), fn(acc_hk, p) {
              let fname = { p.0 }.name
              let safe = mangle_moon_ident(to_snake_case(fname))
              let #(val_e, next_hk) = expr_to_mbt({ p.1 }.conv, safe, acc_hk, 0)
              #(next_hk, fname <> ": " <> val_e)
            })
          let adapter_params =
            list.map(r_fields, fn(p) {
              mangle_moon_ident(to_snake_case({ p.0 }.name))
              <> " : "
              <> { p.1 }.adapter_ty
            })
            |> string.join(", ")
          let adapter_fn =
            "///|\npub fn"
            <> generics
            <> " "
            <> mangle_moon_ident(ctor_name)
            <> "("
            <> adapter_params
            <> ") -> "
            <> self_spec.adapter_ty
            <> " {\n  @"
            <> bctx.target_alias
            <> "."
            <> td.name
            <> "::{\n    "
            <> string.join(mbt_field_inits, ",\n    ")
            <> ",\n  }\n}"
          let item_ext_types =
            list.fold(r_fields, self_spec.used_external_types, fn(m, p) {
              dict.merge(m, { p.1 }.used_external_types)
            })
          let item =
            EmittedFn(
              gleam_stub:,
              adapter_fn: Some(adapter_fn),
              needs_option: self_spec.needs_option
                || list.any(r_fields, fn(p) { { p.1 }.needs_option }),
              needs_gprelude: self_spec.needs_gprelude
                || list.any(r_fields, fn(p) { { p.1 }.needs_gprelude }),
              needs_float_pkg: list.any(r_fields, fn(p) {
                { p.1 }.needs_float_pkg
              }),
              needs_int16_pkg: list.any(r_fields, fn(p) {
                { p.1 }.needs_int16_pkg
              }),
              helper_kinds: hk,
              ext_types: item_ext_types,
              extra_imports: ext_types_to_extra_imports(bctx, item_ext_types),
            )
          #([item, ..items], skipped, next_u)
        }
      }
    }
    _, _ -> acc
  }

  // Field getters for visible fields
  case self_spec_res {
    Error(_) -> acc_after_ctor
    Ok(self_spec) ->
      list.fold(fields, acc_after_ctor, fn(cur_acc, fld) {
        let #(items, skipped, used) = cur_acc
        case resolve_type(bctx, fld.field_type, tp_map) {
          Error(reason) -> #(
            items,
            [#(td.name <> "." <> fld.name, reason), ..skipped],
            used,
          )
          Ok(fspec) -> {
            let getter_base =
              to_snake_case(td.name) <> "_" <> to_snake_case(fld.name)
            let getter_name = pick_unique_gleam_name(getter_base, used)
            let next_u = set.insert(used, getter_name)
            let generics = case td.type_params {
              [] -> ""
              tps -> "[" <> string.join(tps, ", ") <> "]"
            }
            let gleam_stub =
              "/// @external(moonbit, \""
              <> bctx.adapter_pkg_name
              <> "\", \""
              <> getter_name
              <> "\")\n"
              <> "pub fn "
              <> getter_name
              <> "(self: "
              <> self_spec.gleam_ty
              <> ") -> "
              <> fspec.gleam_ty
              <> " {\n  let _ = self\n  panic as \"Implemented in MoonBit\"\n}"
            let #(ret_e, hk) =
              expr_from_mbt(fspec.conv, "self_." <> fld.name, set.new(), 0)
            let adapter_fn =
              "///|\npub fn"
              <> generics
              <> " "
              <> mangle_moon_ident(getter_name)
              <> "(self_ : "
              <> self_spec.adapter_ty
              <> ") -> "
              <> fspec.adapter_ty
              <> " {\n  "
              <> ret_e
              <> "\n}"
            let getter_ext =
              dict.merge(
                self_spec.used_external_types,
                fspec.used_external_types,
              )
            let item =
              EmittedFn(
                gleam_stub:,
                adapter_fn: Some(adapter_fn),
                needs_option: self_spec.needs_option || fspec.needs_option,
                needs_gprelude: self_spec.needs_gprelude || fspec.needs_gprelude,
                needs_float_pkg: fspec.needs_float_pkg,
                needs_int16_pkg: fspec.needs_int16_pkg,
                helper_kinds: hk,
                ext_types: getter_ext,
                extra_imports: ext_types_to_extra_imports(bctx, getter_ext),
              )
            #([item, ..items], skipped, next_u)
          }
        }
      })
  }
}

fn generate_enum_constructors(
  bctx: BindContext,
  td: MbtiTypeDecl,
  variants: List(mbti.MbtiVariant),
  acc: #(List(EmittedFn), List(#(String, String)), Set(String)),
) -> #(List(EmittedFn), List(#(String, String)), Set(String)) {
  let tp_map =
    list.fold(td.type_params, dict.new(), fn(m, tp) {
      dict.insert(m, tp, sanitize_gleam_type_var(tp))
    })
  let owner_ty =
    MbtiNamed(
      None,
      td.name,
      list.map(td.type_params, fn(tp) { MbtiNamed(None, tp, []) }),
    )
  case resolve_type(bctx, owner_ty, tp_map) {
    Error(_) -> acc
    Ok(self_spec) ->
      list.fold(variants, acc, fn(cur_acc, v) {
        let #(items, skipped, used) = cur_acc
        let resolved_params =
          list.try_map(v.params, fn(vp) {
            use spec <- result.try(resolve_type(bctx, vp.1, tp_map))
            Ok(#(vp.0, spec))
          })
        case resolved_params {
          Error(reason) -> #(
            items,
            [#(td.name <> "::" <> v.name, reason), ..skipped],
            used,
          )
          Ok(r_params) -> {
            let fn_base = to_snake_case(td.name) <> "_" <> to_snake_case(v.name)
            let fn_name = pick_unique_gleam_name(fn_base, used)
            let next_u = set.insert(used, fn_name)
            let generics = case td.type_params {
              [] -> ""
              tps -> "[" <> string.join(tps, ", ") <> "]"
            }
            let arg_names =
              list.index_map(r_params, fn(rp, i) {
                case rp.0 {
                  Some(lbl) -> escape_gleam_ident(to_snake_case(lbl))
                  None -> "arg" <> int.to_string(i)
                }
              })
            let gleam_sig =
              list.zip(arg_names, r_params)
              |> list.map(fn(p) { p.0 <> ": " <> p.1.1.gleam_ty })
              |> string.join(", ")
            let gleam_ignores = case arg_names {
              [] -> ""
              _ ->
                {
                  list.map(arg_names, fn(n) { "  let _ = " <> n })
                  |> string.join("\n")
                }
                <> "\n"
            }
            let gleam_stub =
              "/// @external(moonbit, \""
              <> bctx.adapter_pkg_name
              <> "\", \""
              <> fn_name
              <> "\")\n"
              <> "pub fn "
              <> fn_name
              <> "("
              <> gleam_sig
              <> ") -> "
              <> self_spec.gleam_ty
              <> " {\n"
              <> gleam_ignores
              <> "  panic as \"Implemented in MoonBit\"\n}"

            let #(hk, mbt_args) =
              list.zip(arg_names, r_params)
              |> list.map_fold(set.new(), fn(acc_hk, pair) {
                let #(aname, #(lbl_opt, spec)) = pair
                let m_aname = mangle_moon_ident(aname)
                let #(val_e, next_hk) =
                  expr_to_mbt(spec.conv, m_aname, acc_hk, 0)
                let arg_str = case lbl_opt {
                  Some(lbl) -> lbl <> "=" <> val_e
                  None -> val_e
                }
                #(next_hk, arg_str)
              })
            let adapter_params =
              list.zip(arg_names, r_params)
              |> list.map(fn(pair) {
                mangle_moon_ident(pair.0) <> " : " <> pair.1.1.adapter_ty
              })
              |> string.join(", ")
            let call_part = case mbt_args {
              [] -> "@" <> bctx.target_alias <> "." <> v.name
              _ ->
                "@"
                <> bctx.target_alias
                <> "."
                <> v.name
                <> "("
                <> string.join(mbt_args, ", ")
                <> ")"
            }
            let adapter_fn =
              "///|\npub fn"
              <> generics
              <> " "
              <> mangle_moon_ident(fn_name)
              <> "("
              <> adapter_params
              <> ") -> "
              <> self_spec.adapter_ty
              <> " {\n  "
              <> call_part
              <> "\n}"
            let enum_ext =
              list.fold(r_params, self_spec.used_external_types, fn(m, p) {
                dict.merge(m, { p.1 }.used_external_types)
              })
            let item =
              EmittedFn(
                gleam_stub:,
                adapter_fn: Some(adapter_fn),
                needs_option: self_spec.needs_option
                  || list.any(r_params, fn(p) { p.1.needs_option }),
                needs_gprelude: self_spec.needs_gprelude
                  || list.any(r_params, fn(p) { p.1.needs_gprelude }),
                needs_float_pkg: list.any(r_params, fn(p) {
                  p.1.needs_float_pkg
                }),
                needs_int16_pkg: list.any(r_params, fn(p) {
                  p.1.needs_int16_pkg
                }),
                helper_kinds: hk,
                ext_types: enum_ext,
                extra_imports: ext_types_to_extra_imports(bctx, enum_ext),
              )
            #([item, ..items], skipped, next_u)
          }
        }
      })
  }
}

fn build_external_type_decls(
  pkg: MbtiPackage,
  used_ext_types: Dict(String, ExternalTypeRef),
) -> List(String) {
  let type_param_names_by_name =
    list.fold(pkg.types, dict.new(), fn(acc, td) {
      dict.insert(acc, td.name, td.type_params)
    })

  used_ext_types
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let ext = entry.1
    let raw_params = case
      ext.pkg_path == pkg.package_name,
      dict.get(type_param_names_by_name, ext.mbt_name)
    {
      True, Ok(tps) if tps != [] -> list.map(tps, sanitize_gleam_type_var)
      _, _ -> int_range_names("t", ext.arity)
    }
    let tp_suffix = case raw_params {
      [] -> ""
      ps -> "(" <> string.join(ps, ", ") <> ")"
    }
    "/// @external_type(moonbit, \""
    <> ext.pkg_path
    <> "\", \""
    <> ext.mbt_name
    <> "\")\n"
    <> "pub type "
    <> ext.gleam_name
    <> tp_suffix
  })
}

fn emit_adapter_helpers(helper_kinds: Set(String)) -> List(String) {
  let checks = [
    #(
      "int32",
      "///|\nfn __to_int32(x : Int64) -> Int {\n  if x < -2147483648L || x > 2147483647L {\n    abort(\"Int64 out of Int32 range\")\n  }\n  x.to_int()\n}",
    ),
    #(
      "uint32",
      "///|\nfn __to_uint32(x : Int64) -> UInt {\n  if x < 0L || x > 4294967295L {\n    abort(\"Int64 out of UInt32 range\")\n  }\n  x.reinterpret_as_uint64().to_uint()\n}",
    ),
    #(
      "int16",
      "///|\nfn __to_int16(x : Int64) -> Int16 {\n  if x < -32768L || x > 32767L {\n    abort(\"Int64 out of Int16 range\")\n  }\n  @int16.Int16::from_int64(x)\n}",
    ),
    #(
      "uint16",
      "///|\nfn __to_uint16(x : Int64) -> UInt16 {\n  if x < 0L || x > 65535L {\n    abort(\"Int64 out of UInt16 range\")\n  }\n  x.to_uint16()\n}",
    ),
    #(
      "byte",
      "///|\nfn __to_byte(x : Int64) -> Byte {\n  if x < 0L || x > 255L {\n    abort(\"Int64 out of Byte range\")\n  }\n  x.to_byte()\n}",
    ),
    #(
      "char",
      "///|\nfn __to_char(s : String) -> Char {\n  match s.get_char(0) {\n    Some(c) => c\n    None => abort(\"Expected non-empty String for Char\")\n  }\n}",
    ),
  ]

  list.filter_map(checks, fn(entry) {
    case set.contains(helper_kinds, entry.0) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}

fn emit_adapter_moon_pkg(
  bctx: BindContext,
  needs_gprelude: Bool,
  needs_float: Bool,
  needs_int16: Bool,
  extra_imports: Dict(String, String),
) -> String {
  let base =
    dict.new()
    |> dict.insert(bctx.mbti.package_name, bctx.target_alias)
  let base = case needs_gprelude {
    True -> dict.insert(base, bctx.project_name <> "/gprelude", "gprelude")
    False -> base
  }
  let base = case needs_float {
    True -> dict.insert(base, "moonbitlang/core/float", "float")
    False -> base
  }
  let base = case needs_int16 {
    True -> dict.insert(base, "moonbitlang/core/int16", "int16")
    False -> base
  }
  let merged = dict.merge(extra_imports, base)
  let entries =
    dict.to_list(merged)
    |> list.sort(fn(a, b) { string.compare(a.1, b.1) })
    |> list.map(fn(p) { "  \"" <> p.0 <> "\" @" <> p.1 <> "," })
    |> string.join("\n")

  "import {\n" <> entries <> "\n}\n"
}

fn render_gleam_source(
  needs_option: Bool,
  ext_type_decls: List(String),
  fn_stubs: List(String),
  skipped: List(#(String, String)),
) -> String {
  let header = "// Generated by `gekko moonbit bind` - DO NOT EDIT."
  let imports = case needs_option {
    True -> ["import gleam/option.{type Option}"]
    False -> []
  }
  let skipped_block = case skipped {
    [] -> []
    _ -> [
      "// Skipped items:\n"
      <> {
        list.map(skipped, fn(s) { "// - " <> s.0 <> ": " <> s.1 })
        |> string.join("\n")
      },
    ]
  }
  let sections =
    list.flatten([[header], imports, ext_type_decls, fn_stubs, skipped_block])
    |> list.filter(fn(s) { s != "" })

  string.join(sections, "\n\n") <> "\n"
}

fn ext_types_to_extra_imports(
  bctx: BindContext,
  ext_types: Dict(String, ExternalTypeRef),
) -> Dict(String, String) {
  ext_types
  |> dict.values
  |> list.fold(dict.new(), fn(acc, ext) {
    case ext.pkg_path == bctx.mbti.package_name {
      True -> acc
      False -> dict.insert(acc, ext.pkg_path, pkg_to_moon_alias(ext.pkg_path))
    }
  })
}

fn format_fn_label(f: MbtiFnDecl) -> String {
  case f.owner_type {
    Some(o) -> o <> "::" <> f.name
    None -> f.name
  }
}

fn pkg_to_moon_alias(pkg_path: String) -> String {
  pkg_path
  |> string.replace("/", "_")
  |> string.replace("-", "_")
  |> string.replace(".", "_")
}

fn last_segment_snake(pkg_path: String) -> String {
  pkg_path
  |> string.split("/")
  |> list.last
  |> result.unwrap(pkg_path)
  |> to_snake_case
}

fn to_snake_case(raw: String) -> String {
  raw
  |> string.replace("-", "_")
  |> camel_to_snake_loop("", False)
}

fn camel_to_snake_loop(
  src: String,
  acc: String,
  prev_lower_or_digit: Bool,
) -> String {
  case string.pop_grapheme(src) {
    Error(_) -> acc
    Ok(#(g, rest)) -> {
      let lower = string.lowercase(g)
      let upper = string.uppercase(g)
      let is_upper = lower != upper && g == upper
      let is_lower_or_digit =
        { lower != upper && g == lower }
        || g == "0"
        || g == "1"
        || g == "2"
        || g == "3"
        || g == "4"
        || g == "5"
        || g == "6"
        || g == "7"
        || g == "8"
        || g == "9"
      let next_acc = case is_upper && prev_lower_or_digit {
        True -> acc <> "_" <> lower
        False -> acc <> lower
      }
      camel_to_snake_loop(rest, next_acc, is_lower_or_digit)
    }
  }
}

fn sanitize_gleam_type_var(tp: String) -> String {
  let base = to_snake_case(tp)
  let clean = case base {
    "" -> "a"
    _ -> base
  }
  escape_gleam_ident(clean)
}

fn escape_gleam_ident(name: String) -> String {
  case name {
    "as"
    | "assert"
    | "case"
    | "const"
    | "echo"
    | "else"
    | "fn"
    | "if"
    | "import"
    | "let"
    | "opaque"
    | "panic"
    | "pub"
    | "todo"
    | "type"
    | "use" -> name <> "_"
    _ -> name
  }
}

fn mangle_moon_ident(name: String) -> String {
  case name {
    "match"
    | "loop"
    | "for"
    | "while"
    | "break"
    | "continue"
    | "struct"
    | "enum"
    | "trait"
    | "impl"
    | "guard"
    | "async"
    | "test"
    | "init"
    | "main"
    | "pub"
    | "priv"
    | "fn"
    | "let"
    | "mut"
    | "const"
    | "type"
    | "import"
    | "as"
    | "is"
    | "in"
    | "if"
    | "else"
    | "return"
    | "throw"
    | "true"
    | "false"
    | "raise"
    | "try"
    | "catch"
    | "extern"
    | "self"
    | "use"
    | "var" -> name <> "_"
    _ -> name
  }
}

fn pick_unique_gleam_name(base: String, used: Set(String)) -> String {
  let clean = escape_gleam_ident(base)
  case set.contains(used, clean) {
    False -> clean
    True -> pick_unique_suffix(clean, 2, used)
  }
}

fn pick_unique_suffix(base: String, idx: Int, used: Set(String)) -> String {
  let candidate = base <> "_" <> int.to_string(idx)
  case set.contains(used, candidate) {
    False -> candidate
    True -> pick_unique_suffix(base, idx + 1, used)
  }
}

fn read_file_err(path: String) -> Result(String, String) {
  simplifile.read(from: path)
  |> result.map_error(fn(err) {
    "Failed to read " <> path <> ": " <> simplifile.describe_error(err)
  })
}

fn write_with_parents(path: String, contents: String) -> Result(Nil, String) {
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

fn int_range_names(prefix: String, count: Int) -> List(String) {
  int_range_loop(prefix, count - 1, [])
}

fn int_range_loop(prefix: String, idx: Int, acc: List(String)) -> List(String) {
  case idx < 0 {
    True -> acc
    False ->
      int_range_loop(prefix, idx - 1, [prefix <> int.to_string(idx), ..acc])
  }
}
