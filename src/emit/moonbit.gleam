import emit/pkg_config
import glance
import gleam/dict
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
import project/interface.{
  type ResolvedType, FnType, NamedType, TupleType, VariableType,
}
import project/prepass.{ExternalType, PackageCall, WasmImport}

type EmitCtx {
  EmitCtx(
    current_module: String,
    local_ctors: dict.Dict(String, List(Option(String))),
    local_external_types: Set(String),
    table: Option(SymbolTable),
    pkg_to_alias: dict.Dict(String, String),
    used_aliases: Set(String),
    fn_eq_bounds: dict.Dict(String, Set(String)),
  )
}

/// Render a lowered `IrModule` into MoonBit source code and the list of
/// `#(pkg_or_dir, alias)` imports needed for its `moon.pkg`.
pub fn emit_module(module: IrModule) -> #(String, List(#(String, String))) {
  emit_module_inner(module, None)
}

/// Render a lowered `IrModule` with full `SymbolTable` access (enabling
/// higher-order eta-expansion for imported constructors).
pub fn emit_module_with_table(
  module: IrModule,
  table: SymbolTable,
) -> #(String, List(#(String, String))) {
  emit_module_inner(module, Some(table))
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
) -> #(String, List(#(String, String))) {
  let local_ctors =
    list.fold(module.types, dict.new(), fn(acc, td) {
      list.fold(td.variants, acc, fn(inner, v) {
        dict.insert(inner, v.name, list.map(v.fields, fn(f) { f.label }))
      })
    })

  let local_external_types =
    list.filter_map(module.types, fn(td) {
      case td.external_type {
        Some(_) -> Ok(td.name)
        None -> Error(Nil)
      }
    })
    |> set.from_list

  let ctx0 =
    EmitCtx(
      current_module: module.module_name,
      local_ctors:,
      local_external_types:,
      table:,
      pkg_to_alias: dict.new(),
      used_aliases: set.from_list(["gprelude"]),
      fn_eq_bounds: dict.new(),
    )

  let #(raw_type_blocks, ctx1) = map_acc(module.types, ctx0, emit_type_def)
  let type_blocks = list.filter(raw_type_blocks, fn(b) { b != "" })

  let visible_aliases =
    list.filter(module.type_aliases, fn(ta) {
      ta.publicity == glance.Public
      || is_alias_referenced_in_module(module, ta.name)
    })
  let #(alias_blocks, ctx2) = map_acc(visible_aliases, ctx1, emit_type_alias)

  let #(getter_blocks, ctx3) = map_acc(module.getters, ctx2, emit_getter)

  let #(const_blocks, ctx4) = map_acc(module.constants, ctx3, emit_constant)

  let fn_eq_bounds = compute_module_eq_bounds(module, ctx4)
  let ctx4_with_bounds = EmitCtx(..ctx4, fn_eq_bounds:)
  let #(fn_blocks, ctx5) =
    map_acc(module.functions, ctx4_with_bounds, emit_function)

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
      let dict_key_params = collect_td_dict_key_vars(td)
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
  case symbol_table.is_builtin_inspectable_external(module, name) {
    True -> False
    False ->
      case
        module == ctx.current_module
        && set.contains(ctx.local_external_types, name)
      {
        True -> True
        False ->
          case ctx.table {
            None -> False
            Some(tbl) ->
              case dict.get(tbl.modules, module) {
                Error(_) -> False
                Ok(ms) ->
                  case dict.get(ms.types, name) {
                    Ok(ti) -> option.is_some(ti.external_type)
                    Error(_) ->
                      dict.values(ms.types)
                      |> list.any(fn(ti) {
                        mangle.mangle_type_name(ti.name) == name
                        && option.is_some(ti.external_type)
                      })
                  }
              }
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
      <> escape_string_literal(f.unmangled_name)
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
      case pattern_is_irrefutable(pattern) {
        True -> {
          let #(ann_str, ctx3) = case annotation {
            Some(ann) -> {
              let #(t_str, c) = emit_type(ann, ctx2)
              #(" : " <> t_str, c)
            }
            None -> #("", ctx2)
          }
          #(indent <> "let " <> pat_str <> ann_str <> " = " <> val_str, ctx3)
        }
        False -> #(
          indent
            <> "guard "
            <> val_str
            <> " is "
            <> pat_str
            <> " else { @prelude.abort(\"let pattern match failed\") }",
          ctx2,
        )
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
      let #(guard_line, ctx3) = case pattern, guard_condition {
        IrPatVar(v), Some(cond) -> {
          let #(cond_str, c) = emit_expr_indented(cond, indent, ctx2)
          #(
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
              <> ") }",
            c,
          )
        }
        IrPatVar(v), None -> #(indent <> "let " <> v <> " = " <> val_str, ctx2)
        IrPatDiscard, None -> #(
          indent <> "@prelude.ignore(" <> val_str <> ")",
          ctx2,
        )
        _, _ -> {
          let #(pat_str, c1) = emit_pattern(pattern, ctx2)
          let #(cond_suffix, c2) = case guard_condition {
            Some(cond) -> {
              let #(cond_str, c) = emit_expr_indented(cond, indent, c1)
              #(" && " <> paren_if_compound(cond, cond_str), c)
            }
            None -> #("", c1)
          }
          #(
            indent
              <> "guard "
              <> val_str
              <> " is "
              <> pat_str
              <> cond_suffix
              <> " else { @prelude.abort("
              <> msg_str
              <> ") }",
            c2,
          )
        }
      }

      let #(binding_lines, ctx4) =
        map_acc(post_bindings, ctx3, fn(binding, c) {
          let #(name, expr) = binding
          let #(expr_str, c_next) = emit_expr(expr, c)
          #(indent <> "let " <> name <> " = " <> expr_str, c_next)
        })

      let all = [guard_line, ..binding_lines]
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

    IrTuple(elements) -> {
      let #(el_strs, ctx1) = map_acc(elements, ctx, emit_expr)
      #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
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
      let #(param_strs, ctx1) =
        map_acc(params, ctx, fn(p, c) {
          case p.param_type {
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
        <> escape_string_literal(file_path)
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
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  case target_module {
    Some("gleam/option") -> #("", ctx)
    Some(tm) if tm != ctx.current_module -> {
      let #(alias, ctx1) = add_module_import(ctx, tm, module_alias)
      #("@" <> alias <> ".", ctx1)
    }
    _ ->
      case module_alias {
        Some("gprelude") -> #("@gprelude.", add_gprelude_import(ctx))
        _ -> #("", ctx)
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
    emit_constructor_prefix(module_alias, target_module, ctx)
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

fn lookup_ctor_field_labels(
  target_module: Option(String),
  ctor_name: String,
  ctx: EmitCtx,
) -> Option(List(Option(String))) {
  case target_module, ctx.table {
    Some(tm), Some(tbl) ->
      case dict.get(tbl.modules, tm) {
        Ok(ms) ->
          case dict.get(ms.constructors, ctor_name) {
            Ok(ctor) -> Some(list.map(ctor.fields, fn(f) { f.label }))
            Error(_) -> None
          }
        Error(_) -> None
      }
    _, _ ->
      case dict.get(ctx.local_ctors, ctor_name) {
        Ok(labels) -> Some(labels)
        Error(_) -> None
      }
  }
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
        emit_constructor_prefix(module_alias, target_module, ctx1)
      case normalized_args {
        [] -> #(prefix <> name, ctx2)
        _ -> #(prefix <> name <> "(" <> args_joined <> ")", ctx2)
      }
    }

    IrModuleRef(module_alias:, target_module:, symbol:) -> {
      let ordered_args = case
        lookup_fn_param_labels(Some(target_module), symbol, ctx)
      {
        Some(param_labels) -> align_call_args(args, param_labels, False)
        None -> args
      }
      let #(arg_strs, ctx1) =
        map_acc(ordered_args, ctx, fn(a, c) { emit_expr(a.value, c) })
      let args_joined = string.join(arg_strs, ", ")
      let #(alias, ctx2) = add_module_import(ctx1, target_module, module_alias)
      #("@" <> alias <> "." <> symbol <> "(" <> args_joined <> ")", ctx2)
    }

    IrVar(fn_name) -> {
      let ordered_args = case lookup_fn_param_labels(None, fn_name, ctx) {
        Some(param_labels) -> align_call_args(args, param_labels, False)
        None -> args
      }
      let #(arg_strs, ctx1) =
        map_acc(ordered_args, ctx, fn(a, c) { emit_expr(a.value, c) })
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

fn lookup_fn_param_labels(
  target_module: Option(String),
  fn_name: String,
  ctx: EmitCtx,
) -> Option(List(Option(String))) {
  case ctx.table {
    None -> None
    Some(tbl) -> {
      let mod_name = option.unwrap(target_module, ctx.current_module)
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
        is_empty_list_or_none(left, ctx.current_module),
        is_empty_list_or_none(right, ctx.current_module)
      {
        None, Some(ctor) -> emit_is_empty_op(op == IrEq, left, ctor, ctx)
        Some(ctor), None -> emit_is_empty_op(op == IrEq, right, ctor, ctx)
        _, _ -> emit_regular_bin_op_expr(op, left, right, ctx)
      }
    _ -> emit_regular_bin_op_expr(op, left, right, ctx)
  }
}

fn is_empty_list_or_none(
  expr: IrExpr,
  current_module: String,
) -> Option(String) {
  case expr {
    IrList(elements: [], tail: None) -> Some("@gprelude.Nil")
    IrConstructor(target_module: Some("gleam/option"), name: "None", ..) ->
      Some("None")
    IrConstructor(target_module: None, name: "None", ..)
      if current_module == "gleam/option"
    -> Some("None")
    _ -> None
  }
}

fn emit_is_empty_op(
  is_eq: Bool,
  subject: IrExpr,
  ctor: String,
  ctx: EmitCtx,
) -> #(String, EmitCtx) {
  let ctx0 = case ctor {
    "@gprelude.Nil" -> add_gprelude_import(ctx)
    _ -> ctx
  }
  let #(subj_raw, ctx1) = emit_expr(subject, ctx0)
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

    IrPatTuple(els) -> {
      let #(el_strs, ctx1) = map_acc(els, ctx, emit_pattern)
      #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
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
        emit_constructor_prefix(module_alias, target_module, ctx)
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
    IrTypeTuple(els) -> {
      let #(el_strs, ctx1) = map_acc(els, ctx, emit_type)
      #("(" <> string.join(el_strs, ", ") <> ")", ctx1)
    }
    IrTypeFn(params, ret) -> {
      let #(param_strs, ctx1) = map_acc(params, ctx, emit_type)
      let #(ret_str, ctx2) = emit_type(ret, ctx1)
      #("(" <> string.join(param_strs, ", ") <> ") -> " <> ret_str, ctx2)
    }
    IrTypeVar(name) -> #(name, ctx)
    IrTypeNamed(module_alias:, package: _, module:, name:, args:) ->
      case module, name {
        "gleam", "Dynamic" | "gleam/dynamic", "Dynamic" -> #(
          "@gprelude.Dynamic",
          add_gprelude_import(ctx),
        )
        "gleam", "UtfCodepoint" -> #(
          "@gprelude.UtfCodepoint",
          add_gprelude_import(ctx),
        )
        "gleam/option", "Option" -> {
          let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
          #("Option[" <> string.join(arg_strs, ", ") <> "]", ctx1)
        }
        _, _ -> {
          let #(arg_strs, ctx1) = map_acc(args, ctx, emit_type)
          let #(prefix, ctx2) = case module == ctx1.current_module {
            True -> #("", ctx1)
            False -> {
              let #(alias, c) = add_module_import(ctx1, module, module_alias)
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
      let needs_inspect =
        {
          ctx.current_module == "gleam/string"
          && {
            f.unmangled_name == "inspect" || f.unmangled_name == "do_inspect"
          }
        }
        || stmts_any_expr(f.body, expr_is_inspect)
      let eq_vars = case dict.get(ctx.fn_eq_bounds, f.name) {
        Ok(vars) -> vars
        Error(_) -> collect_dict_key_vars(f.params, f.return_type)
      }
      let to_dynamic_vars = compute_to_dynamic_vars(f, ctx)
      let non_fn_vars =
        list.append(list.map(f.params, fn(p) { p.param_type }), [f.return_type])
        |> list.fold(set.new(), fn(acc, t) {
          collect_non_fn_type_vars(t, ctx, acc)
        })
      let #(rev_formatted, final_ctx) =
        list.fold(tps, #([], ctx), fn(acc, tp) {
          let #(parts, cur_ctx) = acc
          let has_eq = set.contains(eq_vars, tp)
          let has_inspect = needs_inspect && set.contains(non_fn_vars, tp)
          let has_to_dyn = set.contains(to_dynamic_vars, tp)
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

fn compute_to_dynamic_vars(f: IrFunction, ctx: EmitCtx) -> Set(String) {
  let local = case ctx.current_module == "gleam/dynamic/decode" {
    False -> set.new()
    True ->
      case f.unmangled_name, f.params {
        "cast", [p0, ..] -> collect_type_var_names(p0.param_type, set.new())
        "bare_index", [_, p1, ..] ->
          collect_type_var_names(p1.param_type, set.new())
        "push_path", [_, p1, ..] ->
          collect_type_var_names(p1.param_type, set.new())
        "subfield", [p0, ..]
        | "at", [p0, ..]
        | "index", [p0, ..]
        | "field", [p0, ..]
        | "optional_field", [p0, ..]
        | "optionally_at", [p0, ..]
        -> collect_type_var_names(p0.param_type, set.new())
        _, _ -> set.new()
      }
  }
  let base_env = build_initial_env(f, ctx)
  collect_stmts_to_dynamic(f.body, base_env, local)
}

fn collect_stmts_to_dynamic(
  stmts: List(IrStmt),
  env: dict.Dict(String, IrType),
  acc: Set(String),
) -> Set(String) {
  case stmts {
    [] -> acc
    [stmt, ..rest] ->
      case stmt {
        IrStmtLet(value:, ..) -> {
          let acc1 = collect_expr_to_dynamic(value, env, acc)
          collect_stmts_to_dynamic(rest, env, acc1)
        }
        IrStmtGuard(
          value:,
          guard_condition:,
          abort_message:,
          post_bindings:,
          ..,
        ) -> {
          let acc1 = collect_expr_to_dynamic(value, env, acc)
          let acc2 = case guard_condition {
            Some(g) -> collect_expr_to_dynamic(g, env, acc1)
            None -> acc1
          }
          let acc3 = case abort_message {
            Some(m) -> collect_expr_to_dynamic(m, env, acc2)
            None -> acc2
          }
          let acc4 =
            list.fold(post_bindings, acc3, fn(a, b) {
              collect_expr_to_dynamic(b.1, env, a)
            })
          collect_stmts_to_dynamic(rest, env, acc4)
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let acc1 = collect_expr_to_dynamic(condition, env, acc)
          let acc2 = case abort_message {
            Some(m) -> collect_expr_to_dynamic(m, env, acc1)
            None -> acc1
          }
          collect_stmts_to_dynamic(rest, env, acc2)
        }
        IrStmtExpr(expr) ->
          collect_stmts_to_dynamic(
            rest,
            env,
            collect_expr_to_dynamic(expr, env, acc),
          )
      }
  }
}

fn collect_expr_to_dynamic(
  expr: IrExpr,
  env: dict.Dict(String, IrType),
  acc: Set(String),
) -> Set(String) {
  case expr {
    IrCall(
      function: IrModuleRef(target_module: "gleam/dynamic/decode", symbol:, ..),
      args:,
    ) -> {
      let acc1 = case symbol, args {
        "subfield", [arg0, ..]
        | "at", [arg0, ..]
        | "field", [arg0, ..]
        | "optional_field", [arg0, ..]
        | "optionally_at", [arg0, ..]
        ->
          case infer_simple_expr_type(arg0.value, env) {
            Some(ty) -> collect_type_var_names(ty, acc)
            None -> acc
          }
        _, _ -> acc
      }
      list.fold(args, acc1, fn(a, arg) {
        collect_expr_to_dynamic(arg.value, env, a)
      })
    }
    IrCall(function:, args:) -> {
      let acc1 = collect_expr_to_dynamic(function, env, acc)
      list.fold(args, acc1, fn(a, arg) {
        collect_expr_to_dynamic(arg.value, env, a)
      })
    }
    IrBlock(stmts) | IrFn(body: stmts, ..) ->
      collect_stmts_to_dynamic(stmts, env, acc)
    IrMatch(subjects:, clauses:) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) { collect_expr_to_dynamic(s, env, a) })
      list.fold(clauses, acc1, fn(a, c) {
        let a1 = case c.guard {
          Some(g) -> collect_expr_to_dynamic(g, env, a)
          None -> a
        }
        let a2 =
          list.fold(c.prefix_bindings, a1, fn(x, b) {
            collect_expr_to_dynamic(b.1, env, x)
          })
        collect_expr_to_dynamic(c.body, env, a2)
      })
    }
    IrBinOp(left:, right:, ..) ->
      collect_expr_to_dynamic(
        right,
        env,
        collect_expr_to_dynamic(left, env, acc),
      )
    IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrBreak(inner)
    | IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..) -> collect_expr_to_dynamic(inner, env, acc)
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, acc, fn(a, e) { collect_expr_to_dynamic(e, env, a) })
    IrList(elements:, tail:) -> {
      let acc1 =
        list.fold(elements, acc, fn(a, e) { collect_expr_to_dynamic(e, env, a) })
      case tail {
        Some(t) -> collect_expr_to_dynamic(t, env, acc1)
        None -> acc1
      }
    }
    IrForLoop(bindings:, body:) -> {
      let acc1 =
        list.fold(bindings, acc, fn(a, b) {
          collect_expr_to_dynamic(b.1, env, a)
        })
      collect_stmts_to_dynamic(body, env, acc1)
    }
    IrEcho(expr: inner, message:, ..) -> {
      let acc1 = collect_expr_to_dynamic(inner, env, acc)
      case message {
        Some(m) -> collect_expr_to_dynamic(m, env, acc1)
        None -> acc1
      }
    }
    IrAbort(message: Some(m), ..) -> collect_expr_to_dynamic(m, env, acc)
    _ -> acc
  }
}

fn infer_simple_expr_type(
  expr: IrExpr,
  env: dict.Dict(String, IrType),
) -> Option(IrType) {
  case expr {
    IrVar(name) -> dict.get(env, name) |> option.from_result
    IrList(elements: [first, ..], ..) ->
      option.map(infer_simple_expr_type(first, env), IrTypeList)
    IrList(tail: Some(t), ..) -> infer_simple_expr_type(t, env)
    _ -> None
  }
}

fn build_initial_env(f: IrFunction, ctx: EmitCtx) -> dict.Dict(String, IrType) {
  let _ = ctx
  list.fold(f.params, dict.new(), fn(acc, p) {
    dict.insert(acc, p.name, p.param_type)
  })
}

fn compute_module_eq_bounds(
  module: IrModule,
  ctx: EmitCtx,
) -> dict.Dict(String, Set(String)) {
  let fn_map =
    list.fold(module.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, f)
    })
  let const_env =
    list.fold(module.constants, dict.new(), fn(acc, c) {
      dict.insert(acc, c.name, c.value_type)
    })
  let initial_bounds =
    list.fold(module.functions, dict.new(), fn(acc, f) {
      let sig_keys = collect_dict_key_vars(f.params, f.return_type)
      dict.insert(acc, f.name, sig_keys)
    })
  iterate_eq_bounds(module.functions, fn_map, const_env, ctx, initial_bounds, 6)
}

fn iterate_eq_bounds(
  fns: List(IrFunction),
  fn_map: dict.Dict(String, IrFunction),
  const_env: dict.Dict(String, IrType),
  ctx: EmitCtx,
  cur_bounds: dict.Dict(String, Set(String)),
  iters_left: Int,
) -> dict.Dict(String, Set(String)) {
  case iters_left <= 0 {
    True -> cur_bounds
    False -> {
      let #(next_bounds, changed) =
        list.fold(fns, #(cur_bounds, False), fn(acc, f) {
          let #(bmap, ch) = acc
          let existing = case dict.get(bmap, f.name) {
            Ok(s) -> s
            Error(_) -> set.new()
          }
          let env0 =
            list.fold(f.params, const_env, fn(e, p) {
              dict.insert(e, p.name, p.param_type)
            })
          let dict_vals = collect_dict_val_only_vars(f.params, f.return_type)
          let allowed = set.difference(set.from_list(f.type_params), dict_vals)
          let computed =
            collect_stmts_eq_vars(
              f.body,
              env0,
              fn_map,
              bmap,
              ctx,
              allowed,
              existing,
            )
          let final_set =
            set.intersection(computed, set.from_list(f.type_params))
          let grew = set.size(final_set) > set.size(existing)
          #(dict.insert(bmap, f.name, final_set), ch || grew)
        })
      case changed {
        True ->
          iterate_eq_bounds(
            fns,
            fn_map,
            const_env,
            ctx,
            next_bounds,
            iters_left - 1,
          )
        False -> next_bounds
      }
    }
  }
}

fn collect_stmts_eq_vars(
  stmts: List(IrStmt),
  env: dict.Dict(String, IrType),
  fn_map: dict.Dict(String, IrFunction),
  bounds_map: dict.Dict(String, Set(String)),
  ctx: EmitCtx,
  allowed: Set(String),
  acc: Set(String),
) -> Set(String) {
  case stmts {
    [] -> acc
    [stmt, ..rest] ->
      case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let acc1 =
            collect_expr_eq_vars(
              value,
              env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              acc,
            )
          let val_ty = case annotation {
            Some(t) -> Some(t)
            None -> infer_expr_type(value, env, fn_map, ctx)
          }
          let env1 = case val_ty {
            Some(ty) -> bind_pattern_types(pattern, ty, env)
            None -> env
          }
          collect_stmts_eq_vars(
            rest,
            env1,
            fn_map,
            bounds_map,
            ctx,
            allowed,
            acc1,
          )
        }
        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) -> {
          let acc1 =
            collect_expr_eq_vars(
              value,
              env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              acc,
            )
          let env1 = case infer_expr_type(value, env, fn_map, ctx) {
            Some(ty) -> bind_pattern_types(pattern, ty, env)
            None -> env
          }
          let env2 =
            list.fold(post_bindings, env1, fn(e, b) {
              case infer_expr_type(b.1, e, fn_map, ctx) {
                Some(ty) -> dict.insert(e, b.0, ty)
                None -> e
              }
            })
          let acc2 = case guard_condition {
            Some(g) ->
              collect_expr_eq_vars(
                g,
                env2,
                fn_map,
                bounds_map,
                ctx,
                allowed,
                acc1,
              )
            None -> acc1
          }
          let acc3 = case abort_message {
            Some(m) ->
              collect_expr_eq_vars(
                m,
                env2,
                fn_map,
                bounds_map,
                ctx,
                allowed,
                acc2,
              )
            None -> acc2
          }
          let acc4 =
            list.fold(post_bindings, acc3, fn(a, b) {
              collect_expr_eq_vars(
                b.1,
                env1,
                fn_map,
                bounds_map,
                ctx,
                allowed,
                a,
              )
            })
          collect_stmts_eq_vars(
            rest,
            env2,
            fn_map,
            bounds_map,
            ctx,
            allowed,
            acc4,
          )
        }
        IrStmtAssert(condition:, abort_message:) -> {
          let acc1 =
            collect_expr_eq_vars(
              condition,
              env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              acc,
            )
          let acc2 = case abort_message {
            Some(m) ->
              collect_expr_eq_vars(
                m,
                env,
                fn_map,
                bounds_map,
                ctx,
                allowed,
                acc1,
              )
            None -> acc1
          }
          collect_stmts_eq_vars(
            rest,
            env,
            fn_map,
            bounds_map,
            ctx,
            allowed,
            acc2,
          )
        }
        IrStmtExpr(expr) -> {
          let acc1 =
            collect_expr_eq_vars(
              expr,
              env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              acc,
            )
          collect_stmts_eq_vars(
            rest,
            env,
            fn_map,
            bounds_map,
            ctx,
            allowed,
            acc1,
          )
        }
      }
  }
}

fn collect_expr_eq_vars(
  expr: IrExpr,
  env: dict.Dict(String, IrType),
  fn_map: dict.Dict(String, IrFunction),
  bounds_map: dict.Dict(String, Set(String)),
  ctx: EmitCtx,
  allowed: Set(String),
  acc: Set(String),
) -> Set(String) {
  case expr {
    IrBinOp(op: IrEq, left:, right:) | IrBinOp(op: IrNotEq, left:, right:) -> {
      let acc_children =
        collect_expr_eq_vars(left, env, fn_map, bounds_map, ctx, allowed, acc)
        |> collect_expr_eq_vars(right, env, fn_map, bounds_map, ctx, allowed, _)
      case
        is_empty_list_or_none(left, ctx.current_module),
        is_empty_list_or_none(right, ctx.current_module)
      {
        None, None ->
          case
            infer_expr_type(left, env, fn_map, ctx),
            infer_expr_type(right, env, fn_map, ctx)
          {
            Some(ty), _ -> collect_type_var_names(ty, acc_children)
            None, Some(ty) -> collect_type_var_names(ty, acc_children)
            None, None -> set.union(acc_children, allowed)
          }
        _, _ -> acc_children
      }
    }
    IrBinOp(left:, right:, ..) ->
      collect_expr_eq_vars(left, env, fn_map, bounds_map, ctx, allowed, acc)
      |> collect_expr_eq_vars(right, env, fn_map, bounds_map, ctx, allowed, _)
    IrCall(function:, args:) -> {
      let acc1 =
        collect_expr_eq_vars(
          function,
          env,
          fn_map,
          bounds_map,
          ctx,
          allowed,
          acc,
        )
      let callee_param_types =
        resolve_callee_param_types(function, env, fn_map, ctx, args)
      let acc2 =
        propagate_call_eq_vars(
          function,
          args,
          env,
          fn_map,
          bounds_map,
          ctx,
          allowed,
          acc1,
        )
      list.index_fold(args, acc2, fn(a, arg, idx) {
        case arg.value, list_at_idx(callee_param_types, idx) {
          IrFn(params:, body:, ..), Some(IrTypeFn(params: exp_ps, ..)) -> {
            let fn_env = bind_fn_param_types(params, exp_ps, env)
            collect_stmts_eq_vars(
              body,
              fn_env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              a,
            )
          }
          _, _ ->
            collect_expr_eq_vars(
              arg.value,
              env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              a,
            )
        }
      })
    }
    IrBlock(stmts) ->
      collect_stmts_eq_vars(stmts, env, fn_map, bounds_map, ctx, allowed, acc)
    IrFn(params:, body:, ..) -> {
      let env1 =
        list.fold(params, env, fn(e, p) {
          case p.param_type {
            Some(pt) -> dict.insert(e, p.name, pt)
            None -> e
          }
        })
      collect_stmts_eq_vars(body, env1, fn_map, bounds_map, ctx, allowed, acc)
    }
    IrForLoop(bindings:, body:) -> {
      let #(acc1, env1) =
        list.fold(bindings, #(acc, env), fn(st, b) {
          let #(a, e) = st
          let a1 =
            collect_expr_eq_vars(b.1, env, fn_map, bounds_map, ctx, allowed, a)
          let e1 = case infer_expr_type(b.1, env, fn_map, ctx) {
            Some(ty) -> dict.insert(e, b.0, ty)
            None -> e
          }
          #(a1, e1)
        })
      collect_stmts_eq_vars(body, env1, fn_map, bounds_map, ctx, allowed, acc1)
    }
    IrMatch(subjects:, clauses:) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) {
          collect_expr_eq_vars(s, env, fn_map, bounds_map, ctx, allowed, a)
        })
      let subj_tys =
        list.map(subjects, fn(s) { infer_expr_type(s, env, fn_map, ctx) })
      list.fold(clauses, acc1, fn(a, c) {
        let c_env = case c.patterns {
          [first_alt, ..] ->
            list.fold(list.zip(first_alt, subj_tys), env, fn(e, pair) {
              let #(pat, maybe_ty) = pair
              case maybe_ty {
                Some(ty) -> bind_pattern_types(pat, ty, e)
                None -> e
              }
            })
          [] -> env
        }
        let c_env2 =
          list.fold(c.prefix_bindings, c_env, fn(e, b) {
            case infer_expr_type(b.1, e, fn_map, ctx) {
              Some(ty) -> dict.insert(e, b.0, ty)
              None -> e
            }
          })
        let a1 = case c.guard {
          Some(g) ->
            collect_expr_eq_vars(g, c_env2, fn_map, bounds_map, ctx, allowed, a)
          None -> a
        }
        let a2 =
          list.fold(c.prefix_bindings, a1, fn(x, b) {
            collect_expr_eq_vars(
              b.1,
              c_env,
              fn_map,
              bounds_map,
              ctx,
              allowed,
              x,
            )
          })
        collect_expr_eq_vars(
          c.body,
          c_env2,
          fn_map,
          bounds_map,
          ctx,
          allowed,
          a2,
        )
      })
    }
    IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrBreak(inner)
    | IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..) ->
      collect_expr_eq_vars(inner, env, fn_map, bounds_map, ctx, allowed, acc)
    IrTuple(els) | IrContinue(els) ->
      list.fold(els, acc, fn(a, e) {
        collect_expr_eq_vars(e, env, fn_map, bounds_map, ctx, allowed, a)
      })
    IrList(elements:, tail:) -> {
      let acc1 =
        list.fold(elements, acc, fn(a, e) {
          collect_expr_eq_vars(e, env, fn_map, bounds_map, ctx, allowed, a)
        })
      case tail {
        Some(t) ->
          collect_expr_eq_vars(t, env, fn_map, bounds_map, ctx, allowed, acc1)
        None -> acc1
      }
    }
    IrBitString(segments:) ->
      list.fold(segments, acc, fn(a, seg) {
        let a1 =
          collect_expr_eq_vars(seg.0, env, fn_map, bounds_map, ctx, allowed, a)
        list.fold(seg.1, a1, fn(inner_a, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              collect_expr_eq_vars(
                size_expr,
                env,
                fn_map,
                bounds_map,
                ctx,
                allowed,
                inner_a,
              )
            _ -> inner_a
          }
        })
      })
    IrEcho(expr: inner, message:, ..) -> {
      let acc1 =
        collect_expr_eq_vars(inner, env, fn_map, bounds_map, ctx, allowed, acc)
      case message {
        Some(m) ->
          collect_expr_eq_vars(m, env, fn_map, bounds_map, ctx, allowed, acc1)
        None -> acc1
      }
    }
    IrAbort(message: Some(m), ..) ->
      collect_expr_eq_vars(m, env, fn_map, bounds_map, ctx, allowed, acc)
    IrModuleRef(target_module: "gleam/dict", ..)
    | IrModuleRef(target_module: "gleam/set", ..) ->
      case ctx.table {
        None -> set.union(acc, allowed)
        Some(_) -> acc
      }
    _ -> acc
  }
}

fn propagate_call_eq_vars(
  function: IrExpr,
  args: List(IrCallArg),
  env: dict.Dict(String, IrType),
  fn_map: dict.Dict(String, IrFunction),
  bounds_map: dict.Dict(String, Set(String)),
  ctx: EmitCtx,
  allowed: Set(String),
  acc: Set(String),
) -> Set(String) {
  case function {
    IrVar(callee_name) ->
      case dict.get(fn_map, callee_name), dict.get(bounds_map, callee_name) {
        Ok(callee_fn), Ok(callee_eq_vars) ->
          case set.is_empty(callee_eq_vars) {
            True -> acc
            False -> {
              let param_tys = list.map(callee_fn.params, fn(p) { p.param_type })
              unify_call_eq_vars(
                param_tys,
                callee_fn.params,
                args,
                callee_eq_vars,
                env,
                fn_map,
                ctx,
                acc,
              )
            }
          }
        _, _ -> acc
      }

    IrModuleRef(target_module:, symbol:, ..) ->
      case ctx.table {
        None ->
          case target_module {
            "gleam/dict" | "gleam/set" -> set.union(acc, allowed)
            _ -> acc
          }
        Some(tbl) ->
          case lookup_table_fn_sig(tbl, target_module, symbol) {
            None -> acc
            Some(#(param_infos, ret_ty)) -> {
              let eq_vars =
                cross_module_eq_vars(target_module, symbol, param_infos, ret_ty)
              case set.is_empty(eq_vars) {
                True -> acc
                False -> {
                  let param_tys =
                    list.map(param_infos, fn(pi) { pi.param_type })
                  unify_call_eq_vars(
                    param_tys,
                    param_infos,
                    args,
                    eq_vars,
                    env,
                    fn_map,
                    ctx,
                    acc,
                  )
                }
              }
            }
          }
      }

    _ -> acc
  }
}

fn resolve_callee_param_types(
  function: IrExpr,
  env: dict.Dict(String, IrType),
  fn_map: dict.Dict(String, IrFunction),
  ctx: EmitCtx,
  args: List(IrCallArg),
) -> List(IrType) {
  let raw_params = case function {
    IrVar(callee_name) ->
      case dict.get(fn_map, callee_name) {
        Ok(callee_fn) -> Some(callee_fn.params)
        Error(_) -> None
      }
    IrModuleRef(target_module:, symbol:, ..) ->
      case ctx.table {
        Some(tbl) ->
          case lookup_table_fn_sig(tbl, target_module, symbol) {
            Some(#(param_infos, _)) -> Some(param_infos)
            None -> None
          }
        None -> None
      }
    _ -> None
  }
  case raw_params {
    None -> []
    Some(param_infos) -> {
      let ordered_args = align_ir_call_args(param_infos, args)
      let subst =
        list.fold(list.zip(param_infos, ordered_args), dict.new(), fn(s, pair) {
          let #(pi, maybe_arg) = pair
          case maybe_arg {
            Some(arg_val) ->
              case infer_expr_type(arg_val, env, fn_map, ctx) {
                Some(arg_ty) -> unify_ir_types(pi.param_type, arg_ty, s)
                None -> s
              }
            None -> s
          }
        })
      list.map(param_infos, fn(pi) { apply_ir_subst(pi.param_type, subst) })
    }
  }
}

fn align_ir_call_args(
  params: List(IrParam),
  args: List(IrCallArg),
) -> List(Option(IrExpr)) {
  let #(labelled, rev_pos) =
    list.fold(args, #(dict.new(), []), fn(st, a) {
      let #(lm, pos) = st
      case a.label {
        Some(lbl) -> #(dict.insert(lm, lbl, a.value), pos)
        None -> #(lm, [a.value, ..pos])
      }
    })
  let #(rev_out, _) =
    list.fold(params, #([], list.reverse(rev_pos)), fn(st, p) {
      let #(out, pos_q) = st
      case p.label {
        Some(lbl) ->
          case dict.get(labelled, lbl) {
            Ok(v) -> #([Some(v), ..out], pos_q)
            Error(_) ->
              case pos_q {
                [v, ..rest] -> #([Some(v), ..out], rest)
                [] -> #([None, ..out], pos_q)
              }
          }
        None ->
          case pos_q {
            [v, ..rest] -> #([Some(v), ..out], rest)
            [] -> #([None, ..out], pos_q)
          }
      }
    })
  list.reverse(rev_out)
}

fn unify_call_eq_vars(
  param_tys: List(IrType),
  param_infos: List(IrParam),
  args: List(IrCallArg),
  callee_eq_vars: Set(String),
  env: dict.Dict(String, IrType),
  fn_map: dict.Dict(String, IrFunction),
  ctx: EmitCtx,
  acc: Set(String),
) -> Set(String) {
  let _ = param_tys
  let ordered_args = align_ir_call_args(param_infos, args)
  let subst =
    list.fold(list.zip(param_infos, ordered_args), dict.new(), fn(s, pair) {
      let #(pi, maybe_arg) = pair
      case maybe_arg {
        Some(arg_val) ->
          case infer_expr_type(arg_val, env, fn_map, ctx) {
            Some(arg_ty) -> unify_ir_types(pi.param_type, arg_ty, s)
            None -> s
          }
        None -> s
      }
    })
  set.fold(callee_eq_vars, acc, fn(a, tp) {
    case dict.get(subst, tp) {
      Ok(caller_ty) -> collect_type_var_names(caller_ty, a)
      Error(_) -> a
    }
  })
}

fn cross_module_eq_vars(
  target_module: String,
  symbol: String,
  params: List(IrParam),
  ret_ty: IrType,
) -> Set(String) {
  let base = collect_dict_key_vars(params, ret_ty)
  case target_module, symbol, params {
    "gleam/list", "contains", [_, p1, ..]
    | "gleam/list", "key_find", [_, p1, ..]
    | "gleam/list", "key_filter", [_, p1, ..]
    | "gleam/list", "key_pop", [_, p1, ..]
    | "gleam/list", "key_set", [_, p1, ..]
    -> collect_type_var_names(p1.param_type, base)
    "gleam/list", "unique", [p0, ..] ->
      collect_type_var_names(p0.param_type, base)
    "gleam/list", "chunk", [_, p1, ..] ->
      case p1.param_type {
        IrTypeFn(_, k_ret) -> collect_type_var_names(k_ret, base)
        _ -> base
      }
    _, _, _ -> base
  }
}

fn lookup_table_fn_sig(
  tbl: SymbolTable,
  target_mod: String,
  symbol: String,
) -> Option(#(List(IrParam), IrType)) {
  case dict.get(tbl.modules, target_mod) {
    Error(_) -> None
    Ok(ms) -> {
      let maybe_fi = case dict.get(ms.functions, symbol) {
        Ok(fi) -> Some(fi)
        Error(_) ->
          dict.values(ms.functions)
          |> list.find(fn(fi) { mangle.mangle_ident(fi.name) == symbol })
          |> option.from_result
      }
      case maybe_fi {
        None -> None
        Some(fi) -> {
          let params =
            list.map(fi.parameters, fn(p) {
              let pt = case p.resolved_type {
                Some(rt) -> resolved_interface_to_ir(rt)
                None -> IrTypeUnit
              }
              let name = case p.name {
                glance.Named(n) -> mangle.mangle_ident(n)
                glance.Discarded(_) -> "_"
              }
              IrParam(
                label: option.map(p.label, mangle.mangle_ident),
                name:,
                param_type: pt,
              )
            })
          let ret = case fi.return_type {
            Some(rt) -> resolved_interface_to_ir(rt)
            None -> IrTypeUnit
          }
          Some(#(params, ret))
        }
      }
    }
  }
}

fn resolved_interface_to_ir(rt: ResolvedType) -> IrType {
  case rt {
    NamedType(name:, package:, module:, parameters:) -> {
      let args = list.map(parameters, resolved_interface_to_ir)
      case module, name, args {
        "gleam", "Int", [] -> IrTypeInt64
        "gleam", "Float", [] -> IrTypeDouble
        "gleam", "String", [] -> IrTypeString
        "gleam", "Bool", [] -> IrTypeBool
        "gleam", "Nil", [] -> IrTypeUnit
        "gleam", "BitArray", [] -> IrTypeBitArray
        "gleam", "List", [inner] -> IrTypeList(inner)
        "gleam", "Result", [ok_t, err_t] -> IrTypeResult(ok_t, err_t)
        _, _, _ ->
          IrTypeNamed(module_alias: None, package:, module:, name:, args:)
      }
    }
    TupleType(elements:) ->
      IrTypeTuple(list.map(elements, resolved_interface_to_ir))
    FnType(parameters:, return:) ->
      IrTypeFn(
        list.map(parameters, resolved_interface_to_ir),
        resolved_interface_to_ir(return),
      )
    VariableType(id:) -> IrTypeVar(mangle.type_var_id_to_name(id))
  }
}

fn infer_expr_type(
  expr: IrExpr,
  env: dict.Dict(String, IrType),
  fn_map: dict.Dict(String, IrFunction),
  ctx: EmitCtx,
) -> Option(IrType) {
  case expr {
    IrInt(_) -> Some(IrTypeInt64)
    IrFloat(_) -> Some(IrTypeDouble)
    IrString(_) -> Some(IrTypeString)
    IrBool(_) -> Some(IrTypeBool)
    IrUnit -> Some(IrTypeUnit)
    IrBitString(_) -> Some(IrTypeBitArray)
    IrVar(name) -> dict.get(env, name) |> option.from_result
    IrTuple(els) -> {
      let inferred =
        list.map(els, fn(e) { infer_expr_type(e, env, fn_map, ctx) })
      case list.all(inferred, option.is_some) {
        True ->
          Some(IrTypeTuple(list.filter_map(inferred, option.to_result(_, Nil))))
        False -> None
      }
    }
    IrTupleIndex(tuple:, index:) ->
      case infer_expr_type(tuple, env, fn_map, ctx) {
        Some(IrTypeTuple(els)) -> list_at_idx(els, index)
        _ -> None
      }
    IrList(elements:, tail:) ->
      case tail {
        Some(t) -> infer_expr_type(t, env, fn_map, ctx)
        None ->
          case elements {
            [first, ..] ->
              option.map(infer_expr_type(first, env, fn_map, ctx), IrTypeList)
            [] -> None
          }
      }
    IrBinOp(op:, ..) ->
      case op {
        IrEq
        | IrNotEq
        | IrAnd
        | IrOr
        | IrLtInt
        | IrLtEqInt
        | IrGtInt
        | IrGtEqInt
        | IrLtFloat
        | IrLtEqFloat
        | IrGtFloat
        | IrGtEqFloat -> Some(IrTypeBool)
        IrStringConcat -> Some(IrTypeString)
        IrAddInt | IrSubInt | IrMultInt | IrDivInt | IrRemInt ->
          Some(IrTypeInt64)
        IrAddFloat | IrSubFloat | IrMultFloat | IrDivFloat -> Some(IrTypeDouble)
      }
    IrNegateBool(_) -> Some(IrTypeBool)
    IrNegateInt(_) -> Some(IrTypeInt64)
    IrCall(function:, args:) -> {
      let sig = case function {
        IrVar(name) ->
          case dict.get(fn_map, name) {
            Ok(callee) -> Some(#(callee.params, callee.return_type))
            Error(_) -> None
          }
        IrModuleRef(target_module:, symbol:, ..) ->
          case ctx.table {
            Some(tbl) -> lookup_table_fn_sig(tbl, target_module, symbol)
            None -> None
          }
        _ -> None
      }
      case sig {
        Some(#(param_infos, ret_ty)) -> {
          let ordered_args = align_ir_call_args(param_infos, args)
          let subst =
            list.fold(
              list.zip(param_infos, ordered_args),
              dict.new(),
              fn(s, pair) {
                let #(pi, maybe_arg) = pair
                case maybe_arg {
                  Some(arg_val) ->
                    case infer_expr_type(arg_val, env, fn_map, ctx) {
                      Some(arg_ty) -> unify_ir_types(pi.param_type, arg_ty, s)
                      None -> s
                    }
                  None -> s
                }
              },
            )
          Some(apply_call_ret_subst(ret_ty, subst))
        }
        None -> None
      }
    }
    IrBlock(stmts) ->
      case list.last(stmts) {
        Ok(IrStmtExpr(e)) -> infer_expr_type(e, env, fn_map, ctx)
        _ -> None
      }
    IrEcho(expr: inner, ..) -> infer_expr_type(inner, env, fn_map, ctx)
    _ -> None
  }
}

fn bind_pattern_types(
  pat: IrPattern,
  ty: IrType,
  env: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case pat, ty {
    IrPatVar(name), _ -> dict.insert(env, name, ty)
    IrPatAs(inner, alias), _ ->
      bind_pattern_types(inner, ty, dict.insert(env, alias, ty))
    IrPatTuple(pats), IrTypeTuple(tys) ->
      list.fold(list.zip(pats, tys), env, fn(e, pair) {
        bind_pattern_types(pair.0, pair.1, e)
      })
    IrPatVariant(constructor: "Cons", args: [h_arg, t_arg], ..),
      IrTypeList(inner)
    ->
      env
      |> bind_pattern_types(h_arg.pattern, inner, _)
      |> bind_pattern_types(t_arg.pattern, IrTypeList(inner), _)
    IrPatVariant(constructor: "Ok", args: [ok_arg], ..), IrTypeResult(ok_t, _)
    -> bind_pattern_types(ok_arg.pattern, ok_t, env)
    IrPatVariant(constructor: "Err", args: [err_arg], ..),
      IrTypeResult(_, err_t)
    -> bind_pattern_types(err_arg.pattern, err_t, env)
    IrPatVariant(constructor: "Some", args: [some_arg], ..),
      IrTypeNamed(module: "gleam/option", name: "Option", args: [inner], ..)
    -> bind_pattern_types(some_arg.pattern, inner, env)
    _, _ -> env
  }
}

fn bind_fn_param_types(
  params: List(IrFnParam),
  expected: List(IrType),
  env: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  list.fold(list.zip(params, expected), env, fn(e, pair) {
    let #(p, exp_ty) = pair
    let final_ty = option.unwrap(p.param_type, exp_ty)
    dict.insert(e, p.name, final_ty)
  })
}

fn unify_ir_types(
  pattern_ty: IrType,
  concrete_ty: IrType,
  subst: dict.Dict(String, IrType),
) -> dict.Dict(String, IrType) {
  case pattern_ty, concrete_ty {
    IrTypeVar(v), _ ->
      case string.starts_with(v, "__free") {
        True -> subst
        False ->
          case concrete_ty {
            IrTypeVar(cv) ->
              case string.starts_with(cv, "__free") {
                True -> subst
                False ->
                  case dict.has_key(subst, v) {
                    True -> subst
                    False -> dict.insert(subst, v, concrete_ty)
                  }
              }
            _ ->
              case dict.has_key(subst, v) {
                True -> subst
                False -> dict.insert(subst, v, concrete_ty)
              }
          }
      }
    IrTypeList(p_in), IrTypeList(c_in) -> unify_ir_types(p_in, c_in, subst)
    IrTypeResult(po, pe), IrTypeResult(co, ce) ->
      unify_ir_types(pe, ce, unify_ir_types(po, co, subst))
    IrTypeTuple(ps), IrTypeTuple(cs) ->
      list.fold(list.zip(ps, cs), subst, fn(s, pair) {
        unify_ir_types(pair.0, pair.1, s)
      })
    IrTypeFn(pp, pr), IrTypeFn(cp, cr) -> {
      let s1 =
        list.fold(list.zip(pp, cp), subst, fn(s, pair) {
          unify_ir_types(pair.0, pair.1, s)
        })
      unify_ir_types(pr, cr, s1)
    }
    IrTypeNamed(module: pm, name: pn, args: pas, ..),
      IrTypeNamed(module: cm, name: cn, args: cas, ..)
      if pm == cm && pn == cn
    ->
      list.fold(list.zip(pas, cas), subst, fn(s, pair) {
        unify_ir_types(pair.0, pair.1, s)
      })
    _, _ -> subst
  }
}

fn apply_call_ret_subst(
  ty: IrType,
  subst: dict.Dict(String, IrType),
) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(t) -> t
        Error(_) ->
          case string.starts_with(v, "__free") {
            True -> ty
            False -> IrTypeVar("__free_" <> v)
          }
      }
    IrTypeList(inner) -> IrTypeList(apply_call_ret_subst(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        apply_call_ret_subst(ok_t, subst),
        apply_call_ret_subst(err_t, subst),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(list.map(els, apply_call_ret_subst(_, subst)))
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, apply_call_ret_subst(_, subst)),
        apply_call_ret_subst(r, subst),
      )
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, apply_call_ret_subst(_, subst)))
    _ -> ty
  }
}

fn apply_ir_subst(ty: IrType, subst: dict.Dict(String, IrType)) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(t) -> t
        Error(_) -> ty
      }
    IrTypeList(inner) -> IrTypeList(apply_ir_subst(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(apply_ir_subst(ok_t, subst), apply_ir_subst(err_t, subst))
    IrTypeTuple(els) -> IrTypeTuple(list.map(els, apply_ir_subst(_, subst)))
    IrTypeFn(ps, r) ->
      IrTypeFn(list.map(ps, apply_ir_subst(_, subst)), apply_ir_subst(r, subst))
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, apply_ir_subst(_, subst)))
    _ -> ty
  }
}

fn collect_type_var_names(ty: IrType, acc: Set(String)) -> Set(String) {
  case ty {
    IrTypeVar(v) -> set.insert(acc, v)
    IrTypeList(inner) -> collect_type_var_names(inner, acc)
    IrTypeResult(ok_t, err_t) ->
      collect_type_var_names(err_t, collect_type_var_names(ok_t, acc))
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) { collect_type_var_names(e, s) })
    IrTypeFn(ps, r) ->
      collect_type_var_names(
        r,
        list.fold(ps, acc, fn(s, p) { collect_type_var_names(p, s) }),
      )
    IrTypeNamed(args:, ..) ->
      list.fold(args, acc, fn(s, a) { collect_type_var_names(a, s) })
    _ -> acc
  }
}

fn list_at_idx(items: List(a), index: Int) -> Option(a) {
  case items, index {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], i if i > 0 -> list_at_idx(tail, i - 1)
    _, _ -> None
  }
}

fn collect_dict_key_vars(params: List(IrParam), ret: IrType) -> Set(String) {
  let all = list.append(list.map(params, fn(p) { p.param_type }), [ret])
  list.fold(all, set.new(), fn(acc, t) { walk_type_dict_keys(t, acc) })
}

fn walk_type_dict_keys(ty: IrType, acc: Set(String)) -> Set(String) {
  case ty {
    IrTypeNamed(module: "gleam/dict", name: "Dict", args: [k_ty, v_ty], ..)
    | IrTypeNamed(
        module: "gleam/dict",
        name: "TransientDict",
        args: [k_ty, v_ty],
        ..,
      ) -> {
      let with_k = collect_type_var_names(k_ty, acc)
      walk_type_dict_keys(v_ty, with_k)
    }
    IrTypeNamed(module: "gleam/set", name: "Set", args: [m_ty], ..) ->
      collect_type_var_names(m_ty, acc)
    IrTypeList(inner) -> walk_type_dict_keys(inner, acc)
    IrTypeResult(ok_t, err_t) ->
      walk_type_dict_keys(err_t, walk_type_dict_keys(ok_t, acc))
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) { walk_type_dict_keys(e, s) })
    IrTypeFn(ps, r) ->
      walk_type_dict_keys(
        r,
        list.fold(ps, acc, fn(s, p) { walk_type_dict_keys(p, s) }),
      )
    IrTypeNamed(args:, ..) ->
      list.fold(args, acc, fn(s, a) { walk_type_dict_keys(a, s) })
    _ -> acc
  }
}

fn collect_dict_val_only_vars(
  params: List(IrParam),
  ret: IrType,
) -> Set(String) {
  let all = list.append(list.map(params, fn(p) { p.param_type }), [ret])
  let #(dict_vals, non_dict_vals) =
    list.fold(all, #(set.new(), set.new()), fn(acc, t) {
      walk_type_val_vars(t, acc.0, acc.1)
    })
  set.difference(dict_vals, non_dict_vals)
}

fn walk_type_val_vars(
  ty: IrType,
  dict_vals: Set(String),
  other_vars: Set(String),
) -> #(Set(String), Set(String)) {
  case ty {
    IrTypeNamed(module: "gleam/dict", name: "Dict", args: [k_ty, v_ty], ..)
    | IrTypeNamed(
        module: "gleam/dict",
        name: "TransientDict",
        args: [k_ty, v_ty],
        ..,
      ) -> {
      let #(dv1, ov1) = walk_type_val_vars(k_ty, dict_vals, other_vars)
      case v_ty {
        IrTypeVar(v) -> #(set.insert(dv1, v), ov1)
        _ -> walk_type_val_vars(v_ty, dv1, ov1)
      }
    }
    IrTypeVar(v) -> #(dict_vals, set.insert(other_vars, v))
    IrTypeList(inner) -> walk_type_val_vars(inner, dict_vals, other_vars)
    IrTypeResult(ok_t, err_t) -> {
      let #(dv1, ov1) = walk_type_val_vars(ok_t, dict_vals, other_vars)
      walk_type_val_vars(err_t, dv1, ov1)
    }
    IrTypeTuple(els) ->
      list.fold(els, #(dict_vals, other_vars), fn(acc, e) {
        walk_type_val_vars(e, acc.0, acc.1)
      })
    IrTypeFn(ps, r) -> {
      let #(dv1, ov1) =
        list.fold(ps, #(dict_vals, other_vars), fn(acc, p) {
          walk_type_val_vars(p, acc.0, acc.1)
        })
      walk_type_val_vars(r, dv1, ov1)
    }
    IrTypeNamed(args:, ..) ->
      list.fold(args, #(dict_vals, other_vars), fn(acc, a) {
        walk_type_val_vars(a, acc.0, acc.1)
      })
    _ -> #(dict_vals, other_vars)
  }
}

fn stmts_any_expr(stmts: List(IrStmt), pred: fn(IrExpr) -> Bool) -> Bool {
  list.any(stmts, fn(s) { stmt_any_expr(s, pred) })
}

fn stmt_any_expr(stmt: IrStmt, pred: fn(IrExpr) -> Bool) -> Bool {
  case stmt {
    IrStmtLet(value:, ..) -> expr_any(value, pred)
    IrStmtGuard(value:, guard_condition:, abort_message:, post_bindings:, ..) ->
      expr_any(value, pred)
      || option.map(guard_condition, fn(e) { expr_any(e, pred) }) == Some(True)
      || option.map(abort_message, fn(e) { expr_any(e, pred) }) == Some(True)
      || list.any(post_bindings, fn(b) { expr_any(b.1, pred) })
    IrStmtAssert(condition:, abort_message:) ->
      expr_any(condition, pred)
      || option.map(abort_message, fn(e) { expr_any(e, pred) }) == Some(True)
    IrStmtExpr(expr) -> expr_any(expr, pred)
  }
}

fn expr_any(expr: IrExpr, pred: fn(IrExpr) -> Bool) -> Bool {
  case pred(expr) {
    True -> True
    False ->
      case expr {
        IrBinOp(left:, right:, ..) ->
          expr_any(left, pred) || expr_any(right, pred)
        IrNegateInt(inner) | IrNegateBool(inner) | IrBreak(inner) ->
          expr_any(inner, pred)
        IrTuple(els) | IrContinue(els) ->
          list.any(els, fn(e) { expr_any(e, pred) })
        IrTupleIndex(tuple:, ..) -> expr_any(tuple, pred)
        IrList(elements:, tail:) ->
          list.any(elements, fn(e) { expr_any(e, pred) })
          || option.map(tail, fn(e) { expr_any(e, pred) }) == Some(True)
        IrBitString(segments:) ->
          list.any(segments, fn(s) {
            expr_any(s.0, pred)
            || list.any(s.1, fn(opt) {
              case opt {
                glance.SizeValueOption(size_expr) -> expr_any(size_expr, pred)
                _ -> False
              }
            })
          })
        IrCall(function:, args:) ->
          expr_any(function, pred)
          || list.any(args, fn(a) { expr_any(a.value, pred) })
        IrGetterCall(receiver:, ..) -> expr_any(receiver, pred)
        IrBlock(stmts) | IrFn(body: stmts, ..) -> stmts_any_expr(stmts, pred)
        IrForLoop(bindings:, body:) ->
          list.any(bindings, fn(b) { expr_any(b.1, pred) })
          || stmts_any_expr(body, pred)
        IrMatch(subjects:, clauses:) ->
          list.any(subjects, fn(e) { expr_any(e, pred) })
          || list.any(clauses, fn(c) {
            expr_any(c.body, pred)
            || option.map(c.guard, fn(e) { expr_any(e, pred) }) == Some(True)
            || list.any(c.prefix_bindings, fn(b) { expr_any(b.1, pred) })
          })
        IrEcho(expr: inner, message:, ..) ->
          expr_any(inner, pred)
          || option.map(message, fn(e) { expr_any(e, pred) }) == Some(True)
        IrAbort(message:, ..) ->
          option.map(message, fn(e) { expr_any(e, pred) }) == Some(True)
        _ -> False
      }
  }
}

fn expr_is_inspect(expr: IrExpr) -> Bool {
  case expr {
    IrEcho(_, _, _, _) -> True
    IrModuleRef(target_module: "gleam/string", symbol: "inspect", ..) -> True
    _ -> False
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
  // Replace unescaped `\{` interpolation sequence and raw CR/LF inside multiline strings
  raw
  |> string.replace("\\{", "\\\\{")
  |> string.replace("\r", "\\r")
  |> string.replace("\n", "\\n")
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

fn collect_td_dict_key_vars(td: IrTypeDef) -> Set(String) {
  let used =
    list.fold(td.variants, set.new(), fn(acc, v) {
      list.fold(v.fields, acc, fn(inner, f) {
        walk_type_dict_keys(f.field_type, inner)
      })
    })
  set.intersection(used, set.from_list(td.type_params))
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

fn is_alias_referenced_in_module(module: IrModule, alias_name: String) -> Bool {
  let in_types =
    list.any(module.types, fn(td) {
      td.external_type == None
      && list.any(td.variants, fn(v) {
        list.any(v.fields, fn(f) {
          type_uses_local_name(f.field_type, alias_name)
        })
      })
    })
  let in_aliases =
    list.any(module.type_aliases, fn(ta) {
      ta.publicity == glance.Public
      && type_uses_local_name(ta.aliased, alias_name)
    })
  let in_getters =
    list.any(module.getters, fn(g) {
      type_uses_local_name(g.return_type, alias_name)
    })
  let in_consts =
    list.any(module.constants, fn(c) {
      type_uses_local_name(c.value_type, alias_name)
    })
  let in_fns =
    list.any(module.functions, fn(f) {
      list.any(f.params, fn(p) {
        type_uses_local_name(p.param_type, alias_name)
      })
      || type_uses_local_name(f.return_type, alias_name)
      || stmts_use_local_type(f.body, alias_name)
    })
  in_types || in_aliases || in_getters || in_consts || in_fns
}

fn type_uses_local_name(ty: IrType, alias_name: String) -> Bool {
  case ty {
    IrTypeNamed(module: "", name:, args:, ..) ->
      name == alias_name || list.any(args, type_uses_local_name(_, alias_name))
    IrTypeNamed(args:, ..) ->
      list.any(args, type_uses_local_name(_, alias_name))
    IrTypeList(inner) -> type_uses_local_name(inner, alias_name)
    IrTypeResult(ok_t, err_t) ->
      type_uses_local_name(ok_t, alias_name)
      || type_uses_local_name(err_t, alias_name)
    IrTypeTuple(els) -> list.any(els, type_uses_local_name(_, alias_name))
    IrTypeFn(ps, r) ->
      list.any(ps, type_uses_local_name(_, alias_name))
      || type_uses_local_name(r, alias_name)
    _ -> False
  }
}

fn stmts_use_local_type(stmts: List(IrStmt), alias_name: String) -> Bool {
  list.any(stmts, fn(s) {
    case s {
      IrStmtLet(annotation: Some(ann), value:, ..) ->
        type_uses_local_name(ann, alias_name)
        || expr_uses_local_type(value, alias_name)
      IrStmtLet(value:, ..) -> expr_uses_local_type(value, alias_name)
      IrStmtGuard(value:, guard_condition:, abort_message:, post_bindings:, ..) ->
        expr_uses_local_type(value, alias_name)
        || option.map(guard_condition, expr_uses_local_type(_, alias_name))
        == Some(True)
        || option.map(abort_message, expr_uses_local_type(_, alias_name))
        == Some(True)
        || list.any(post_bindings, fn(b) {
          expr_uses_local_type(b.1, alias_name)
        })
      IrStmtAssert(condition:, abort_message:) ->
        expr_uses_local_type(condition, alias_name)
        || option.map(abort_message, expr_uses_local_type(_, alias_name))
        == Some(True)
      IrStmtExpr(expr) -> expr_uses_local_type(expr, alias_name)
    }
  })
}

fn expr_uses_local_type(expr: IrExpr, alias_name: String) -> Bool {
  case expr {
    IrFn(params:, return_type:, body:) ->
      list.any(params, fn(p) {
        option.map(p.param_type, type_uses_local_name(_, alias_name))
        == Some(True)
      })
      || option.map(return_type, type_uses_local_name(_, alias_name))
      == Some(True)
      || stmts_use_local_type(body, alias_name)
    IrBlock(stmts) -> stmts_use_local_type(stmts, alias_name)
    IrForLoop(bindings:, body:) ->
      list.any(bindings, fn(b) { expr_uses_local_type(b.1, alias_name) })
      || stmts_use_local_type(body, alias_name)
    IrBinOp(left:, right:, ..) ->
      expr_uses_local_type(left, alias_name)
      || expr_uses_local_type(right, alias_name)
    IrNegateInt(i) | IrNegateBool(i) | IrBreak(i) ->
      expr_uses_local_type(i, alias_name)
    IrTuple(els) | IrContinue(els) ->
      list.any(els, expr_uses_local_type(_, alias_name))
    IrTupleIndex(tuple:, ..) -> expr_uses_local_type(tuple, alias_name)
    IrList(elements:, tail:) ->
      list.any(elements, expr_uses_local_type(_, alias_name))
      || option.map(tail, expr_uses_local_type(_, alias_name)) == Some(True)
    IrCall(function:, args:) ->
      expr_uses_local_type(function, alias_name)
      || list.any(args, fn(a) { expr_uses_local_type(a.value, alias_name) })
    IrMatch(subjects:, clauses:) ->
      list.any(subjects, expr_uses_local_type(_, alias_name))
      || list.any(clauses, fn(c) { expr_uses_local_type(c.body, alias_name) })
    _ -> False
  }
}
