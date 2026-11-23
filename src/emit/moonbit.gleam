import emit/pkg_config
import emit/trait_bounds.{type ProjectTraitBounds}
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrBinOp, type IrCallArg, type IrClause, type IrConstant, type IrExpr,
  type IrFnParam, type IrFunction, type IrGetter, type IrModule, type IrParam,
  type IrPatArg, type IrPattern, type IrStmt, type IrType, type IrTypeAlias,
  type IrTypeDef, type IrVariant, type IrVariantField, AssertAbort, IrAbort,
  IrAddFloat, IrAddInt, IrAnd, IrBinOp, IrBitString, IrBlock, IrBool, IrBreak,
  IrCall, IrCallArg, IrConstructor, IrContinue, IrDivFloat, IrDivInt, IrEcho,
  IrEq, IrFloat, IrFn, IrForLoop, IrGetterCall, IrGtEqFloat, IrGtEqInt,
  IrGtFloat, IrGtInt, IrInt, IrList, IrLtEqFloat, IrLtEqInt, IrLtFloat, IrLtInt,
  IrMatch, IrModuleRef, IrMultFloat, IrMultInt, IrNegateBool, IrNegateInt,
  IrNotEq, IrOr, IrParam, IrPatArg, IrPatAs, IrPatBitString, IrPatBool,
  IrPatDiscard, IrPatFloat, IrPatInt, IrPatString, IrPatTuple, IrPatUnit,
  IrPatVar, IrPatVariant, IrRemInt, IrStmtAssert, IrStmtExpr, IrStmtGuard,
  IrStmtLet, IrString, IrStringConcat, IrSubFloat, IrSubInt, IrTuple,
  IrTupleIndex, IrTypeBitArray, IrTypeBool, IrTypeDouble, IrTypeFn, IrTypeInt64,
  IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple, IrTypeUnit,
  IrTypeVar, IrUnit, IrVar, LetAssertAbort, PanicAbort, TodoAbort,
}
import lower/mangle
import moonbit/ffi_meta.{type FfiMetadata}
import project/prepass.{type ExternalType, ExternalType, PackageCall, WasmImport}

type EmitCtx {
  EmitCtx(
    current_module: String,
    local_ctors: Dict(String, #(Int, List(Option(String)))),
    local_external_types: Dict(String, ExternalType),
    table: Option(SymbolTable),
    ffi_metadata: FfiMetadata,
    project_bounds: ProjectTraitBounds,
    pkg_to_alias: Dict(String, String),
    used_aliases: Set(String),
  )
}

/// Render a lowered `IrModule` into MoonBit source code and the list of
/// `#(pkg_or_dir, alias)` imports needed for its `moon.pkg`.
pub fn emit_module(module: IrModule) -> #(String, List(#(String, String))) {
  let meta = ffi_meta.base_metadata()
  let bounds = trait_bounds.analyze_project([module], None, meta)
  emit_module_inner(module, None, meta, bounds)
}

/// Render a lowered `IrModule` with full `SymbolTable` access (enabling
/// higher-order eta-expansion for imported constructors).
pub fn emit_module_with_table(
  module: IrModule,
  table: SymbolTable,
) -> #(String, List(#(String, String))) {
  let meta = ffi_meta.base_metadata()
  let bounds = trait_bounds.analyze_project([module], Some(table), meta)
  emit_module_inner(module, Some(table), meta, bounds)
}

/// Render a lowered `IrModule` with pre-scanned FFI metadata and whole-project
/// inferred trait bounds.
pub fn emit_module_with_context(
  module: IrModule,
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
  project_bounds: ProjectTraitBounds,
) -> #(String, List(#(String, String))) {
  emit_module_inner(module, table, ffi_metadata, project_bounds)
}

/// Return True if this root module defines a 0-argument `main()` entrypoint.
pub fn module_has_main(module: IrModule) -> Bool {
  module.module_name == module.package_name
  && list.any(module.functions, fn(f) {
    f.unmangled_name == "main" && f.params == []
  })
}

fn emit_module_inner(
  module: IrModule,
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
  project_bounds: ProjectTraitBounds,
) -> #(String, List(#(String, String))) {
  let local_ctors =
    list.fold(module.types, dict.new(), fn(acc, td) {
      let variant_count = list.length(td.variants)
      list.fold(td.variants, acc, fn(inner, v) {
        let labels = list.map(v.fields, fn(f) { f.label })
        dict.insert(inner, v.name, #(variant_count, labels))
      })
    })

  let local_external_types =
    list.fold(module.types, dict.new(), fn(acc, td) {
      case td.external_type {
        Some(ext) ->
          acc
          |> dict.insert(td.name, ext)
          |> dict.insert(td.unmangled_name, ext)
        None -> acc
      }
    })

  let ctx0 =
    EmitCtx(
      current_module: module.module_name,
      local_ctors:,
      local_external_types:,
      table:,
      ffi_metadata:,
      project_bounds:,
      pkg_to_alias: dict.new(),
      used_aliases: set.from_list(["gprelude"]),
    )

  let #(raw_type_blocks, ctx1) = map_acc(module.types, ctx0, emit_type_def)
  let type_blocks = list.filter(raw_type_blocks, fn(b) { b != "" })

  let visible_alias_names = collect_visible_alias_names(module)
  let visible_aliases =
    list.filter(module.type_aliases, fn(ta) {
      set.contains(visible_alias_names, ta.name)
    })
  let #(alias_blocks, ctx2) = map_acc(visible_aliases, ctx1, emit_type_alias)

  let #(getter_blocks, ctx3) = map_acc(module.getters, ctx2, emit_getter)

  let #(const_blocks, ctx4) = map_acc(module.constants, ctx3, emit_constant)

  let #(fn_blocks, ctx5) = map_acc(module.functions, ctx4, emit_function)

  let main_blocks = case module_has_main(module) {
    True -> ["///|\nfn main {\n  @prelude.ignore(main_())\n}"]
    False -> []
  }

  let all_blocks =
    list.flatten([
      type_blocks,
      alias_blocks,
      getter_blocks,
      const_blocks,
      fn_blocks,
      main_blocks,
    ])

  let source = case all_blocks {
    [] -> ""
    _ -> string.join(all_blocks, "\n\n") <> "\n"
  }

  let import_list =
    ctx5.pkg_to_alias
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.1, b.1) })

  #(source, import_list)
}

fn add_gprelude_import(ctx: EmitCtx) -> EmitCtx {
  EmitCtx(
    ..ctx,
    pkg_to_alias: dict.insert(ctx.pkg_to_alias, "gprelude", "gprelude"),
  )
}

fn add_module_import(
  ctx: EmitCtx,
  target_module: String,
  alias_opt: Option(String),
) -> #(String, EmitCtx) {
  case target_module {
    "gprelude" -> #("gprelude", add_gprelude_import(ctx))
    _ -> {
      let pkg_dir = pkg_config.module_to_pkg_dir(target_module)
      let full_fallback = mangle.module_to_alias(target_module)
      let preferred = case alias_opt {
        Some(a) -> safe_alias(a)
        None -> full_fallback
      }
      register_import(ctx, pkg_dir, preferred, full_fallback)
    }
  }
}

fn register_import(
  ctx: EmitCtx,
  pkg_key: String,
  preferred: String,
  fallback: String,
) -> #(String, EmitCtx) {
  case dict.get(ctx.pkg_to_alias, pkg_key) {
    Ok(existing) -> #(existing, ctx)
    Error(_) -> {
      let chosen = case set.contains(ctx.used_aliases, preferred) {
        False -> preferred
        True ->
          case set.contains(ctx.used_aliases, fallback) {
            False -> fallback
            True -> pick_unique_alias(fallback, 2, ctx.used_aliases)
          }
      }
      #(
        chosen,
        EmitCtx(
          ..ctx,
          pkg_to_alias: dict.insert(ctx.pkg_to_alias, pkg_key, chosen),
          used_aliases: set.insert(ctx.used_aliases, chosen),
        ),
      )
    }
  }
}

fn pick_unique_alias(base: String, idx: Int, used: Set(String)) -> String {
  let candidate = base <> "_" <> int.to_string(idx)
  case set.contains(used, candidate) {
    True -> pick_unique_alias(base, idx + 1, used)
    False -> candidate
  }
}

fn safe_alias(alias: String) -> String {
  case alias {
    "prelude" -> "mod_prelude"
    _ -> mangle.mangle_ident(alias)
  }
}

fn emit_type_def(td: IrTypeDef, ctx: EmitCtx) -> #(String, EmitCtx) {
  let generics = format_type_params(td.type_params)
  case td.external_type {
    Some(ExternalType(package:, type_name:)) -> {
      let vis = case td.publicity {
        glance.Public -> "pub "
        glance.Private -> "priv "
      }
      case package == "" || package == "builtin", type_name == td.name {
        True, True -> #("", ctx)
        _, _ -> {
          let #(target_str, ctx1) = case package {
            "" | "builtin" -> #(type_name <> generics, ctx)
            "gprelude" -> #(
              "@gprelude." <> type_name <> generics,
              add_gprelude_import(ctx),
            )
            _ -> {
              let default_alias = mangle.module_to_alias(package)
              let #(ffi_alias, ctx_imp) =
                register_import(ctx, package, default_alias, default_alias)
              #("@" <> ffi_alias <> "." <> type_name <> generics, ctx_imp)
            }
          }
          #(
            "///|\n"
              <> vis
              <> "type "
              <> td.name
              <> generics
              <> " = "
              <> target_str,
            ctx1,
          )
        }
      }
    }

    None -> {
      let vis = case td.publicity, td.opaque_ {
        glance.Public, False -> "pub(all) "
        glance.Public, True -> "pub "
        glance.Private, _ -> "priv "
      }
      let dict_key_params = case
        dict.get(ctx.project_bounds.type_eq_hash_params, #(
          ctx.current_module,
          td.name,
        ))
      {
        Ok(indices) ->
          list.index_fold(td.type_params, set.new(), fn(acc, tp, idx) {
            case set.contains(indices, idx) {
              True -> set.insert(acc, tp)
              False -> acc
            }
          })
        Error(_) -> set.new()
      }
      let needs_manual_dict_eq =
        td.derive_eq_debug_hash
        && td.type_params != []
        && !set.is_empty(dict_key_params)
      let derive_line = case td.derive_eq_debug_hash, needs_manual_dict_eq {
        True, False -> "#derive(Eq, Debug, Hash)\n"
        True, True -> "#derive(Debug, Hash)\n"
        False, _ -> ""
      }
      let #(variant_lines, ctx1) = map_acc(td.variants, ctx, emit_variant)
      let body = case variant_lines {
        [] -> "{}"
        lines -> "{\n" <> string.join(lines, "\n") <> "\n}"
      }
      let enum_decl =
        "///|\n"
        <> derive_line
        <> vis
        <> "enum "
        <> td.name
        <> generics
        <> " "
        <> body
      let eq_block = case needs_manual_dict_eq {
        True -> "\n\n" <> emit_type_eq_impl(td, dict_key_params)
        False -> ""
      }
      let #(inspect_impl, ctx2) = emit_type_inspect_impl(td, ctx1)
      #(enum_decl <> eq_block <> "\n\n" <> inspect_impl, ctx2)
    }
  }
}

type FieldInspectKind {
  Inspectable
  UninspectableFn
  UninspectableExternal
}

fn classify_inspect_kind(ty: IrType, ctx: EmitCtx) -> FieldInspectKind {
  case ty {
    IrTypeFn(_, _) -> UninspectableFn
    IrTypeList(inner) -> classify_inspect_kind(inner, ctx)
    IrTypeResult(ok_t, err_t) ->
      case classify_inspect_kind(ok_t, ctx) {
        Inspectable -> classify_inspect_kind(err_t, ctx)
        other -> other
      }
    IrTypeTuple(els) -> classify_list_inspect_kind(els, ctx)
    IrTypeNamed(module:, name:, args:, ..) ->
      case is_external_named_type(module, name, ctx) {
        True -> UninspectableExternal
        False -> classify_list_inspect_kind(args, ctx)
      }
    _ -> Inspectable
  }
}

fn classify_list_inspect_kind(
  types: List(IrType),
  ctx: EmitCtx,
) -> FieldInspectKind {
  case types {
    [] -> Inspectable
    [head, ..tail] ->
      case classify_inspect_kind(head, ctx) {
        Inspectable -> classify_list_inspect_kind(tail, ctx)
        other -> other
      }
  }
}

fn is_external_named_type(module: String, name: String, ctx: EmitCtx) -> Bool {
  case module {
    "gleam" -> False
    _ ->
      case lookup_external_type(module, name, ctx) {
        None -> False
        Some(ext) ->
          !ffi_meta.is_inspectable(ctx.ffi_metadata, ext.package, ext.type_name)
      }
  }
}

fn lookup_external_type(
  module: String,
  name: String,
  ctx: EmitCtx,
) -> Option(ExternalType) {
  let resolved_mod = case module {
    "" -> ctx.current_module
    m -> m
  }
  case resolved_mod == ctx.current_module {
    True ->
      case dict.get(ctx.local_external_types, name) {
        Ok(ext) -> Some(ext)
        Error(_) -> lookup_external_type_in_table(resolved_mod, name, ctx.table)
      }
    False -> lookup_external_type_in_table(resolved_mod, name, ctx.table)
  }
}

fn lookup_external_type_in_table(
  module: String,
  name: String,
  table: Option(SymbolTable),
) -> Option(ExternalType) {
  case table {
    None -> None
    Some(tbl) ->
      case dict.get(tbl.modules, module) {
        Error(_) -> None
        Ok(ms) ->
          case dict.get(ms.types, name) {
            Ok(ti) -> ti.external_type
            Error(_) ->
              dict.values(ms.types)
              |> list.find(fn(ti) { mangle.mangle_type_name(ti.name) == name })
              |> option.from_result
              |> option.then(fn(ti) { ti.external_type })
          }
      }
  }
}

fn emit_type_inspect_impl(td: IrTypeDef, ctx: EmitCtx) -> #(String, EmitCtx) {
  let ctx1 = add_gprelude_import(ctx)
  let impl_vis = case td.publicity {
    glance.Public -> "pub "
    glance.Private -> ""
  }
  let inspectable_vars =
    list.fold(td.variants, set.new(), fn(acc, v) {
      list.fold(v.fields, acc, fn(inner, f) {
        case classify_inspect_kind(f.field_type, ctx) {
          Inspectable -> collect_non_fn_type_vars(f.field_type, ctx, inner)
          _ -> inner
        }
      })
    })
  let impl_generics = case td.type_params {
    [] -> ""
    tps ->
      "["
      <> {
        list.map(tps, fn(tp) {
          case set.contains(inspectable_vars, tp) {
            True -> tp <> " : @gprelude.GleamInspect"
            False -> tp
          }
        })
        |> string.join(", ")
      }
      <> "]"
  }
  let self_ty = td.name <> format_type_params(td.type_params)
  let body = case td.variants {
    [] -> "  @prelude.ignore(self)\n  \"\""
    variants -> {
      let arms =
        list.map(variants, fn(v) {
          case v.fields {
            [] -> "    " <> v.name <> " => \"" <> v.name <> "\""
            fields -> {
              let #(pat_parts, expr_parts) =
                list.index_fold(fields, #([], []), fn(acc, f, idx) {
                  let #(pats, exprs) = acc
                  let inspect_kind = classify_inspect_kind(f.field_type, ctx)
                  let bind_name = case inspect_kind {
                    Inspectable -> "f" <> int.to_string(idx)
                    _ -> "_"
                  }
                  let pat_part = case f.label {
                    Some(lbl) -> lbl <> "=" <> bind_name
                    None -> bind_name
                  }
                  let expr_part = case inspect_kind {
                    Inspectable ->
                      "@gprelude.GleamInspect::gleam_inspect("
                      <> bind_name
                      <> ")"
                    UninspectableFn -> "\"\\\"//fn(...) { ... }\\\"\""
                    UninspectableExternal -> "\"\\\"//external\\\"\""
                  }
                  #([pat_part, ..pats], [expr_part, ..exprs])
                })
              let pat_str =
                list.reverse(pat_parts)
                |> string.join(", ")
              let joined_fields =
                list.reverse(expr_parts)
                |> string.join(" + \", \" + ")
              "    "
              <> v.name
              <> "("
              <> pat_str
              <> ") => \""
              <> v.name
              <> "(\" + "
              <> joined_fields
              <> " + \")\""
            }
          }
        })
        |> string.join("\n")
      "  match self {\n" <> arms <> "\n  }"
    }
  }
  let code =
    "///|\n"
    <> impl_vis
    <> "impl"
    <> impl_generics
    <> " @gprelude.GleamInspect for "
    <> self_ty
    <> " with gleam_inspect(self) {\n"
    <> body
    <> "\n}"
  #(code, ctx1)
}

fn collect_non_fn_type_vars(
  ty: IrType,
  ctx: EmitCtx,
  acc: Set(String),
) -> Set(String) {
  case classify_inspect_kind(ty, ctx) {
    UninspectableFn | UninspectableExternal -> acc
    Inspectable ->
      case ty {
        IrTypeVar(v) -> set.insert(acc, v)
        IrTypeList(inner) -> collect_non_fn_type_vars(inner, ctx, acc)
        IrTypeResult(ok_t, err_t) ->
          collect_non_fn_type_vars(
            err_t,
            ctx,
            collect_non_fn_type_vars(ok_t, ctx, acc),
          )
        IrTypeTuple(els) ->
          list.fold(els, acc, fn(s, e) { collect_non_fn_type_vars(e, ctx, s) })
        IrTypeNamed(args:, ..) ->
          list.fold(args, acc, fn(s, a) { collect_non_fn_type_vars(a, ctx, s) })
        _ -> acc
      }
  }
}

fn emit_variant(v: IrVariant, ctx: EmitCtx) -> #(String, EmitCtx) {
  case v.fields {
    [] -> #("  " <> v.name, ctx)
    fields -> {
      let #(field_strs, ctx1) = map_acc(fields, ctx, emit_variant_field)
      #("  " <> v.name <> "(" <> string.join(field_strs, ", ") <> ")", ctx1)
    }
  }
}

fn emit_variant_field(f: IrVariantField, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(ty_str, ctx1) = emit_type(f.field_type, ctx)
  let s = case f.label {
    Some(lbl) -> lbl <> "~ : " <> ty_str
    None -> ty_str
  }
  #(s, ctx1)
}

fn emit_type_alias(ta: IrTypeAlias, ctx: EmitCtx) -> #(String, EmitCtx) {
  let vis = case ta.publicity {
    glance.Public -> "pub "
    glance.Private -> "priv "
  }
  let generics = format_type_params(ta.type_params)
  let #(aliased_str, ctx1) = emit_type(ta.aliased, ctx)
  #(
    "///|\n" <> vis <> "type " <> ta.name <> generics <> " = " <> aliased_str,
    ctx1,
  )
}

fn emit_getter(g: IrGetter, ctx: EmitCtx) -> #(String, EmitCtx) {
  let vis = case g.publicity {
    glance.Public -> "pub "
    glance.Private -> ""
  }
  let generics = format_type_params(g.type_params)
  let self_ty = g.type_name <> generics
  let #(ret_str, ctx1) = emit_type(g.return_type, ctx)
  let arms =
    list.map(g.variants, fn(v) {
      let #(v_name, positional) = v
      let placeholders = list.repeat("_", positional)
      let pat_args =
        list.append(placeholders, [g.field_name <> "~", ".."])
        |> string.join(", ")
      "    " <> v_name <> "(" <> pat_args <> ") => " <> g.field_name
    })
    |> string.join("\n")
  let code =
    "///|\n"
    <> vis
    <> "fn"
    <> generics
    <> " "
    <> g.type_name
    <> "::"
    <> g.field_name
    <> "(self : "
    <> self_ty
    <> ") -> "
    <> ret_str
    <> " {\n"
    <> "  match self {\n"
    <> arms
    <> "\n  }\n}"
  #(code, ctx1)
}

fn emit_constant(c: IrConstant, ctx: EmitCtx) -> #(String, EmitCtx) {
  let vis = case c.publicity {
    glance.Public -> "pub "
    glance.Private -> ""
  }
  let concrete_ty = instantiate_type_vars_to_unit(c.value_type)
  let #(ty_str, ctx1) = emit_type(concrete_ty, ctx)
  let #(val_str, ctx2) = emit_expr(c.value, ctx1)
  #(
    "///|\n" <> vis <> "let " <> c.name <> " : " <> ty_str <> " = " <> val_str,
    ctx2,
  )
}

fn instantiate_type_vars_to_unit(ty: IrType) -> IrType {
  case ty {
    IrTypeVar(_) -> IrTypeUnit
    IrTypeList(inner) -> IrTypeList(instantiate_type_vars_to_unit(inner))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        instantiate_type_vars_to_unit(ok_t),
        instantiate_type_vars_to_unit(err_t),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(list.map(els, instantiate_type_vars_to_unit))
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, instantiate_type_vars_to_unit),
        instantiate_type_vars_to_unit(r),
      )
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, instantiate_type_vars_to_unit))
    _ -> ty
  }
}

fn emit_function(f: IrFunction, ctx: EmitCtx) -> #(String, EmitCtx) {
  let f = case f.ffi {
    Some(_) -> {
      let named_params =
        list.index_map(f.params, fn(p, idx) {
          case p.name {
            "_" -> IrParam(..p, name: "__arg_" <> int.to_string(idx))
            _ -> p
          }
        })
      ir.IrFunction(..f, params: named_params)
    }
    None -> f
  }
  let vis = case f.publicity {
    glance.Public -> "pub "
    glance.Private -> ""
  }
  let #(generics, ctx0) = format_function_type_params(f, ctx)
  let #(param_strs, ctx1) = map_acc(f.params, ctx0, emit_fn_param)
  let #(ret_str, ctx2) = emit_type(f.return_type, ctx1)

  let header =
    vis
    <> "fn"
    <> generics
    <> " "
    <> f.name
    <> "("
    <> string.join(param_strs, ", ")
    <> ") -> "
    <> ret_str

  let #(fn_block, ctx3) = case f.ffi {
    Some(PackageCall(pkg, target_fn)) -> {
      let #(ffi_alias, ctx_imp) = case pkg {
        "gprelude" -> #("gprelude", add_gprelude_import(ctx2))
        _ -> {
          let default_alias = mangle.module_to_alias(pkg)
          register_import(ctx2, pkg, default_alias, default_alias)
        }
      }
      let call_args =
        list.map(f.params, fn(p) { p.name })
        |> string.join(", ")
      let body =
        "  @" <> ffi_alias <> "." <> target_fn <> "(" <> call_args <> ")"
      #("///|\n" <> header <> " {\n" <> body <> "\n}", ctx_imp)
    }

    Some(WasmImport(wasm_mod, imp_name)) -> {
      let stub_name = "__ffi_" <> f.name
      let #(stub_param_types, ctx_stub) =
        map_acc(f.params, ctx2, fn(p, c) { emit_type(p.param_type, c) })
      let stub_decl =
        "///|\nfn "
        <> stub_name
        <> "("
        <> string.join(stub_param_types, ", ")
        <> ") -> "
        <> ret_str
        <> " = \""
        <> wasm_mod
        <> "\" \""
        <> imp_name
        <> "\""
      let call_args =
        list.map(f.params, fn(p) { p.name })
        |> string.join(", ")
      let wrapper =
        "///|\n"
        <> header
        <> " {\n  "
        <> stub_name
        <> "("
        <> call_args
        <> ")\n}"
      #(stub_decl <> "\n\n" <> wrapper, ctx_stub)
    }

    None -> {
      let #(body_lines, ctx_body) = emit_stmts(f.body, "  ", ctx2)
      let body_str = case body_lines {
        [] -> "  ()"
        lines -> string.join(lines, "\n")
      }
      #("///|\n" <> header <> " {\n" <> body_str <> "\n}", ctx_body)
    }
  }

  let test_suffix = case
    f.params == [] && string.ends_with(f.unmangled_name, "_test")
  {
    True ->
      "\n\n///|\ntest \""
      <> escape_plain_string(f.unmangled_name)
      <> "\" {\n  @prelude.ignore("
      <> f.name
      <> "())\n}"
    False -> ""
  }

  #(fn_block <> test_suffix, ctx3)
}

fn emit_fn_param(p: IrParam, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(ty_str, ctx1) = emit_type(p.param_type, ctx)
  #(p.name <> " : " <> ty_str, ctx1)
}

fn emit_stmts(
  stmts: List(IrStmt),
  indent: String,
  ctx: EmitCtx,
) -> #(List(String), EmitCtx) {
  emit_stmts_loop(stmts, indent, ctx, [])
}

fn emit_stmts_loop(
  stmts: List(IrStmt),
  indent: String,
  ctx: EmitCtx,
  rev_acc: List(String),
) -> #(List(String), EmitCtx) {
  case stmts {
    [] -> #(list.reverse(rev_acc), ctx)
    [last] -> {
      let #(line, next_ctx) = emit_stmt(last, indent, True, ctx)
      #(list.reverse([line, ..rev_acc]), next_ctx)
    }
    [head, ..tail] -> {
      let #(line, next_ctx) = emit_stmt(head, indent, False, ctx)
      emit_stmts_loop(tail, indent, next_ctx, [line, ..rev_acc])
    }
  }
}

fn emit_stmt(
  stmt: IrStmt,
  indent: String,
  is_last: Bool,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case stmt {
    IrStmtLet(pattern:, annotation:, value:) -> {
      let #(val_str, ctx1) = emit_expr(value, ctx)
      let #(pat_str, ctx2) = emit_pattern(pattern, ctx1)
      let #(ann_str, ctx3) = case annotation {
        Some(ann) -> {
          let #(t_str, c) = emit_type(ann, ctx2)
          #(" : " <> t_str, c)
        }
        None -> #("", ctx2)
      }
      case is_last {
        False ->
          case pattern_is_irrefutable(pattern) {
            True -> #(
              indent <> "let " <> pat_str <> ann_str <> " = " <> val_str,
              ctx3,
            )
            False -> #(
              indent
                <> "guard "
                <> paren_if_compound(value, val_str)
                <> " is "
                <> pat_str
                <> " else { @prelude.abort(\"let pattern match failed\") }",
              ctx3,
            )
          }
        True ->
          case pattern_is_irrefutable(pattern), pattern {
            True, IrPatVar(v) -> #(
              indent
                <> "let "
                <> v
                <> ann_str
                <> " = "
                <> val_str
                <> "\n"
                <> indent
                <> v,
              ctx3,
            )
            True, IrPatDiscard | True, IrPatUnit -> #(indent <> val_str, ctx3)
            True, _ -> #(
              indent
                <> "let __gekko_let_val"
                <> ann_str
                <> " = "
                <> val_str
                <> "\n"
                <> indent
                <> "let "
                <> pat_str
                <> " = __gekko_let_val\n"
                <> indent
                <> "__gekko_let_val",
              ctx3,
            )
            False, _ -> #(
              indent
                <> "let __gekko_let_val"
                <> ann_str
                <> " = "
                <> val_str
                <> "\n"
                <> indent
                <> "guard __gekko_let_val is "
                <> pat_str
                <> " else { @prelude.abort(\"let pattern match failed\") }\n"
                <> indent
                <> "__gekko_let_val",
              ctx3,
            )
          }
      }
    }

    IrStmtGuard(
      value:,
      pattern:,
      guard_condition:,
      abort_message:,
      post_bindings:,
    ) -> {
      let #(val_str, ctx1) = emit_expr(value, ctx)
      let #(msg_str, ctx2) = case abort_message {
        Some(m) -> emit_expr(m, ctx1)
        None -> #("\"let assert failed\"", ctx1)
      }
      let #(guard_line, ret_expr_opt, ctx3) = case
        is_last,
        pattern,
        guard_condition
      {
        _, IrPatVar(v), Some(cond) -> {
          let #(cond_str, c) = emit_expr_indented(cond, indent, ctx2)
          let line =
            indent
            <> "let "
            <> v
            <> " = "
            <> val_str
            <> "\n"
            <> indent
            <> "guard "
            <> paren_if_match(cond, cond_str)
            <> " else { @prelude.abort("
            <> msg_str
            <> ") }"
          #(line, Some(v), c)
        }
        _, IrPatVar(v), None -> #(
          indent <> "let " <> v <> " = " <> val_str,
          Some(v),
          ctx2,
        )
        False, IrPatDiscard, None -> #(
          indent <> "@prelude.ignore(" <> val_str <> ")",
          None,
          ctx2,
        )
        True, IrPatDiscard, None ->
          case post_bindings {
            [] -> #(indent <> val_str, None, ctx2)
            _ -> #(
              indent <> "let __gekko_assert_val = " <> val_str,
              Some("__gekko_assert_val"),
              ctx2,
            )
          }
        _, _, _ -> {
          let #(pat_str, c1) = emit_pattern(pattern, ctx2)
          let #(cond_suffix, c2) = case guard_condition {
            Some(cond) -> {
              let #(cond_str, c) = emit_expr_indented(cond, indent, c1)
              #(" && " <> paren_if_compound(cond, cond_str), c)
            }
            None -> #("", c1)
          }
          case is_last {
            False -> #(
              indent
                <> "guard "
                <> paren_if_compound(value, val_str)
                <> " is "
                <> pat_str
                <> cond_suffix
                <> " else { @prelude.abort("
                <> msg_str
                <> ") }",
              None,
              c2,
            )
            True -> #(
              indent
                <> "let __gekko_assert_val = "
                <> val_str
                <> "\n"
                <> indent
                <> "guard __gekko_assert_val is "
                <> pat_str
                <> cond_suffix
                <> " else { @prelude.abort("
                <> msg_str
                <> ") }",
              Some("__gekko_assert_val"),
              c2,
            )
          }
        }
      }

      let #(binding_lines, ctx4) =
        map_acc(post_bindings, ctx3, fn(binding, c) {
          let #(name, expr) = binding
          let #(expr_str, c_next) = emit_expr(expr, c)
          #(indent <> "let " <> name <> " = " <> expr_str, c_next)
        })

      let with_bindings = [guard_line, ..binding_lines]
      let all = case is_last, ret_expr_opt {
        True, Some(ret_name) -> list.append(with_bindings, [indent <> ret_name])
        _, _ -> with_bindings
      }
      #(string.join(all, "\n"), ctx4)
    }

    IrStmtAssert(condition:, abort_message:) -> {
      let #(cond_str, ctx1) = emit_expr(condition, ctx)
      let #(msg_str, ctx2) = case abort_message {
        Some(m) -> emit_expr(m, ctx1)
        None -> #("\"assertion failed\"", ctx1)
      }
      #(
        indent
          <> "if !("
          <> cond_str
          <> ") {\n"
          <> indent
          <> "  @prelude.abort("
          <> msg_str
          <> ")\n"
          <> indent
          <> "}",
        ctx2,
      )
    }

    IrStmtExpr(expr) -> {
      let #(expr_str, ctx1) = emit_expr_indented(expr, indent, ctx)
      case is_last || stmt_expr_is_control_flow(expr) {
        True -> #(indent <> expr_str, ctx1)
        False -> #(indent <> "@prelude.ignore(" <> expr_str <> ")", ctx1)
      }
    }
  }
}

fn stmt_expr_is_control_flow(expr: IrExpr) -> Bool {
  case expr {
    IrBreak(_) | IrContinue(_) | IrAbort(_, _) -> True
    _ -> False
  }
}

fn emit_expr(expr: IrExpr, ctx: EmitCtx) -> #(String, EmitCtx) {
  emit_expr_indented(expr, "", ctx)
}

fn emit_expr_indented(
  expr: IrExpr,
  indent: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case expr {
    IrInt(val) -> #(val <> "L", ctx)
    IrFloat(val) -> #(val, ctx)
    IrString(val) -> #("\"" <> escape_string_literal(val) <> "\"", ctx)
    IrBool(True) -> #("true", ctx)
    IrBool(False) -> #("false", ctx)
    IrUnit -> #("()", ctx)
    IrVar(name) -> #(name, ctx)

    IrModuleRef(module_alias:, target_module:, symbol:) -> {
      let #(alias, ctx1) = add_module_import(ctx, target_module, module_alias)
      #("@" <> alias <> "." <> symbol, ctx1)
    }

    IrConstructor(module_alias:, target_module:, name:) ->
      emit_constructor_value(module_alias, target_module, name, ctx)

    IrTuple(elements) ->
      case elements {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_expr(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1(" <> el_str <> ")", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(elements, ctx, emit_expr)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }

    IrTupleIndex(tuple:, index:) -> {
      let #(tuple_str, ctx1) = emit_expr(tuple, ctx)
      #(wrap_if_compound(tuple, tuple_str) <> "." <> int.to_string(index), ctx1)
    }

    IrList(elements:, tail:) -> emit_list_expr(elements, tail, ctx)

    IrBitString(segments:) -> emit_bit_string_expr(segments, ctx)

    IrNegateInt(inner) -> {
      let #(inner_str, ctx1) = emit_expr(inner, ctx)
      #("-(" <> inner_str <> ")", ctx1)
    }

    IrNegateBool(inner) -> {
      let #(inner_str, ctx1) = emit_expr(inner, ctx)
      #("!(" <> inner_str <> ")", ctx1)
    }

    IrBinOp(op:, left:, right:) -> emit_bin_op_expr(op, left, right, ctx)

    IrCall(function:, args:) -> emit_call_expr(function, args, ctx)

    IrGetterCall(receiver:, field:) -> {
      let #(recv_str, ctx1) = emit_expr(receiver, ctx)
      #(wrap_if_compound(receiver, recv_str) <> "." <> field <> "()", ctx1)
    }

    IrBlock(stmts) ->
      case stmts {
        [] -> #("()", ctx)
        _ -> {
          let inner_indent = indent <> "  "
          let #(lines, ctx1) = emit_stmts(stmts, inner_indent, ctx)
          #("{\n" <> string.join(lines, "\n") <> "\n" <> indent <> "}", ctx1)
        }
      }

    IrFn(params:, return_type:, body:) -> {
      let inferred_param_types = infer_fn_param_types(params, body)
      let #(param_strs, ctx1) =
        map_acc(params, ctx, fn(p, c) {
          let effective_ty = case p.param_type {
            Some(pt) -> Some(pt)
            None -> dict.get(inferred_param_types, p.name) |> option.from_result
          }
          case effective_ty {
            Some(pt) -> {
              let #(t_str, c_next) = emit_type(pt, c)
              #(p.name <> " : " <> t_str, c_next)
            }
            None -> #(p.name, c)
          }
        })
      let #(ret_ann, ctx2) = case return_type {
        Some(rt) -> {
          let #(t_str, c_next) = emit_type(rt, ctx1)
          #(" -> " <> t_str, c_next)
        }
        None -> #("", ctx1)
      }
      let inner_indent = indent <> "  "
      let #(body_lines, ctx3) = emit_stmts(body, inner_indent, ctx2)
      let body_str = case body_lines {
        [] -> inner_indent <> "()"
        lines -> string.join(lines, "\n")
      }
      #(
        "fn("
          <> string.join(param_strs, ", ")
          <> ")"
          <> ret_ann
          <> " {\n"
          <> body_str
          <> "\n"
          <> indent
          <> "}",
        ctx3,
      )
    }

    IrMatch(subjects:, clauses:) ->
      emit_match_expr(subjects, clauses, indent, ctx)

    IrForLoop(bindings:, body:) -> {
      let #(binding_strs, ctx1) =
        map_acc(bindings, ctx, fn(b, c) {
          let #(name, init_expr) = b
          let #(init_str, c_next) = emit_expr(init_expr, c)
          #(name <> " = " <> init_str, c_next)
        })
      let header = case binding_strs {
        [] -> "for ;; {"
        bs -> "for " <> string.join(bs, ", ") <> " {"
      }
      let inner_indent = indent <> "  "
      let #(body_lines, ctx2) = emit_stmts(body, inner_indent, ctx1)
      #(
        header <> "\n" <> string.join(body_lines, "\n") <> "\n" <> indent <> "}",
        ctx2,
      )
    }

    IrContinue(args) ->
      case args {
        [] -> #("continue", ctx)
        _ -> {
          let #(arg_strs, ctx1) = map_acc(args, ctx, emit_expr)
          #("continue " <> string.join(arg_strs, ", "), ctx1)
        }
      }

    IrBreak(val) -> {
      let #(val_str, ctx1) = emit_expr(val, ctx)
      #("break " <> val_str, ctx1)
    }

    IrAbort(kind:, message:) -> {
      let default_msg = case kind {
        LetAssertAbort -> "\"let assert failed\""
        AssertAbort -> "\"assertion failed\""
        PanicAbort -> "\"panic\""
        TodoAbort -> "\"not yet implemented\""
      }
      let #(msg_str, ctx1) = case message {
        Some(m) -> emit_expr(m, ctx)
        None -> #(default_msg, ctx)
      }
      #("@prelude.abort(" <> msg_str <> ")", ctx1)
    }

    IrEcho(expr: inner, message:, file_path:, line:) -> {
      let ctx1 = add_gprelude_import(ctx)
      let #(inner_str, ctx2) = emit_expr(inner, ctx1)
      let #(msg_str, ctx3) = case message {
        Some(m) -> emit_expr(m, ctx2)
        None -> #("\"\"", ctx2)
      }
      let loc_str =
        "\""
        <> escape_plain_string(file_path)
        <> ":"
        <> int.to_string(line)
        <> "\""
      #(
        "@gprelude.echo_val("
          <> inner_str
          <> ", "
          <> loc_str
          <> ", "
          <> msg_str
          <> ")",
        ctx3,
      )
    }
  }
}

fn emit_constructor_prefix(
  module_alias: Option(String),
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case target_module {
    Some(tm) ->
      case is_builtin_external_ctor(tm, ctor_name, ctx) {
        True -> #("", ctx)
        False ->
          case tm != ctx.current_module {
            True -> {
              let #(alias, ctx1) = add_module_import(ctx, tm, module_alias)
              #("@" <> alias <> ".", ctx1)
            }
            False ->
              case module_alias {
                Some("gprelude") -> #("@gprelude.", add_gprelude_import(ctx))
                _ -> #("", ctx)
              }
          }
      }
    None ->
      case module_alias {
        Some("gprelude") -> #("@gprelude.", add_gprelude_import(ctx))
        _ -> #("", ctx)
      }
  }
}

fn is_builtin_external_ctor(
  target_module: String,
  ctor_name: String,
  ctx: EmitCtx,
) -> Bool {
  case ctx.table {
    None -> False
    Some(tbl) ->
      case dict.get(tbl.modules, target_module) {
        Error(_) -> False
        Ok(ms) ->
          case dict.get(ms.constructors, ctor_name) {
            Error(_) -> False
            Ok(ctor) ->
              case dict.get(ms.types, ctor.type_name) {
                Ok(ti) ->
                  case ti.external_type {
                    Some(ExternalType(package: pkg, ..)) ->
                      pkg == "" || pkg == "builtin"
                    _ -> False
                  }
                Error(_) -> False
              }
          }
      }
  }
}

fn emit_constructor_value(
  module_alias: Option(String),
  target_module: Option(String),
  name: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(prefix, ctx1) =
    emit_constructor_prefix(module_alias, target_module, name, ctx)
  let qualified = prefix <> name
  // MoonBit forbids using multi-arg constructors directly as first-class function values
  let field_labels = lookup_ctor_field_labels(target_module, name, ctx1)
  case field_labels {
    Some([]) -> #(qualified, ctx1)
    Some(labels) -> {
      let params =
        list.index_map(labels, fn(_, idx) { "__c_" <> int.to_string(idx) })
      let call_args =
        list.index_map(labels, fn(lbl_opt, idx) {
          let arg_var = "__c_" <> int.to_string(idx)
          case lbl_opt {
            Some(lbl) -> mangle.mangle_ident(lbl) <> "=" <> arg_var
            None -> arg_var
          }
        })
      #(
        "fn("
          <> string.join(params, ", ")
          <> ") { "
          <> qualified
          <> "("
          <> string.join(call_args, ", ")
          <> ") }",
        ctx1,
      )
    }
    None ->
      case name {
        "Ok" | "Err" | "Some" -> #(
          "fn(__c_0) { " <> qualified <> "(__c_0) }",
          ctx1,
        )
        _ -> #(qualified, ctx1)
      }
  }
}

fn lookup_ctor_info(
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> Option(#(Int, List(Option(String)))) {
  case target_module, ctx.table {
    Some(tm), Some(tbl) ->
      case dict.get(tbl.modules, tm) {
        Ok(ms) ->
          case dict.get(ms.constructors, ctor_name) {
            Ok(ctor) -> {
              let variant_count = case dict.get(ms.types, ctor.type_name) {
                Ok(ti) -> list.length(ti.variants)
                Error(_) -> 1
              }
              Some(#(variant_count, list.map(ctor.fields, fn(f) { f.label })))
            }
            Error(_) -> None
          }
        Error(_) -> None
      }
    None, _ ->
      case dict.get(ctx.local_ctors, ctor_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Some(tm), None if tm == ctx.current_module ->
      case dict.get(ctx.local_ctors, ctor_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    _, _ -> None
  }
}

fn lookup_ctor_field_labels(
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> Option(List(Option(String))) {
  option.map(lookup_ctor_info(target_module, ctor_name, ctx), fn(p) { p.1 })
}

fn emit_call_expr(
  function: IrExpr,
  args: List(IrCallArg),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case function {
    IrConstructor(module_alias:, target_module:, name:) -> {
      let normalized_args = case
        lookup_ctor_field_labels(target_module, name, ctx)
      {
        Some(field_labels) -> align_call_args(args, field_labels, True)
        None -> args
      }
      let #(arg_strs, ctx1) = map_acc(normalized_args, ctx, emit_call_arg)
      let args_joined = string.join(arg_strs, ", ")
      let #(prefix, ctx2) =
        emit_constructor_prefix(module_alias, target_module, name, ctx1)
      case normalized_args {
        [] -> #(prefix <> name, ctx2)
        _ -> #(prefix <> name <> "(" <> args_joined <> ")", ctx2)
      }
    }

    IrModuleRef(module_alias:, target_module:, symbol:) -> {
      let callee_info = lookup_callee_with_bounds(target_module, symbol, ctx)
      let ordered_args = case
        lookup_fn_param_labels(Some(target_module), symbol, ctx)
      {
        Some(param_labels) -> align_call_args(args, param_labels, False)
        None -> args
      }
      let #(arg_strs, ctx1) =
        map_index_acc(ordered_args, ctx, fn(a, idx, c) {
          emit_call_arg_with_inspect_check(a.value, idx, callee_info, c)
        })
      let args_joined = string.join(arg_strs, ", ")
      let #(alias, ctx2) = add_module_import(ctx1, target_module, module_alias)
      #("@" <> alias <> "." <> symbol <> "(" <> args_joined <> ")", ctx2)
    }

    IrVar(fn_name) -> {
      let callee_info =
        lookup_callee_with_bounds(ctx.current_module, fn_name, ctx)
      let ordered_args = case lookup_fn_param_labels(None, fn_name, ctx) {
        Some(param_labels) -> align_call_args(args, param_labels, False)
        None -> args
      }
      let #(arg_strs, ctx1) =
        map_index_acc(ordered_args, ctx, fn(a, idx, c) {
          emit_call_arg_with_inspect_check(a.value, idx, callee_info, c)
        })
      let args_joined = string.join(arg_strs, ", ")
      #(fn_name <> "(" <> args_joined <> ")", ctx1)
    }

    _ -> {
      let #(arg_strs, ctx1) =
        map_acc(args, ctx, fn(a, c) { emit_expr(a.value, c) })
      let args_joined = string.join(arg_strs, ", ")
      let #(fn_str, ctx2) = emit_expr(function, ctx1)
      #(wrap_if_compound(function, fn_str) <> "(" <> args_joined <> ")", ctx2)
    }
  }
}

fn lookup_callee_with_bounds(
  target_module: String,
  fn_name: String,
  ctx: EmitCtx,
) -> Option(#(IrFunction, trait_bounds.FnTraitBounds)) {
  case dict.get(ctx.project_bounds.all_fns, #(target_module, fn_name)) {
    Ok(callee_fn) -> {
      let callee_bounds =
        trait_bounds.lookup_fn_bounds(
          ctx.project_bounds,
          target_module,
          fn_name,
        )
      Some(#(callee_fn, callee_bounds))
    }
    Error(_) -> None
  }
}

fn emit_call_arg_with_inspect_check(
  val: IrExpr,
  idx: Int,
  callee_info: Option(#(IrFunction, trait_bounds.FnTraitBounds)),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case callee_info {
    Some(#(callee_fn, callee_bounds)) ->
      case
        trait_bounds.param_is_pure_inspect_sink(callee_fn, idx, callee_bounds)
      {
        True -> emit_inspect_arg(val, ctx)
        False -> emit_expr(val, ctx)
      }
    None -> emit_expr(val, ctx)
  }
}

fn emit_inspect_arg(expr: IrExpr, ctx: EmitCtx) -> #(String, EmitCtx) {
  case expr {
    IrFn(params:, ..) -> {
      let ctx1 = add_gprelude_import(ctx)
      #(
        "@gprelude.inspect_fn(" <> int.to_string(list.length(params)) <> ")",
        ctx1,
      )
    }
    IrConstructor(target_module:, name:, ..) -> {
      let arity = case lookup_ctor_field_labels(target_module, name, ctx) {
        Some(labels) -> list.length(labels)
        None ->
          case name {
            "Ok" | "Err" | "Some" -> 1
            _ -> 0
          }
      }
      case arity > 0 {
        True -> {
          let ctx1 = add_gprelude_import(ctx)
          #("@gprelude.inspect_fn(" <> int.to_string(arity) <> ")", ctx1)
        }
        False -> emit_expr(expr, ctx)
      }
    }
    IrTuple(elements) ->
      case elements {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_inspect_arg(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1(" <> el_str <> ")", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(elements, ctx, emit_inspect_arg)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }
    IrList(elements:, tail:) -> {
      let ctx1 = add_gprelude_import(ctx)
      let #(tail_str, ctx2) = case tail {
        Some(t) -> emit_inspect_arg(t, ctx1)
        None -> #("@gprelude.Nil", ctx1)
      }
      let #(el_strs, ctx3) = map_acc(elements, ctx2, emit_inspect_arg)
      let expr_str =
        el_strs
        |> list.reverse
        |> list.fold(tail_str, fn(acc, el) {
          "@gprelude.Cons(" <> el <> ", " <> acc <> ")"
        })
      #(expr_str, ctx3)
    }
    _ -> emit_expr(expr, ctx)
  }
}

fn lookup_fn_param_labels(
  target_module: Option(String),
  fn_name: String,
  ctx: EmitCtx,
) -> Option(List(Option(String))) {
  let mod_name = option.unwrap(target_module, ctx.current_module)
  case ctx.table {
    Some(tbl) ->
      case dict.get(tbl.modules, mod_name) {
        Ok(ms) -> {
          let found =
            dict.values(ms.functions)
            |> list.find(fn(fi) { mangle.mangle_ident(fi.name) == fn_name })
          case found {
            Ok(fi) ->
              Some(
                list.map(fi.parameters, fn(p) {
                  option.map(p.label, mangle.mangle_ident)
                }),
              )
            Error(_) -> None
          }
        }
        Error(_) -> None
      }
    None ->
      case dict.get(ctx.project_bounds.all_fns, #(mod_name, fn_name)) {
        Ok(f) -> Some(list.map(f.params, fn(p) { p.label }))
        Error(_) -> None
      }
  }
}

fn align_call_args(
  args: List(IrCallArg),
  target_labels: List(Option(String)),
  keep_labels: Bool,
) -> List(IrCallArg) {
  let has_labels = list.any(args, fn(a) { option.is_some(a.label) })
  case list.length(args) == list.length(target_labels) {
    False ->
      case keep_labels {
        True -> args
        False -> list.map(args, fn(a) { IrCallArg(None, a.value) })
      }
    True ->
      case !has_labels && !keep_labels {
        True -> args
        False -> {
          let #(labeled_map, rev_positional) =
            list.fold(args, #(dict.new(), []), fn(acc, arg) {
              let #(lmap, pos) = acc
              case arg.label {
                Some(lbl) -> #(dict.insert(lmap, lbl, arg.value), pos)
                None -> #(lmap, [arg.value, ..pos])
              }
            })
          let #(rev_out, _) =
            list.fold(
              target_labels,
              #([], list.reverse(rev_positional)),
              fn(acc, lbl_opt) {
                let #(out, pos_q) = acc
                let out_lbl = case keep_labels {
                  True -> lbl_opt
                  False -> None
                }
                case lbl_opt {
                  Some(lbl) ->
                    case dict.get(labeled_map, lbl) {
                      Ok(v) -> #([IrCallArg(out_lbl, v), ..out], pos_q)
                      Error(_) ->
                        case pos_q {
                          [v, ..rest_pos] -> #(
                            [IrCallArg(out_lbl, v), ..out],
                            rest_pos,
                          )
                          [] -> #(out, pos_q)
                        }
                    }
                  None ->
                    case pos_q {
                      [v, ..rest_pos] -> #(
                        [IrCallArg(out_lbl, v), ..out],
                        rest_pos,
                      )
                      [] -> #(out, pos_q)
                    }
                }
              },
            )
          list.reverse(rev_out)
        }
      }
  }
}

fn emit_call_arg(arg: IrCallArg, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(val_str, ctx1) = emit_expr(arg.value, ctx)
  let s = case arg.label {
    Some(lbl) -> lbl <> "=" <> val_str
    None -> val_str
  }
  #(s, ctx1)
}

fn emit_list_expr(
  elements: List(IrExpr),
  tail: Option(IrExpr),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let ctx1 = add_gprelude_import(ctx)
  let #(tail_str, ctx2) = case tail {
    Some(t) -> emit_expr(t, ctx1)
    None -> #("@gprelude.Nil", ctx1)
  }
  let #(el_strs, ctx3) = map_acc(elements, ctx2, emit_expr)
  let expr_str =
    el_strs
    |> list.reverse
    |> list.fold(tail_str, fn(acc, el) {
      "@gprelude.Cons(" <> el <> ", " <> acc <> ")"
    })
  #(expr_str, ctx3)
}

fn emit_bit_string_expr(
  segments: List(#(IrExpr, List(glance.BitStringSegmentOption(IrExpr)))),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let ctx1 = add_gprelude_import(ctx)
  case segments {
    [] -> #("@gprelude.BitArray::empty()", ctx1)
    _ -> {
      let #(seg_strs, ctx2) =
        map_acc(segments, ctx1, fn(seg, c) { emit_bit_segment(seg.0, seg.1, c) })
      #(
        "@gprelude.bit_array_from_segments(["
          <> string.join(seg_strs, ", ")
          <> "])",
        ctx2,
      )
    }
  }
}

fn emit_bit_segment(
  val: IrExpr,
  opts: List(glance.BitStringSegmentOption(IrExpr)),
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(val_str, ctx1) = emit_expr(val, ctx)
  let has_bytes = list.contains(opts, glance.BytesOption)
  let has_bits = list.contains(opts, glance.BitsOption)
  let has_utf8 = list.contains(opts, glance.Utf8Option)
  let has_utf16 = list.contains(opts, glance.Utf16Option)
  let has_utf32 = list.contains(opts, glance.Utf32Option)
  let has_utf8_cp = list.contains(opts, glance.Utf8CodepointOption)
  let has_utf16_cp = list.contains(opts, glance.Utf16CodepointOption)
  let has_utf32_cp = list.contains(opts, glance.Utf32CodepointOption)
  let has_float = list.contains(opts, glance.FloatOption)
  let has_int = list.contains(opts, glance.IntOption)
  let has_size =
    list.any(opts, fn(o) {
      case o {
        glance.SizeOption(_) | glance.SizeValueOption(_) -> True
        _ -> False
      }
    })
  let big_endian =
    !list.any(opts, fn(o) {
      case o {
        glance.LittleOption | glance.NativeOption -> True
        _ -> False
      }
    })
  let endian_str = case big_endian {
    True -> "true"
    False -> "false"
  }

  case
    has_bytes || has_bits,
    has_utf8_cp,
    has_utf16_cp,
    has_utf32_cp,
    has_utf8,
    has_utf16,
    has_utf32
  {
    True, _, _, _, _, _, _ ->
      case has_size {
        False -> #(val_str, ctx1)
        True -> {
          let default_unit = case has_bytes {
            True -> 8
            False -> 1
          }
          let #(bits_str, ctx2) =
            compute_segment_bits(opts, 1, default_unit, ctx1)
          #(
            "@gprelude.BitArray::bits_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ")",
            ctx2,
          )
        }
      }
    _, True, _, _, _, _, _ -> #(
      "@gprelude.BitArray::utf8_codepoint_segment(" <> val_str <> ")",
      ctx1,
    )
    _, _, True, _, _, _, _ -> #(
      "@gprelude.BitArray::utf16_codepoint_segment("
        <> val_str
        <> ", "
        <> endian_str
        <> ")",
      ctx1,
    )
    _, _, _, True, _, _, _ -> #(
      "@gprelude.BitArray::utf32_codepoint_segment("
        <> val_str
        <> ", "
        <> endian_str
        <> ")",
      ctx1,
    )
    _, _, _, _, True, _, _ -> #(
      "@gprelude.BitArray::from_string(" <> val_str <> ")",
      ctx1,
    )
    _, _, _, _, _, True, _ -> #(
      "@gprelude.BitArray::from_utf16(" <> val_str <> ", " <> endian_str <> ")",
      ctx1,
    )
    _, _, _, _, _, _, True -> #(
      "@gprelude.BitArray::from_utf32(" <> val_str <> ", " <> endian_str <> ")",
      ctx1,
    )
    _, _, _, _, _, _, _ ->
      case val {
        IrString(_) if !has_int && !has_float -> #(
          "@gprelude.BitArray::from_string(" <> val_str <> ")",
          ctx1,
        )
        IrFloat(_) if !has_int -> {
          let #(bits_str, ctx2) = compute_segment_bits(opts, 64, 1, ctx1)
          #(
            "@gprelude.BitArray::float_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ", "
              <> endian_str
              <> ")",
            ctx2,
          )
        }
        _ if has_float -> {
          let #(bits_str, ctx2) = compute_segment_bits(opts, 64, 1, ctx1)
          #(
            "@gprelude.BitArray::float_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ", "
              <> endian_str
              <> ")",
            ctx2,
          )
        }
        _ -> {
          let #(bits_str, ctx2) = compute_segment_bits(opts, 8, 1, ctx1)
          #(
            "@gprelude.BitArray::int_segment("
              <> val_str
              <> ", "
              <> bits_str
              <> ", "
              <> endian_str
              <> ")",
            ctx2,
          )
        }
      }
  }
}

fn compute_segment_bits(
  opts: List(glance.BitStringSegmentOption(IrExpr)),
  default_size: Int,
  default_unit: Int,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let unit =
    list.fold(opts, default_unit, fn(acc, o) {
      case o {
        glance.UnitOption(u) -> u
        _ -> acc
      }
    })
  let size_opt =
    list.find_map(opts, fn(o) {
      case o {
        glance.SizeOption(n) -> Ok(Ok(n))
        glance.SizeValueOption(expr) -> Ok(Error(expr))
        _ -> Error(Nil)
      }
    })
  case size_opt {
    Ok(Ok(n)) -> #(int.to_string(n * unit) <> "L", ctx)
    Ok(Error(expr)) -> {
      let #(e_str, ctx1) = emit_expr(expr, ctx)
      case unit {
        1 -> #(e_str, ctx1)
        u -> #("(" <> e_str <> " * " <> int.to_string(u) <> "L)", ctx1)
      }
    }
    Error(_) -> #(int.to_string(default_size * unit) <> "L", ctx)
  }
}

fn emit_bin_op_expr(
  op: IrBinOp,
  left: IrExpr,
  right: IrExpr,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case op {
    IrEq | IrNotEq ->
      case
        nullary_multi_variant_ctor(left, ctx),
        nullary_multi_variant_ctor(right, ctx)
      {
        None, Some(#(ctor, ctx_c)) ->
          emit_is_empty_op(op == IrEq, left, ctor, ctx_c)
        Some(#(ctor, ctx_c)), None ->
          emit_is_empty_op(op == IrEq, right, ctor, ctx_c)
        _, _ -> emit_regular_bin_op_expr(op, left, right, ctx)
      }
    _ -> emit_regular_bin_op_expr(op, left, right, ctx)
  }
}

fn nullary_multi_variant_ctor(
  expr: IrExpr,
  ctx: EmitCtx,
) -> Option(#(String, EmitCtx)) {
  case expr {
    IrList(elements: [], tail: None) ->
      Some(#("@gprelude.Nil", add_gprelude_import(ctx)))
    IrConstructor(module_alias:, target_module:, name:) ->
      case lookup_ctor_info(target_module, name, ctx) {
        Some(#(variant_count, [])) if variant_count >= 2 -> {
          let #(prefix, ctx1) =
            emit_constructor_prefix(module_alias, target_module, name, ctx)
          Some(#(prefix <> name, ctx1))
        }
        _ -> None
      }
    _ -> None
  }
}

fn emit_is_empty_op(
  is_eq: Bool,
  subject: IrExpr,
  ctor: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(subj_raw, ctx1) = emit_expr(subject, ctx)
  let base = "((" <> subj_raw <> ") is " <> ctor <> ")"
  case is_eq {
    True -> #(base, ctx1)
    False -> #("!(" <> base <> ")", ctx1)
  }
}

fn emit_regular_bin_op_expr(
  op: IrBinOp,
  left: IrExpr,
  right: IrExpr,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(l_raw, ctx1) = emit_expr(left, ctx)
  let #(r_raw, ctx2) = emit_expr(right, ctx1)
  let l_str = paren_if_compound(left, l_raw)
  let r_str = paren_if_compound(right, r_raw)

  case op {
    IrDivInt -> {
      let ctx3 = add_gprelude_import(ctx2)
      #("@gprelude.int_div(" <> l_str <> ", " <> r_str <> ")", ctx3)
    }
    IrRemInt -> {
      let ctx3 = add_gprelude_import(ctx2)
      #("@gprelude.int_rem(" <> l_str <> ", " <> r_str <> ")", ctx3)
    }
    IrDivFloat -> {
      let ctx3 = add_gprelude_import(ctx2)
      #("@gprelude.float_div(" <> l_str <> ", " <> r_str <> ")", ctx3)
    }
    _ -> {
      let sym = case op {
        IrAnd -> "&&"
        IrOr -> "||"
        IrEq -> "=="
        IrNotEq -> "!="
        IrLtInt | IrLtFloat -> "<"
        IrLtEqInt | IrLtEqFloat -> "<="
        IrGtInt | IrGtFloat -> ">"
        IrGtEqInt | IrGtEqFloat -> ">="
        IrAddInt | IrAddFloat | IrStringConcat -> "+"
        IrSubInt | IrSubFloat -> "-"
        IrMultInt | IrMultFloat -> "*"
        IrDivInt | IrRemInt | IrDivFloat -> ""
      }
      #("(" <> l_str <> " " <> sym <> " " <> r_str <> ")", ctx2)
    }
  }
}

/// A `match` used as an operand or as another match's subject must be
/// parenthesised for MoonBit to parse it.
fn paren_if_match(expr: IrExpr, emitted: String) -> String {
  case expr {
    IrMatch(_, _) -> "(" <> emitted <> ")"
    _ -> emitted
  }
}

fn paren_if_compound(expr: IrExpr, emitted: String) -> String {
  case expr {
    IrMatch(_, _) | IrBlock(_) -> "(" <> emitted <> ")"
    _ -> emitted
  }
}

fn emit_match_expr(
  subjects: List(IrExpr),
  clauses: List(IrClause),
  indent: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(subj_strs, ctx1) =
    map_acc(subjects, ctx, fn(s, c) {
      let #(str, c1) = emit_expr(s, c)
      #(paren_if_match(s, str), c1)
    })
  let is_multi = list.length(subjects) > 1
  let subj_header = case is_multi {
    True -> "(" <> string.join(subj_strs, ", ") <> ")"
    False -> string.join(subj_strs, ", ")
  }
  let arm_indent = indent <> "  "
  let #(arm_strs, ctx2) =
    map_acc(clauses, ctx1, fn(clause, c) {
      emit_clause(clause, is_multi, arm_indent, c)
    })
  #(
    "match "
      <> subj_header
      <> " {\n"
      <> string.join(arm_strs, "\n")
      <> "\n"
      <> indent
      <> "}",
    ctx2,
  )
}

fn emit_clause(
  clause: IrClause,
  is_multi: Bool,
  indent: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let #(alt_strs, ctx1) =
    map_acc(clause.patterns, ctx, fn(alt, c) {
      let #(pat_strs, c_next) = map_acc(alt, c, emit_pattern)
      case is_multi {
        True -> #("(" <> string.join(pat_strs, ", ") <> ")", c_next)
        False -> #(string.join(pat_strs, ", "), c_next)
      }
    })
  let pat_part = string.join(alt_strs, " | ")

  let #(guard_part, ctx2) = case clause.guard {
    Some(g) -> {
      let #(g_str, c_next) = emit_expr_indented(g, indent, ctx1)
      #(" if " <> paren_if_match(g, g_str), c_next)
    }
    None -> #("", ctx1)
  }

  let body_indent = indent <> "  "
  let #(body_str, ctx3) = case clause.prefix_bindings {
    [] -> emit_expr_indented(clause.body, indent, ctx2)
    bindings -> {
      let #(bind_lines, c_b) =
        map_acc(bindings, ctx2, fn(b, c) {
          let #(val_str, c_v) = emit_expr_indented(b.1, body_indent, c)
          #(body_indent <> "let " <> b.0 <> " = " <> val_str, c_v)
        })
      let #(b_str, c_end) = emit_expr_indented(clause.body, body_indent, c_b)
      let lines = list.append(bind_lines, [body_indent <> b_str])
      #("{\n" <> string.join(lines, "\n") <> "\n" <> indent <> "}", c_end)
    }
  }

  #(indent <> pat_part <> guard_part <> " => " <> body_str, ctx3)
}

fn emit_pattern(pat: IrPattern, ctx: EmitCtx) -> #(String, EmitCtx) {
  case pat {
    IrPatInt(val) -> #(val <> "L", ctx)
    IrPatFloat(val) -> #(val, ctx)
    IrPatString(val) -> #("\"" <> escape_string_literal(val) <> "\"", ctx)
    IrPatBool(True) -> #("true", ctx)
    IrPatBool(False) -> #("false", ctx)
    IrPatUnit -> #("_", ctx)
    IrPatDiscard -> #("_", ctx)
    IrPatVar(name) -> #(name, ctx)

    IrPatTuple(els) ->
      case els {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_pattern(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1(" <> el_str <> ")", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(els, ctx, emit_pattern)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }

    IrPatAs(inner, alias) -> {
      let #(inner_str, ctx1) = emit_pattern(inner, ctx)
      #(inner_str <> " as " <> alias, ctx1)
    }

    IrPatVariant(
      module_alias:,
      target_module:,
      constructor:,
      args:,
      with_spread:,
    ) -> {
      let #(prefix, ctx1) =
        emit_constructor_prefix(module_alias, target_module, constructor, ctx)
      let normalized_args = case
        lookup_ctor_field_labels(target_module, constructor, ctx1)
      {
        Some(field_labels) -> align_pat_args(args, field_labels)
        None -> args
      }
      let #(arg_strs, ctx2) = map_acc(normalized_args, ctx1, emit_pat_arg)
      let all_args = case with_spread {
        True -> list.append(arg_strs, [".."])
        False -> arg_strs
      }
      case all_args {
        [] -> #(prefix <> constructor, ctx2)
        _ -> #(
          prefix
            <> constructor
            <> "("
            <> string.join(arg_strs_or_spread(all_args), ", ")
            <> ")",
          ctx2,
        )
      }
    }

    IrPatBitString(segments:) -> {
      let ctx1 = add_gprelude_import(ctx)
      case segments {
        [] -> #("{ bit_length: 0L, .. }", ctx1)
        _ -> #("_", ctx1)
      }
    }
  }
}

fn arg_strs_or_spread(items: List(String)) -> List(String) {
  items
}

fn emit_pat_arg(arg: IrPatArg, ctx: EmitCtx) -> #(String, EmitCtx) {
  let #(pat_str, ctx1) = emit_pattern(arg.pattern, ctx)
  let s = case arg.label {
    Some(lbl) ->
      case arg.pattern {
        IrPatVar(v) if v == lbl -> lbl <> "~"
        _ -> lbl <> "=" <> pat_str
      }
    None -> pat_str
  }
  #(s, ctx1)
}

fn emit_type(ty: IrType, ctx: EmitCtx) -> #(String, EmitCtx) {
  case ty {
    IrTypeInt64 -> #("Int64", ctx)
    IrTypeDouble -> #("Double", ctx)
    IrTypeString -> #("String", ctx)
    IrTypeBool -> #("Bool", ctx)
    IrTypeUnit -> #("Unit", ctx)
    IrTypeBitArray -> #("@gprelude.BitArray", add_gprelude_import(ctx))
    IrTypeList(inner) -> {
      let ctx1 = add_gprelude_import(ctx)
      let #(inner_str, ctx2) = emit_type(inner, ctx1)
      #("@gprelude.GList[" <> inner_str <> "]", ctx2)
    }
    IrTypeResult(ok_t, err_t) -> {
      let #(ok_str, ctx1) = emit_type(ok_t, ctx)
      let #(err_str, ctx2) = emit_type(err_t, ctx1)
      #("Result[" <> ok_str <> ", " <> err_str <> "]", ctx2)
    }
    IrTypeTuple(els) ->
      case els {
        [] -> #("@gprelude.Tuple0", add_gprelude_import(ctx))
        [el] -> {
          let #(el_str, ctx1) = emit_type(el, add_gprelude_import(ctx))
          #("@gprelude.Tuple1[" <> el_str <> "]", ctx1)
        }
        _ -> {
          let #(el_strs, ctx1) = map_acc(els, ctx, emit_type)
          #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
        }
      }
    IrTypeFn(params, ret) -> {
      let #(param_strs, ctx1) = map_acc(params, ctx, emit_type)
      let #(ret_str, ctx2) = emit_type(ret, ctx1)
      #("(" <> string.join(param_strs, ", ") <> ") -> " <> ret_str, ctx2)
    }
    IrTypeVar(name) -> #(name, ctx)
    IrTypeNamed(module_alias:, package: _, module:, name:, args:) ->
      case module, name {
        "gleam", "Dynamic" -> #("@gprelude.Dynamic", add_gprelude_import(ctx))
        "gleam", "UtfCodepoint" -> #(
          "@gprelude.UtfCodepoint",
          add_gprelude_import(ctx),
        )
        _, _ ->
          case lookup_external_type(module, name, ctx) {
            Some(ExternalType(package: pkg, type_name: target))
              if pkg == "" || pkg == "builtin"
            -> {
              let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
              let suffix = case arg_strs {
                [] -> ""
                _ -> "[" <> string.join(arg_strs, ", ") <> "]"
              }
              #(target <> suffix, ctx1)
            }
            Some(ExternalType(package: "gprelude", type_name: target)) -> {
              let ctx0 = add_gprelude_import(ctx)
              let #(arg_strs, ctx1) = map_acc(args, ctx0, emit_type)
              let suffix = case arg_strs {
                [] -> ""
                _ -> "[" <> string.join(arg_strs, ", ") <> "]"
              }
              #("@gprelude." <> target <> suffix, ctx1)
            }
            _ -> {
              let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
              let #(prefix, ctx2) = case module == ctx1.current_module {
                True -> #("", ctx1)
                False -> {
                  let #(alias, c) =
                    add_module_import(ctx1, module, module_alias)
                  #("@" <> alias <> ".", c)
                }
              }
              let suffix = case arg_strs {
                [] -> ""
                _ -> "[" <> string.join(arg_strs, ", ") <> "]"
              }
              #(prefix <> name <> suffix, ctx2)
            }
          }
      }
  }
}

fn pattern_is_irrefutable(pat: IrPattern) -> Bool {
  case pat {
    IrPatVar(_) | IrPatDiscard | IrPatUnit -> True
    IrPatTuple(els) -> list.all(els, pattern_is_irrefutable)
    IrPatAs(inner, _) -> pattern_is_irrefutable(inner)
    IrPatInt(_)
    | IrPatFloat(_)
    | IrPatString(_)
    | IrPatBool(_)
    | IrPatVariant(_, _, _, _, _)
    | IrPatBitString(_) -> False
  }
}

fn wrap_if_compound(expr: IrExpr, rendered: String) -> String {
  case expr {
    IrFn(_, _, _) | IrBlock(_) | IrMatch(_, _) | IrForLoop(_, _) ->
      "(" <> rendered <> ")"
    _ -> rendered
  }
}

fn format_type_params(params: List(String)) -> String {
  case params {
    [] -> ""
    _ -> "[" <> string.join(params, ", ") <> "]"
  }
}

fn format_function_type_params(
  f: IrFunction,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case f.type_params {
    [] -> #("", ctx)
    tps -> {
      let fn_bounds =
        trait_bounds.lookup_fn_bounds(
          ctx.project_bounds,
          ctx.current_module,
          f.name,
        )
      let #(rev_formatted, final_ctx) =
        list.fold(tps, #([], ctx), fn(acc, tp) {
          let #(parts, cur_ctx) = acc
          let has_eq = set.contains(fn_bounds.eq_vars, tp)
          let has_inspect = set.contains(fn_bounds.inspect_vars, tp)
          let has_to_dyn = set.contains(fn_bounds.to_dynamic_vars, tp)
          let traits =
            []
            |> fn(ts) {
              case has_to_dyn {
                True -> ["@gprelude.ToDynamic", ..ts]
                False -> ts
              }
            }
            |> fn(ts) {
              case has_inspect {
                True -> ["@gprelude.GleamInspect", ..ts]
                False -> ts
              }
            }
            |> fn(ts) {
              case has_eq {
                True -> ["Eq", "Hash", ..ts]
                False -> ts
              }
            }
          let #(entry, next_ctx) = case traits {
            [] -> #(tp, cur_ctx)
            _ -> {
              let ctx_g = case has_inspect || has_to_dyn {
                True -> add_gprelude_import(cur_ctx)
                False -> cur_ctx
              }
              #(tp <> " : " <> string.join(traits, " + "), ctx_g)
            }
          }
          #([entry, ..parts], next_ctx)
        })
      #(
        "["
          <> {
          list.reverse(rev_formatted)
          |> string.join(", ")
        }
          <> "]",
        final_ctx,
      )
    }
  }
}

fn infer_fn_param_types(
  params: List(IrFnParam),
  body: List(IrStmt),
) -> dict.Dict(String, IrType) {
  let untyped_names =
    list.fold(params, set.new(), fn(acc, p) {
      case p.param_type, p.name {
        None, "_" -> acc
        None, name -> set.insert(acc, name)
        Some(_), _ -> acc
      }
    })
  case set.is_empty(untyped_names) {
    True -> dict.new()
    False -> infer_stmts_var_types(body, untyped_names, dict.new())
  }
}

fn infer_stmts_var_types(
  stmts: List(IrStmt),
  tracked: Set(String),
  acc: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case stmts {
    [] -> acc
    [stmt, ..rest] ->
      case stmt {
        IrStmtLet(pattern:, value:, ..) -> {
          let acc1 = infer_expr_var_types(value, tracked, acc)
          let next_tracked = set.difference(tracked, ir_pattern_vars(pattern))
          infer_stmts_var_types(rest, next_tracked, acc1)
        }
        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) -> {
          let acc1 = infer_expr_var_types(value, tracked, acc)
          let after_pat = set.difference(tracked, ir_pattern_vars(pattern))
          let after_post =
            list.fold(post_bindings, after_pat, fn(t, b) { set.delete(t, b.0) })
          let acc2 =
            list.fold(post_bindings, acc1, fn(a, b) {
              infer_expr_var_types(b.1, after_pat, a)
            })
          let acc3 = case guard_condition {
            Some(g) -> infer_expr_var_types(g, after_post, acc2)
            None -> acc2
          }
          let acc4 = case abort_message {
            Some(m) -> infer_expr_var_types(m, after_post, acc3)
            None -> acc3
          }
          infer_stmts_var_types(rest, after_post, acc4)
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let acc1 = infer_expr_var_types(condition, tracked, acc)
          let acc2 = case abort_message {
            Some(m) -> infer_expr_var_types(m, tracked, acc1)
            None -> acc1
          }
          infer_stmts_var_types(rest, tracked, acc2)
        }
        IrStmtExpr(expr) ->
          infer_stmts_var_types(
            rest,
            tracked,
            infer_expr_var_types(expr, tracked, acc),
          )
      }
  }
}

fn infer_expr_var_types(
  expr: IrExpr,
  tracked: Set(String),
  acc: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case expr {
    IrNegateInt(inner) -> {
      let acc1 = record_tracked_var(inner, IrTypeInt64, tracked, acc)
      infer_expr_var_types(inner, tracked, acc1)
    }
    IrNegateBool(inner) -> {
      let acc1 = record_tracked_var(inner, IrTypeBool, tracked, acc)
      infer_expr_var_types(inner, tracked, acc1)
    }
    IrBinOp(op:, left:, right:) -> {
      let operand_ty = case op {
        IrAddInt
        | IrSubInt
        | IrMultInt
        | IrDivInt
        | IrRemInt
        | IrLtInt
        | IrLtEqInt
        | IrGtInt
        | IrGtEqInt -> Some(IrTypeInt64)
        IrAddFloat
        | IrSubFloat
        | IrMultFloat
        | IrDivFloat
        | IrLtFloat
        | IrLtEqFloat
        | IrGtFloat
        | IrGtEqFloat -> Some(IrTypeDouble)
        IrStringConcat -> Some(IrTypeString)
        IrAnd | IrOr -> Some(IrTypeBool)
        IrEq | IrNotEq -> None
      }
      let acc1 = case operand_ty {
        Some(ty) ->
          record_tracked_var(left, ty, tracked, acc)
          |> record_tracked_var(right, ty, tracked, _)
        None -> acc
      }
      infer_expr_var_types(left, tracked, acc1)
      |> infer_expr_var_types(right, tracked, _)
    }
    IrCall(function:, args:) -> {
      let acc1 = infer_expr_var_types(function, tracked, acc)
      list.fold(args, acc1, fn(a, arg) {
        infer_expr_var_types(arg.value, tracked, a)
      })
    }
    IrBlock(stmts) -> infer_stmts_var_types(stmts, tracked, acc)
    IrFn(params:, body:, ..) -> {
      let shadowed =
        list.fold(params, set.new(), fn(s, p) { set.insert(s, p.name) })
      let inner_tracked = set.difference(tracked, shadowed)
      infer_stmts_var_types(body, inner_tracked, acc)
    }
    IrMatch(subjects:, clauses:) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) {
          infer_expr_var_types(s, tracked, a)
        })
      list.fold(clauses, acc1, fn(a, c) {
        let pat_shadowed =
          list.fold(c.patterns, set.new(), fn(s, alt) {
            list.fold(alt, s, fn(s2, p) { set.union(s2, ir_pattern_vars(p)) })
          })
        let after_pat = set.difference(tracked, pat_shadowed)
        let after_post =
          list.fold(c.prefix_bindings, after_pat, fn(t, b) {
            set.delete(t, b.0)
          })
        let a1 =
          list.fold(c.prefix_bindings, a, fn(x, b) {
            infer_expr_var_types(b.1, after_pat, x)
          })
        let a2 = case c.guard {
          Some(g) -> infer_expr_var_types(g, after_post, a1)
          None -> a1
        }
        infer_expr_var_types(c.body, after_post, a2)
      })
    }
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, acc, fn(a, e) { infer_expr_var_types(e, tracked, a) })
    IrList(elements:, tail:) -> {
      let acc1 =
        list.fold(elements, acc, fn(a, e) {
          infer_expr_var_types(e, tracked, a)
        })
      case tail {
        Some(t) -> infer_expr_var_types(t, tracked, acc1)
        None -> acc1
      }
    }
    IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..)
    | IrBreak(inner) -> infer_expr_var_types(inner, tracked, acc)
    IrForLoop(bindings:, body:) -> {
      let acc1 =
        list.fold(bindings, acc, fn(a, b) {
          infer_expr_var_types(b.1, tracked, a)
        })
      let shadowed =
        list.fold(bindings, set.new(), fn(s, b) { set.insert(s, b.0) })
      infer_stmts_var_types(body, set.difference(tracked, shadowed), acc1)
    }
    _ -> acc
  }
}

fn record_tracked_var(
  expr: IrExpr,
  ty: IrType,
  tracked: Set(String),
  acc: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case expr {
    IrVar(name) ->
      case set.contains(tracked, name) && !dict.has_key(acc, name) {
        True -> dict.insert(acc, name, ty)
        False -> acc
      }
    _ -> acc
  }
}

fn ir_pattern_vars(pat: IrPattern) -> Set(String) {
  case pat {
    IrPatVar(name) -> set.from_list([name])
    IrPatAs(inner, alias) -> set.insert(ir_pattern_vars(inner), alias)
    IrPatTuple(els) ->
      list.fold(els, set.new(), fn(acc, el) {
        set.union(acc, ir_pattern_vars(el))
      })
    IrPatVariant(args:, ..) ->
      list.fold(args, set.new(), fn(acc, arg) {
        set.union(acc, ir_pattern_vars(arg.pattern))
      })
    IrPatBitString(segments:) ->
      list.fold(segments, set.new(), fn(acc, seg) {
        set.union(acc, ir_pattern_vars(seg.0))
      })
    _ -> set.new()
  }
}

fn align_pat_args(
  args: List(IrPatArg),
  field_labels: List(Option(String)),
) -> List(IrPatArg) {
  let has_unlabelled_for_labelled =
    list.any(args, fn(a) { option.is_none(a.label) })
    && list.any(field_labels, option.is_some)
  case
    has_unlabelled_for_labelled
    && list.length(args) <= list.length(field_labels)
  {
    False -> args
    True -> {
      let #(labeled_map, rev_positional) =
        list.fold(args, #(dict.new(), []), fn(acc, arg) {
          let #(lmap, pos) = acc
          case arg.label {
            Some(lbl) -> #(dict.insert(lmap, lbl, arg.pattern), pos)
            None -> #(lmap, [arg.pattern, ..pos])
          }
        })
      let #(rev_out, _) =
        list.fold(
          field_labels,
          #([], list.reverse(rev_positional)),
          fn(acc, lbl_opt) {
            let #(out, pos_q) = acc
            case lbl_opt {
              Some(lbl) ->
                case dict.get(labeled_map, lbl) {
                  Ok(p) -> #([IrPatArg(Some(lbl), p), ..out], pos_q)
                  Error(_) ->
                    case pos_q {
                      [p, ..rest_pos] -> #(
                        [IrPatArg(Some(lbl), p), ..out],
                        rest_pos,
                      )
                      [] -> #(out, pos_q)
                    }
                }
              None ->
                case pos_q {
                  [p, ..rest_pos] -> #([IrPatArg(None, p), ..out], rest_pos)
                  [] -> #(out, pos_q)
                }
            }
          },
        )
      list.reverse(rev_out)
    }
  }
}

fn escape_string_literal(raw: String) -> String {
  // Escape unescaped `\{` interpolation sequences (odd backslash count before `{`)
  // and raw CR/LF inside multiline Gleam strings.
  escape_string_literal_loop(string.to_graphemes(raw), False, [])
  |> list.reverse
  |> string.concat
}

fn escape_string_literal_loop(
  chars: List(String),
  prev_backslash: Bool,
  rev_acc: List(String),
) -> List(String) {
  case chars {
    [] -> rev_acc
    [ch, ..rest] ->
      case ch {
        "\\" ->
          escape_string_literal_loop(rest, !prev_backslash, [ch, ..rev_acc])
        "{" if prev_backslash ->
          escape_string_literal_loop(rest, False, ["\\{", ..rev_acc])
        "\r" -> escape_string_literal_loop(rest, False, ["\\r", ..rev_acc])
        "\n" -> escape_string_literal_loop(rest, False, ["\\n", ..rev_acc])
        _ -> escape_string_literal_loop(rest, False, [ch, ..rev_acc])
      }
  }
}

fn escape_plain_string(raw: String) -> String {
  raw
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\r", "\\r")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
  |> string.replace("\\{", "\\\\{")
}

fn map_acc(
  items: List(a),
  ctx: EmitCtx,
  f: fn(a, EmitCtx) -> #(b, EmitCtx),
) -> #(List(b), EmitCtx) {
  let #(rev_out, final_ctx) =
    list.fold(items, #([], ctx), fn(acc, item) {
      let #(out_acc, cur_ctx) = acc
      let #(rendered, next_ctx) = f(item, cur_ctx)
      #([rendered, ..out_acc], next_ctx)
    })
  #(list.reverse(rev_out), final_ctx)
}

fn map_index_acc(
  items: List(a),
  ctx: EmitCtx,
  f: fn(a, Int, EmitCtx) -> #(b, EmitCtx),
) -> #(List(b), EmitCtx) {
  let #(rev_out, _, final_ctx) =
    list.fold(items, #([], 0, ctx), fn(acc, item) {
      let #(out_acc, idx, cur_ctx) = acc
      let #(rendered, next_ctx) = f(item, idx, cur_ctx)
      #([rendered, ..out_acc], idx + 1, next_ctx)
    })
  #(list.reverse(rev_out), final_ctx)
}

fn emit_type_eq_impl(td: IrTypeDef, dict_key_params: Set(String)) -> String {
  let vis = case td.publicity {
    glance.Public -> "pub "
    glance.Private -> ""
  }
  let impl_generics = case td.type_params {
    [] -> ""
    tps ->
      "["
      <> {
        list.map(tps, fn(tp) {
          case set.contains(dict_key_params, tp) {
            True -> tp <> " : Eq + Hash"
            False -> tp <> " : Eq"
          }
        })
        |> string.join(", ")
      }
      <> "]"
  }
  let self_ty = td.name <> format_type_params(td.type_params)
  let body = case td.variants {
    [] -> "  @prelude.ignore(self)\n  @prelude.ignore(other)\n  true"
    variants -> {
      let arms =
        list.map(variants, fn(v) {
          case v.fields {
            [] -> "    (" <> v.name <> ", " <> v.name <> ") => true"
            fields -> {
              let #(lhs_pats, rhs_pats, cmps) =
                list.index_fold(fields, #([], [], []), fn(acc, f, idx) {
                  let #(lp, rp, cs) = acc
                  let lname = "l" <> int.to_string(idx)
                  let rname = "r" <> int.to_string(idx)
                  let #(lpat, rpat) = case f.label {
                    Some(lbl) -> #(lbl <> "=" <> lname, lbl <> "=" <> rname)
                    None -> #(lname, rname)
                  }
                  #([lpat, ..lp], [rpat, ..rp], [lname <> " == " <> rname, ..cs])
                })
              let l_str =
                list.reverse(lhs_pats)
                |> string.join(", ")
              let r_str =
                list.reverse(rhs_pats)
                |> string.join(", ")
              let cmp_str =
                list.reverse(cmps)
                |> string.join(" && ")
              "    ("
              <> v.name
              <> "("
              <> l_str
              <> "), "
              <> v.name
              <> "("
              <> r_str
              <> ")) => "
              <> cmp_str
            }
          }
        })
      let all_arms = case list.length(variants) > 1 {
        True -> list.append(arms, ["    _ => false"])
        False -> arms
      }
      "  match (self, other) {\n" <> string.join(all_arms, "\n") <> "\n  }"
    }
  }
  "///|\n"
  <> vis
  <> "impl"
  <> impl_generics
  <> " Eq for "
  <> self_ty
  <> " with equal(self, other) {\n"
  <> body
  <> "\n}"
}

fn collect_visible_alias_names(module: IrModule) -> Set(String) {
  let seed =
    list.fold(module.type_aliases, set.new(), fn(acc, ta) {
      case
        ta.publicity == glance.Public
        || is_alias_referenced_in_module(module, ta.name)
      {
        True -> set.insert(acc, ta.name)
        False -> acc
      }
    })
  expand_visible_aliases(module.type_aliases, module.module_name, seed)
}

fn expand_visible_aliases(
  aliases: List(IrTypeAlias),
  cur_mod: String,
  visible: Set(String),
) -> Set(String) {
  let #(next_visible, changed) =
    list.fold(aliases, #(visible, False), fn(acc, ta) {
      let #(vis_set, _ch) = acc
      case set.contains(vis_set, ta.name) {
        True -> acc
        False -> {
          let used_by_visible =
            list.any(aliases, fn(other) {
              set.contains(vis_set, other.name)
              && type_uses_local_name(other.aliased, cur_mod, ta.name)
            })
          case used_by_visible {
            True -> #(set.insert(vis_set, ta.name), True)
            False -> acc
          }
        }
      }
    })
  case changed {
    True -> expand_visible_aliases(aliases, cur_mod, next_visible)
    False -> next_visible
  }
}

fn is_alias_referenced_in_module(module: IrModule, alias_name: String) -> Bool {
  let cur_mod = module.module_name
  let in_types =
    list.any(module.types, fn(td) {
      td.external_type == None
      && list.any(td.variants, fn(v) {
        list.any(v.fields, fn(f) {
          type_uses_local_name(f.field_type, cur_mod, alias_name)
        })
      })
    })
  let in_aliases =
    list.any(module.type_aliases, fn(ta) {
      ta.publicity == glance.Public
      && type_uses_local_name(ta.aliased, cur_mod, alias_name)
    })
  let in_getters =
    list.any(module.getters, fn(g) {
      type_uses_local_name(g.return_type, cur_mod, alias_name)
    })
  let in_consts =
    list.any(module.constants, fn(c) {
      type_uses_local_name(c.value_type, cur_mod, alias_name)
    })
  let in_fns =
    list.any(module.functions, fn(f) {
      list.any(f.params, fn(p) {
        type_uses_local_name(p.param_type, cur_mod, alias_name)
      })
      || type_uses_local_name(f.return_type, cur_mod, alias_name)
      || stmts_use_local_type(f.body, cur_mod, alias_name)
    })
  in_types || in_aliases || in_getters || in_consts || in_fns
}

fn type_uses_local_name(
  ty: IrType,
  cur_mod: String,
  alias_name: String,
) -> Bool {
  case ty {
    IrTypeNamed(module:, name:, args:, ..) ->
      { { module == "" || module == cur_mod } && name == alias_name }
      || list.any(args, type_uses_local_name(_, cur_mod, alias_name))
    IrTypeList(inner) -> type_uses_local_name(inner, cur_mod, alias_name)
    IrTypeResult(ok_t, err_t) ->
      type_uses_local_name(ok_t, cur_mod, alias_name)
      || type_uses_local_name(err_t, cur_mod, alias_name)
    IrTypeTuple(els) ->
      list.any(els, type_uses_local_name(_, cur_mod, alias_name))
    IrTypeFn(ps, r) ->
      list.any(ps, type_uses_local_name(_, cur_mod, alias_name))
      || type_uses_local_name(r, cur_mod, alias_name)
    _ -> False
  }
}

fn stmts_use_local_type(
  stmts: List(IrStmt),
  cur_mod: String,
  alias_name: String,
) -> Bool {
  list.any(stmts, fn(s) {
    case s {
      IrStmtLet(annotation: Some(ann), value:, ..) ->
        type_uses_local_name(ann, cur_mod, alias_name)
        || expr_uses_local_type(value, cur_mod, alias_name)
      IrStmtLet(value:, ..) -> expr_uses_local_type(value, cur_mod, alias_name)
      IrStmtGuard(value:, guard_condition:, abort_message:, post_bindings:, ..) ->
        expr_uses_local_type(value, cur_mod, alias_name)
        || option.map(guard_condition, expr_uses_local_type(
          _,
          cur_mod,
          alias_name,
        ))
        == Some(True)
        || option.map(abort_message, expr_uses_local_type(
          _,
          cur_mod,
          alias_name,
        ))
        == Some(True)
        || list.any(post_bindings, fn(b) {
          expr_uses_local_type(b.1, cur_mod, alias_name)
        })
      IrStmtAssert(condition:, abort_message:) ->
        expr_uses_local_type(condition, cur_mod, alias_name)
        || option.map(abort_message, expr_uses_local_type(
          _,
          cur_mod,
          alias_name,
        ))
        == Some(True)
      IrStmtExpr(expr) -> expr_uses_local_type(expr, cur_mod, alias_name)
    }
  })
}

fn expr_uses_local_type(
  expr: IrExpr,
  cur_mod: String,
  alias_name: String,
) -> Bool {
  case expr {
    IrFn(params:, return_type:, body:) ->
      list.any(params, fn(p) {
        option.map(p.param_type, type_uses_local_name(_, cur_mod, alias_name))
        == Some(True)
      })
      || option.map(return_type, type_uses_local_name(_, cur_mod, alias_name))
      == Some(True)
      || stmts_use_local_type(body, cur_mod, alias_name)
    IrBlock(stmts) -> stmts_use_local_type(stmts, cur_mod, alias_name)
    IrForLoop(bindings:, body:) ->
      list.any(bindings, fn(b) {
        expr_uses_local_type(b.1, cur_mod, alias_name)
      })
      || stmts_use_local_type(body, cur_mod, alias_name)
    IrBinOp(left:, right:, ..) ->
      expr_uses_local_type(left, cur_mod, alias_name)
      || expr_uses_local_type(right, cur_mod, alias_name)
    IrNegateInt(i)
    | IrNegateBool(i)
    | IrBreak(i)
    | IrGetterCall(receiver: i, ..) ->
      expr_uses_local_type(i, cur_mod, alias_name)
    IrEcho(expr: i, message:, ..) ->
      expr_uses_local_type(i, cur_mod, alias_name)
      || option.map(message, expr_uses_local_type(_, cur_mod, alias_name))
      == Some(True)
    IrBitString(segments:) ->
      list.any(segments, fn(seg) {
        expr_uses_local_type(seg.0, cur_mod, alias_name)
        || list.any(seg.1, fn(opt) {
          case opt {
            glance.SizeValueOption(e) ->
              expr_uses_local_type(e, cur_mod, alias_name)
            _ -> False
          }
        })
      })
    IrTuple(els) | IrContinue(els) ->
      list.any(els, expr_uses_local_type(_, cur_mod, alias_name))
    IrTupleIndex(tuple:, ..) -> expr_uses_local_type(tuple, cur_mod, alias_name)
    IrList(elements:, tail:) ->
      list.any(elements, expr_uses_local_type(_, cur_mod, alias_name))
      || option.map(tail, expr_uses_local_type(_, cur_mod, alias_name))
      == Some(True)
    IrCall(function:, args:) ->
      expr_uses_local_type(function, cur_mod, alias_name)
      || list.any(args, fn(a) {
        expr_uses_local_type(a.value, cur_mod, alias_name)
      })
    IrMatch(subjects:, clauses:) ->
      list.any(subjects, expr_uses_local_type(_, cur_mod, alias_name))
      || list.any(clauses, fn(c) {
        expr_uses_local_type(c.body, cur_mod, alias_name)
      })
    _ -> False
  }
}
