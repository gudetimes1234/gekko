import glance
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{
  type FunctionInfo, type ModuleSymbols, type SymbolTable, type TypeInfo,
}
import lower/ir.{
  type IrBinOp, type IrCallArg, type IrClause, type IrConstant, type IrExpr,
  type IrFnParam, type IrFunction, type IrGetter, type IrModule, type IrParam,
  type IrStmt, type IrType, type IrTypeDef, IrAbort, IrAddFloat, IrAddInt, IrAnd,
  IrBinOp, IrBitString, IrBlock, IrBool, IrCall, IrCallArg, IrClause, IrConstant,
  IrConstructor, IrDivFloat, IrDivInt, IrEcho, IrEq, IrFloat, IrFn, IrFnParam,
  IrFunction, IrGetter, IrGetterCall, IrGtEqFloat, IrGtEqInt, IrGtFloat, IrGtInt,
  IrImport, IrInt, IrList, IrLtEqFloat, IrLtEqInt, IrLtFloat, IrLtInt, IrMatch,
  IrModule, IrModuleRef, IrMultFloat, IrMultInt, IrNegateBool, IrNegateInt,
  IrNotEq, IrOr, IrParam, IrPatArg, IrPatDiscard, IrPatTuple, IrPatVar,
  IrPatVariant, IrRemInt, IrStmtAssert, IrStmtExpr, IrStmtGuard, IrStmtLet,
  IrString, IrStringConcat, IrSubFloat, IrSubInt, IrTuple, IrTupleIndex,
  IrTypeAlias, IrTypeBitArray, IrTypeBool, IrTypeDef, IrTypeDouble, IrTypeFn,
  IrTypeInt64, IrTypeList, IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple,
  IrTypeUnit, IrTypeVar, IrUnit, IrVar, IrVariant, IrVariantField, PanicAbort,
  TodoAbort,
}
import lower/ir_util
import lower/mangle
import lower/pattern
import project/interface.{
  type ResolvedType, FnType, NamedType, TupleType, VariableType,
}
import project/prepass.{ExternalType}

type LowerCtx {
  LowerCtx(
    table: SymbolTable,
    current_module: String,
    mod_syms: ModuleSymbols,
    local_vars: Set(String),
    local_var_types: dict.Dict(String, IrType),
    ast_type_vars: dict.Dict(String, String),
    next_id: Int,
  )
}

/// Lower a parsed `glance.Module` using `SymbolTable` metadata into `IrModule`.
pub fn desugar_module(
  ast_mod: glance.Module,
  table: SymbolTable,
  module_name: String,
) -> IrModule {
  let mod_syms = case dict.get(table.modules, module_name) {
    Ok(ms) -> ms
    Error(_) -> symbol_table.empty_module_symbols(module_name)
  }

  let imports =
    mod_syms.imports
    |> list.reverse
    |> list.map(fn(imp) { IrImport(module: imp.module, alias: imp.alias) })

  let custom_types =
    ast_mod.custom_types
    |> list.reverse
    |> list.filter(fn(def) { !symbol_table.is_excluded_target(def.attributes) })
  let ast_type_aliases =
    ast_mod.type_aliases
    |> list.reverse
    |> list.filter(fn(def) { !symbol_table.is_excluded_target(def.attributes) })
  let ast_constants =
    ast_mod.constants
    |> list.reverse
    |> list.filter(fn(def) { !symbol_table.is_excluded_target(def.attributes) })
  let reachable_fns =
    symbol_table.reachable_private_functions(ast_mod, mod_syms.functions)
  let ast_functions =
    ast_mod.functions
    |> list.reverse
    |> list.filter(fn(def) {
      !symbol_table.is_excluded_target(def.attributes)
      && set.contains(reachable_fns, def.definition.name)
    })

  let types =
    list.filter_map(custom_types, fn(def) {
      let ct = def.definition
      case dict.get(mod_syms.types, ct.name) {
        Ok(type_info) -> Ok(lower_type_def(type_info, mod_syms, table))
        Error(_) -> Error(Nil)
      }
    })

  let type_aliases =
    list.map(ast_type_aliases, fn(def) {
      let ta = def.definition
      let type_params = list.map(ta.parameters, mangle.mangle_type_param)
      IrTypeAlias(
        name: mangle.mangle_type_name(ta.name),
        publicity: ta.publicity,
        type_params:,
        aliased: lower_ast_type_with_table(
          ta.aliased,
          mod_syms,
          table.package_name,
          Some(table),
        ),
      )
    })

  let getters =
    list.flat_map(custom_types, fn(def) {
      let ct = def.definition
      case dict.get(mod_syms.types, ct.name) {
        Ok(type_info) -> synthesize_getters(type_info, mod_syms, table)
        Error(_) -> []
      }
    })

  let #(constants, ctx_after_consts) =
    lower_constants(
      ast_constants,
      LowerCtx(
        table:,
        current_module: module_name,
        mod_syms:,
        local_vars: set.new(),
        local_var_types: dict.new(),
        ast_type_vars: dict.new(),
        next_id: 0,
      ),
    )

  let #(functions, _) = lower_functions(ast_functions, ctx_after_consts)

  IrModule(
    module_name:,
    package_name: table.package_name,
    imports:,
    types:,
    type_aliases:,
    getters:,
    constants:,
    functions:,
  )
}

fn lower_type_def(
  type_info: TypeInfo,
  mod_syms: ModuleSymbols,
  table: SymbolTable,
) -> IrTypeDef {
  let type_params = list.map(type_info.parameters, mangle.mangle_type_param)
  let variants =
    list.map(type_info.variants, fn(variant) {
      let fields =
        list.map(variant.fields, fn(field) {
          let field_type = case field.resolved_type {
            Some(rt) ->
              resolved_type_to_ir_with_table(
                rt,
                Some(type_info.parameters),
                mod_syms,
                Some(table),
              )
            None ->
              lower_ast_type_with_table(
                field.ast_type,
                mod_syms,
                "",
                Some(table),
              )
          }
          IrVariantField(
            label: option.map(field.label, mangle.mangle_ident),
            unmangled_label: field.label,
            field_type:,
          )
        })
      IrVariant(name: variant.name, fields:)
    })

  let ir_name = case type_info.external_type {
    Some(ExternalType(package:, type_name: target))
      if { package == "" || package == "builtin" } && target == type_info.name
    -> type_info.name
    _ -> mangle.mangle_type_name(type_info.name)
  }

  IrTypeDef(
    name: ir_name,
    unmangled_name: type_info.name,
    publicity: type_info.publicity,
    opaque_: type_info.opaque_,
    type_params:,
    variants:,
    external_type: type_info.external_type,
    derive_eq_debug_hash: !type_info.has_function_field,
  )
}

fn synthesize_getters(
  type_info: TypeInfo,
  mod_syms: ModuleSymbols,
  table: SymbolTable,
) -> List(IrGetter) {
  let type_params = list.map(type_info.parameters, mangle.mangle_type_param)
  let variants =
    list.map(type_info.variants, fn(v) {
      let positional = list.count(v.fields, fn(f) { option.is_none(f.label) })
      #(v.name, positional)
    })
  type_info.shared_fields
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let #(field_name, resolved_ty) = entry
    IrGetter(
      type_name: mangle.mangle_type_name(type_info.name),
      type_params:,
      publicity: type_info.publicity,
      field_name: mangle.mangle_ident(field_name),
      return_type: resolved_type_to_ir_with_table(
        resolved_ty,
        Some(type_info.parameters),
        mod_syms,
        Some(table),
      ),
      variants:,
    )
  })
}

fn lower_constants(
  const_defs: List(glance.Definition(glance.Constant)),
  ctx: LowerCtx,
) -> #(List(IrConstant), LowerCtx) {
  let #(rev_consts, final_ctx) =
    list.fold(const_defs, #([], ctx), fn(acc, def) {
      let #(consts, cur_ctx) = acc
      let c = def.definition
      let #(value, next_ctx) = lower_expr(c.value, cur_ctx)
      let fallback_type = fn() {
        case c.annotation {
          Some(ann) ->
            lower_ast_type_with_table(
              ann,
              next_ctx.mod_syms,
              next_ctx.table.package_name,
              Some(next_ctx.table),
            )
          None -> infer_const_expr_type(value)
        }
      }
      let value_type = case dict.get(next_ctx.mod_syms.constants, c.name) {
        Ok(ci) ->
          case ci.resolved_type {
            Some(rt) ->
              resolved_type_to_ir_with_table(
                rt,
                None,
                next_ctx.mod_syms,
                Some(next_ctx.table),
              )
            None -> fallback_type()
          }
        Error(_) -> fallback_type()
      }
      let lowered =
        IrConstant(
          name: mangle.mangle_ident(c.name),
          unmangled_name: c.name,
          publicity: c.publicity,
          value_type:,
          value:,
        )
      #([lowered, ..consts], next_ctx)
    })
  #(list.reverse(rev_consts), final_ctx)
}

fn infer_const_expr_type(expr: IrExpr) -> IrType {
  case expr {
    IrInt(_) | IrNegateInt(_) -> IrTypeInt64
    IrFloat(_) -> IrTypeDouble
    IrString(_) -> IrTypeString
    IrBool(_) | IrNegateBool(_) -> IrTypeBool
    IrUnit -> IrTypeUnit
    IrBitString(_) -> IrTypeBitArray
    IrTuple(els) -> IrTypeTuple(list.map(els, infer_const_expr_type))
    IrList(elements: [first, ..], ..) ->
      IrTypeList(infer_const_expr_type(first))
    IrList(elements: [], tail: Some(t)) -> infer_const_expr_type(t)
    IrList(elements: [], tail: None) -> IrTypeList(IrTypeVar("T0"))
    IrCall(IrConstructor(_, _, "Ok"), [arg]) ->
      IrTypeResult(infer_const_expr_type(arg.value), IrTypeVar("T0"))
    IrCall(IrConstructor(_, _, "Err"), [arg]) ->
      IrTypeResult(IrTypeVar("T0"), infer_const_expr_type(arg.value))
    _ -> IrTypeVar("T0")
  }
}

fn lower_functions(
  fn_defs: List(glance.Definition(glance.Function)),
  ctx: LowerCtx,
) -> #(List(IrFunction), LowerCtx) {
  let #(rev_fns, final_ctx) =
    list.fold(fn_defs, #([], ctx), fn(acc, def) {
      let #(fns, cur_ctx) = acc
      let #(lowered_fn, next_ctx) = lower_function(def.definition, cur_ctx)
      #([lowered_fn, ..fns], next_ctx)
    })
  #(list.reverse(rev_fns), final_ctx)
}

fn lower_function(
  func: glance.Function,
  ctx: LowerCtx,
) -> #(IrFunction, LowerCtx) {
  let maybe_fn_info = dict.get(ctx.mod_syms.functions, func.name)

  let params =
    list.index_map(func.parameters, fn(param, idx) {
      let param_name = case param.name {
        glance.Named(n) -> mangle.mangle_ident(n)
        glance.Discarded(_) -> "_"
      }
      let resolved_param_type = case maybe_fn_info {
        Ok(fn_info) ->
          case list_at(fn_info.parameters, idx) {
            Some(pi) ->
              case pi.resolved_type {
                Some(rt) ->
                  Some(resolved_type_to_ir_with_table(
                    rt,
                    None,
                    ctx.mod_syms,
                    Some(ctx.table),
                  ))
                None -> None
              }
            None -> None
          }
        Error(_) -> None
      }
      let param_type = case resolved_param_type {
        Some(t) -> t
        None ->
          case param.type_ {
            Some(ast_t) ->
              lower_ast_type_with_table(
                ast_t,
                ctx.mod_syms,
                ctx.table.package_name,
                Some(ctx.table),
              )
            None -> IrTypeVar(mangle.type_var_id_to_name(idx))
          }
      }
      IrParam(
        label: option.map(param.label, mangle.mangle_ident),
        name: param_name,
        param_type:,
      )
    })

  let return_type = case maybe_fn_info {
    Ok(fn_info) ->
      case fn_info.return_type {
        Some(rt) ->
          resolved_type_to_ir_with_table(
            rt,
            None,
            ctx.mod_syms,
            Some(ctx.table),
          )
        None ->
          case func.return {
            Some(ast_t) ->
              lower_ast_type_with_table(
                ast_t,
                ctx.mod_syms,
                ctx.table.package_name,
                Some(ctx.table),
              )
            None -> IrTypeUnit
          }
      }
    Error(_) ->
      case func.return {
        Some(ast_t) ->
          lower_ast_type_with_table(
            ast_t,
            ctx.mod_syms,
            ctx.table.package_name,
            Some(ctx.table),
          )
        None -> IrTypeUnit
      }
  }

  let ffi = case maybe_fn_info {
    Ok(fn_info) -> fn_info.ffi
    Error(_) -> None
  }

  let type_params =
    ir_util.collect_type_vars_in_sig(
      list.map(params, fn(p) { p.param_type }),
      return_type,
    )

  let #(param_local_vars, param_local_types) =
    list.fold(
      list.zip(func.parameters, params),
      #(ctx.local_vars, ctx.local_var_types),
      fn(acc, pair) {
        let #(vars, types) = acc
        let #(ast_p, ir_p) = pair
        case ast_p.name {
          glance.Named(n) -> #(
            set.insert(vars, n),
            dict.insert(types, n, ir_p.param_type),
          )
          glance.Discarded(_) -> acc
        }
      },
    )

  let ast_type_vars =
    build_ast_type_var_map(
      func.parameters,
      params,
      func.return,
      return_type,
      ctx.mod_syms,
      ctx.table.package_name,
      Some(ctx.table),
    )
  let body_ctx =
    LowerCtx(
      ..ctx,
      local_vars: param_local_vars,
      local_var_types: param_local_types,
      ast_type_vars:,
    )
  let #(body, after_body_ctx) = lower_statements(func.body, body_ctx)

  let lowered =
    IrFunction(
      name: mangle.mangle_ident(func.name),
      unmangled_name: func.name,
      publicity: func.publicity,
      type_params:,
      params:,
      return_type:,
      ffi:,
      body:,
    )
  #(lowered, LowerCtx(..ctx, next_id: after_body_ctx.next_id))
}

fn lower_statements(
  stmts: List(glance.Statement),
  ctx: LowerCtx,
) -> #(List(IrStmt), LowerCtx) {
  case stmts {
    [] -> #([], ctx)
    [stmt, ..rest] ->
      case stmt {
        glance.Use(patterns:, function:, ..) -> {
          let #(lowered_call_target, ctx1) = lower_expr(function, ctx)
          let #(
            fn_params,
            preamble_stmts,
            body_local_vars,
            body_local_types,
            ctx2,
          ) = lower_use_patterns(patterns, ctx1)

          let body_ctx =
            LowerCtx(
              ..ctx2,
              local_vars: body_local_vars,
              local_var_types: body_local_types,
            )
          let #(rest_stmts, ctx3) = lower_statements(rest, body_ctx)
          let pruned_preambles = prune_use_preambles(preamble_stmts, rest_stmts)

          let closure =
            IrFn(
              params: fn_params,
              return_type: None,
              body: list.append(pruned_preambles, rest_stmts),
            )

          let combined_call = case lowered_call_target {
            IrCall(callee, existing_args) ->
              IrCall(
                callee,
                list.append(existing_args, [IrCallArg(None, closure)]),
              )
            other -> IrCall(other, [IrCallArg(None, closure)])
          }

          #([IrStmtExpr(combined_call)], LowerCtx(..ctx, next_id: ctx3.next_id))
        }

        glance.Assignment(kind:, pattern: pat, annotation:, value:, ..) -> {
          let #(lowered_val, ctx1) = lower_expr(value, ctx)
          let lp =
            pattern.lower_pattern(
              pat,
              ctx1.table,
              ctx1.current_module,
              ctx1.next_id,
            )
          let ctx2 = LowerCtx(..ctx1, next_id: lp.next_id)
          let lowered_ann =
            option.map(annotation, fn(t) {
              lower_ast_type_with_vars(
                t,
                ctx2.mod_syms,
                ctx2.table.package_name,
                ctx2.ast_type_vars,
                Some(ctx2.table),
              )
            })

          let #(lowered_msg, ctx_msg) = case kind {
            glance.LetAssert(message: Some(m)) -> {
              let #(lm, c) = lower_expr(m, ctx2)
              #(Some(lm), c)
            }
            _ -> #(None, ctx2)
          }

          let next_vars =
            list.fold(lp.bound_names, ctx_msg.local_vars, fn(vars, name) {
              set.insert(vars, name)
            })
          let cleared_types =
            list.fold(lp.bound_names, ctx_msg.local_var_types, fn(ts, name) {
              dict.delete(ts, name)
            })
          let next_types = case pat {
            glance.PatternVariable(name: var_name, ..) ->
              case lowered_ann {
                Some(ann_ty) -> dict.insert(cleared_types, var_name, ann_ty)
                None ->
                  case infer_local_expr_type(value, ctx_msg) {
                    Some(inferred_ty) ->
                      dict.insert(cleared_types, var_name, inferred_ty)
                    None -> cleared_types
                  }
              }
            _ -> cleared_types
          }
          let #(rest_stmts, final_ctx) =
            lower_statements(
              rest,
              LowerCtx(
                ..ctx_msg,
                local_vars: next_vars,
                local_var_types: next_types,
              ),
            )
          let post_bindings =
            ir_util.prune_bindings(
              lp.prefix_bindings,
              ir_util.free_vars_stmts(rest_stmts),
            )

          let stmt_ir = case kind {
            glance.Let ->
              case lp.guards, lp.prefix_bindings {
                [], [] -> IrStmtLet(lp.pattern, lowered_ann, lowered_val)
                _, _ -> {
                  let guard_cond = combine_guards(lp.guards)
                  IrStmtGuard(
                    value: lowered_val,
                    pattern: lp.pattern,
                    guard_condition: guard_cond,
                    abort_message: None,
                    post_bindings:,
                  )
                }
              }

            glance.LetAssert(..) -> {
              let guard_cond = combine_guards(lp.guards)
              IrStmtGuard(
                value: lowered_val,
                pattern: lp.pattern,
                guard_condition: guard_cond,
                abort_message: lowered_msg,
                post_bindings:,
              )
            }
          }

          #([stmt_ir, ..rest_stmts], final_ctx)
        }

        glance.Assert(expression:, message:, ..) -> {
          let #(lowered_cond, ctx1) = lower_expr(expression, ctx)
          let #(lowered_msg, ctx2) = case message {
            Some(m) -> {
              let #(lm, c) = lower_expr(m, ctx1)
              #(Some(lm), c)
            }
            None -> #(None, ctx1)
          }
          let #(rest_stmts, final_ctx) = lower_statements(rest, ctx2)
          #([IrStmtAssert(lowered_cond, lowered_msg), ..rest_stmts], final_ctx)
        }

        glance.Expression(expr) -> {
          let #(lowered_expr, ctx1) = lower_expr(expr, ctx)
          let #(rest_stmts, final_ctx) = lower_statements(rest, ctx1)
          #([IrStmtExpr(lowered_expr), ..rest_stmts], final_ctx)
        }
      }
  }
}

fn lower_use_patterns(
  patterns: List(glance.UsePattern),
  ctx: LowerCtx,
) -> #(
  List(IrFnParam),
  List(IrStmt),
  Set(String),
  dict.Dict(String, IrType),
  LowerCtx,
) {
  let #(rev_params, rev_preambles, next_vars, next_types, final_ctx) =
    list.fold(
      patterns,
      #([], [], ctx.local_vars, ctx.local_var_types, ctx),
      fn(acc, up) {
        let #(params_acc, pre_acc, vars_acc, types_acc, cur_ctx) = acc
        let lp =
          pattern.lower_pattern(
            up.pattern,
            cur_ctx.table,
            cur_ctx.current_module,
            cur_ctx.next_id,
          )
        let next_ctx = LowerCtx(..cur_ctx, next_id: lp.next_id)
        let lowered_ann =
          option.map(up.annotation, fn(t) {
            lower_ast_type_with_vars(
              t,
              next_ctx.mod_syms,
              next_ctx.table.package_name,
              next_ctx.ast_type_vars,
              Some(next_ctx.table),
            )
          })
        let updated_vars =
          list.fold(lp.bound_names, vars_acc, fn(v, n) { set.insert(v, n) })
        let cleared_types =
          list.fold(lp.bound_names, types_acc, fn(ts, n) { dict.delete(ts, n) })
        let updated_types = case up.pattern, lowered_ann {
          glance.PatternVariable(name: var_name, ..), Some(ann_ty) ->
            dict.insert(cleared_types, var_name, ann_ty)
          _, _ -> cleared_types
        }

        case lp.pattern, lp.guards, lp.prefix_bindings {
          IrPatVar(name), [], [] -> #(
            [IrFnParam(name, lowered_ann), ..params_acc],
            pre_acc,
            updated_vars,
            updated_types,
            next_ctx,
          )
          IrPatDiscard, [], [] -> #(
            [IrFnParam("_", lowered_ann), ..params_acc],
            pre_acc,
            updated_vars,
            updated_types,
            next_ctx,
          )
          IrPatTuple(_), [], [] -> {
            let synth = "__use_arg_" <> int.to_string(next_ctx.next_id)
            let ctx_after = LowerCtx(..next_ctx, next_id: next_ctx.next_id + 1)
            let stmt = IrStmtLet(lp.pattern, None, IrVar(synth))
            #(
              [IrFnParam(synth, lowered_ann), ..params_acc],
              [stmt, ..pre_acc],
              updated_vars,
              updated_types,
              ctx_after,
            )
          }
          _, _, _ -> {
            let synth = "__use_arg_" <> int.to_string(next_ctx.next_id)
            let ctx_after = LowerCtx(..next_ctx, next_id: next_ctx.next_id + 1)
            let stmt =
              IrStmtGuard(
                value: IrVar(synth),
                pattern: lp.pattern,
                guard_condition: combine_guards(lp.guards),
                abort_message: None,
                post_bindings: lp.prefix_bindings,
              )
            #(
              [IrFnParam(synth, lowered_ann), ..params_acc],
              [stmt, ..pre_acc],
              updated_vars,
              updated_types,
              ctx_after,
            )
          }
        }
      },
    )

  #(
    list.reverse(rev_params),
    list.reverse(rev_preambles),
    next_vars,
    next_types,
    final_ctx,
  )
}

fn lower_expr(expr: glance.Expression, ctx: LowerCtx) -> #(IrExpr, LowerCtx) {
  case expr {
    glance.Int(value:, ..) -> #(IrInt(value), ctx)
    glance.Float(value:, ..) -> #(IrFloat(value), ctx)
    glance.String(value:, ..) -> #(IrString(value), ctx)

    glance.Variable(name:, ..) -> #(resolve_variable(name, ctx), ctx)

    glance.NegateInt(value:, ..) -> {
      let #(v, ctx1) = lower_expr(value, ctx)
      #(IrNegateInt(v), ctx1)
    }

    glance.NegateBool(value:, ..) -> {
      let #(v, ctx1) = lower_expr(value, ctx)
      #(IrNegateBool(v), ctx1)
    }

    glance.Block(statements:, ..) -> {
      let #(stmts, ctx1) = lower_statements(statements, ctx)
      #(IrBlock(stmts), LowerCtx(..ctx, next_id: ctx1.next_id))
    }

    glance.Panic(message:, ..) -> {
      let #(msg, ctx1) = lower_opt_expr(message, ctx)
      #(IrAbort(PanicAbort, msg), ctx1)
    }

    glance.Todo(message:, ..) -> {
      let #(msg, ctx1) = lower_opt_expr(message, ctx)
      #(IrAbort(TodoAbort, msg), ctx1)
    }

    glance.Tuple(elements:, ..) -> {
      let #(els, ctx1) = lower_expr_list(elements, ctx)
      #(IrTuple(els), ctx1)
    }

    glance.List(elements:, rest:, ..) -> {
      let #(els, ctx1) = lower_expr_list(elements, ctx)
      let #(tail, ctx2) = lower_opt_expr(rest, ctx1)
      #(IrList(els, tail), ctx2)
    }

    glance.Fn(arguments:, return_annotation:, body:, ..) -> {
      let #(fn_params, body_vars, body_types) =
        list.fold(
          arguments,
          #([], ctx.local_vars, ctx.local_var_types),
          fn(acc, param) {
            let #(ps, vars, types) = acc
            let p_type =
              option.map(param.type_, fn(t) {
                lower_ast_type_with_vars(
                  t,
                  ctx.mod_syms,
                  ctx.table.package_name,
                  ctx.ast_type_vars,
                  Some(ctx.table),
                )
              })
            let #(p_name, next_vars, next_types) = case param.name {
              glance.Named(n) -> #(
                mangle.mangle_ident(n),
                set.insert(vars, n),
                case p_type {
                  Some(pt) -> dict.insert(types, n, pt)
                  None -> dict.delete(types, n)
                },
              )
              glance.Discarded(_) -> #("_", vars, types)
            }
            #([IrFnParam(p_name, p_type), ..ps], next_vars, next_types)
          },
        )
      let ret_type =
        option.map(return_annotation, fn(t) {
          lower_ast_type_with_vars(
            t,
            ctx.mod_syms,
            ctx.table.package_name,
            ctx.ast_type_vars,
            Some(ctx.table),
          )
        })
      let #(lowered_body, ctx1) =
        lower_statements(
          body,
          LowerCtx(..ctx, local_vars: body_vars, local_var_types: body_types),
        )
      #(
        IrFn(list.reverse(fn_params), ret_type, lowered_body),
        LowerCtx(..ctx, next_id: ctx1.next_id),
      )
    }

    glance.RecordUpdate(module:, constructor:, record:, fields:, ..) ->
      lower_record_update(module, constructor, record, fields, ctx)

    glance.FieldAccess(container:, label:, ..) ->
      lower_field_access(container, label, ctx)

    glance.Call(function:, arguments:, ..) -> {
      let #(lowered_fn, ctx1) = lower_expr(function, ctx)
      let #(lowered_args, ctx2) = lower_call_args(arguments, ctx1)
      #(IrCall(lowered_fn, lowered_args), ctx2)
    }

    glance.TupleIndex(tuple:, index:, ..) -> {
      let #(lowered_tuple, ctx1) = lower_expr(tuple, ctx)
      #(IrTupleIndex(lowered_tuple, index), ctx1)
    }

    glance.FnCapture(label:, function:, arguments_before:, arguments_after:, ..) -> {
      let capture_name = "__capture_" <> int.to_string(ctx.next_id)
      let ctx1 = LowerCtx(..ctx, next_id: ctx.next_id + 1)
      let #(lowered_fn, ctx2) = lower_expr(function, ctx1)
      let #(before_args, ctx3) = lower_call_args(arguments_before, ctx2)
      let #(after_args, ctx4) = lower_call_args(arguments_after, ctx3)
      let capture_arg =
        IrCallArg(
          label: option.map(label, mangle.mangle_ident),
          value: IrVar(capture_name),
        )
      let all_args = list.flatten([before_args, [capture_arg], after_args])
      #(
        IrFn(params: [IrFnParam(capture_name, None)], return_type: None, body: [
          IrStmtExpr(IrCall(lowered_fn, all_args)),
        ]),
        ctx4,
      )
    }

    glance.BitString(segments:, ..) -> {
      let #(rev_segs, final_ctx) =
        list.fold(segments, #([], ctx), fn(acc, seg) {
          let #(segs_acc, cur_ctx) = acc
          let #(val_expr, opts) = seg
          let #(lowered_val, ctx1) = lower_expr(val_expr, cur_ctx)
          let #(lowered_opts, ctx2) = lower_bit_expr_options(opts, ctx1)
          #([#(lowered_val, lowered_opts), ..segs_acc], ctx2)
        })
      #(IrBitString(list.reverse(rev_segs)), final_ctx)
    }

    glance.Case(subjects:, clauses:, ..) -> {
      let #(lowered_subjects, ctx1) = lower_expr_list(subjects, ctx)
      let #(lowered_clauses, ctx2) = lower_clauses(clauses, ctx1)
      #(IrMatch(lowered_subjects, lowered_clauses), ctx2)
    }

    glance.BinaryOperator(name:, left:, right:, ..) ->
      case name {
        glance.Pipe -> lower_pipe(left, right, ctx)
        _ -> {
          let #(l, ctx1) = lower_expr(left, ctx)
          let #(r, ctx2) = lower_expr(right, ctx1)
          #(IrBinOp(lower_bin_op(name), l, r), ctx2)
        }
      }

    glance.Echo(location:, expression:, message:) -> {
      let #(file_path, line) =
        echo_location(ctx.current_module, ctx.mod_syms.source, location.start)
      let #(lowered_msg, ctx1) = lower_opt_expr(message, ctx)
      case expression {
        Some(inner) -> {
          let #(lowered_inner, ctx2) = lower_expr(inner, ctx1)
          #(IrEcho(lowered_inner, lowered_msg, file_path, line), ctx2)
        }
        None -> {
          let param = "__echo_" <> int.to_string(ctx1.next_id)
          let ctx2 = LowerCtx(..ctx1, next_id: ctx1.next_id + 1)
          #(
            IrFn(params: [IrFnParam(param, None)], return_type: None, body: [
              IrStmtExpr(IrEcho(IrVar(param), lowered_msg, file_path, line)),
            ]),
            ctx2,
          )
        }
      }
    }
  }
}

fn echo_location(
  module_name: String,
  source: String,
  byte_offset: Int,
) -> #(String, Int) {
  let file_path = case string.starts_with(module_name, "test/") {
    True -> module_name <> ".gleam"
    False -> "src/" <> module_name <> ".gleam"
  }
  let src_bits = bit_array.from_string(source)
  let limit = int.min(int.max(byte_offset, 0), bit_array.byte_size(src_bits))
  let line = case bit_array.slice(src_bits, at: 0, take: limit) {
    Ok(prefix) -> count_newlines(prefix, 1)
    Error(_) -> 1
  }
  #(file_path, line)
}

fn count_newlines(bits: BitArray, line: Int) -> Int {
  case bits {
    <<10, rest:bits>> -> count_newlines(rest, line + 1)
    <<_, rest:bits>> -> count_newlines(rest, line)
    _ -> line
  }
}

fn lower_pipe(
  left: glance.Expression,
  right: glance.Expression,
  ctx: LowerCtx,
) -> #(IrExpr, LowerCtx) {
  let #(lowered_left, ctx1) = lower_expr(left, ctx)
  case right {
    glance.FnCapture(label:, function:, arguments_before:, arguments_after:, ..) -> {
      let #(lowered_fn, ctx2) = lower_expr(function, ctx1)
      let #(before_args, ctx3) = lower_call_args(arguments_before, ctx2)
      let #(after_args, ctx4) = lower_call_args(arguments_after, ctx3)
      let piped_arg =
        IrCallArg(
          label: option.map(label, mangle.mangle_ident),
          value: lowered_left,
        )
      let all_args = list.flatten([before_args, [piped_arg], after_args])
      #(IrCall(lowered_fn, all_args), ctx4)
    }

    glance.Echo(location:, expression: None, message:) -> {
      let #(file_path, line) =
        echo_location(ctx1.current_module, ctx1.mod_syms.source, location.start)
      let #(lowered_msg, ctx2) = lower_opt_expr(message, ctx1)
      #(IrEcho(lowered_left, lowered_msg, file_path, line), ctx2)
    }

    glance.Call(function:, arguments:, ..) -> {
      let #(lowered_fn, ctx2) = lower_expr(function, ctx1)
      let #(lowered_args, ctx3) = lower_call_args(arguments, ctx2)
      case resolve_callee_arity(function, ctx3) {
        Some(#(arity, params)) ->
          case list.length(arguments) >= arity {
            True -> {
              // Call is already saturated -> returns a 1-arg closure invoked with `left`
              let inner_call = IrCall(lowered_fn, lowered_args)
              #(IrCall(inner_call, [IrCallArg(None, lowered_left)]), ctx3)
            }
            False -> {
              let piped_label = find_pipe_slot_label(params, arguments)
              let piped_arg = IrCallArg(piped_label, lowered_left)
              #(IrCall(lowered_fn, [piped_arg, ..lowered_args]), ctx3)
            }
          }
        None -> #(
          IrCall(lowered_fn, [IrCallArg(None, lowered_left), ..lowered_args]),
          ctx3,
        )
      }
    }

    _ -> {
      let #(lowered_right, ctx2) = lower_expr(right, ctx1)
      #(IrCall(lowered_right, [IrCallArg(None, lowered_left)]), ctx2)
    }
  }
}

fn resolve_callee_arity(
  callee: glance.Expression,
  ctx: LowerCtx,
) -> Option(#(Int, List(Option(String)))) {
  case callee {
    glance.Variable(name:, ..) ->
      case set.contains(ctx.local_vars, name) {
        True ->
          case dict.get(ctx.local_var_types, name) {
            Ok(IrTypeFn(params:, ..)) ->
              Some(#(
                list.length(params),
                list.repeat(None, list.length(params)),
              ))
            _ -> None
          }
        False ->
          case dict.get(ctx.mod_syms.functions, name) {
            Ok(fn_info) -> Some(fn_info_arity_labels(fn_info))
            Error(_) ->
              case dict.get(ctx.mod_syms.constructors, name) {
                Ok(ctor) ->
                  Some(#(
                    list.length(ctor.fields),
                    list.map(ctor.fields, fn(f) { f.label }),
                  ))
                Error(_) ->
                  case dict.get(ctx.mod_syms.unqualified_values, name) {
                    Ok(#(target_mod, orig_name)) ->
                      lookup_remote_arity(ctx.table, target_mod, orig_name)
                    Error(_) -> None
                  }
              }
          }
      }

    glance.FieldAccess(container: glance.Variable(name: alias, ..), label:, ..) ->
      case resolve_module_alias_for_access(alias, label, ctx) {
        Some(target_mod) -> lookup_remote_arity(ctx.table, target_mod, label)
        None -> None
      }

    _ ->
      case infer_local_expr_type(callee, ctx) {
        Some(IrTypeFn(params:, ..)) ->
          Some(#(list.length(params), list.repeat(None, list.length(params))))
        _ -> None
      }
  }
}

fn infer_local_expr_type(
  expr: glance.Expression,
  ctx: LowerCtx,
) -> Option(IrType) {
  case expr {
    glance.Int(..) -> Some(IrTypeInt64)
    glance.Float(..) -> Some(IrTypeDouble)
    glance.String(..) -> Some(IrTypeString)
    glance.Variable(name:, ..) ->
      case set.contains(ctx.local_vars, name) {
        True -> dict.get(ctx.local_var_types, name) |> option.from_result
        False ->
          case dict.get(ctx.mod_syms.functions, name) {
            Ok(fi) -> Some(fn_info_to_ir_type(fi, ctx))
            Error(_) ->
              case dict.get(ctx.mod_syms.unqualified_values, name) {
                Ok(#(tm, orig)) ->
                  lookup_remote_fn_ir_type(ctx.table, tm, orig, ctx)
                Error(_) -> None
              }
          }
      }
    glance.FieldAccess(container: glance.Variable(name: alias, ..), label:, ..) ->
      case resolve_module_alias_for_access(alias, label, ctx) {
        Some(tm) -> lookup_remote_fn_ir_type(ctx.table, tm, label, ctx)
        None -> None
      }
    glance.Fn(arguments:, return_annotation:, body:, ..) -> {
      let #(rev_p_tys, body_vars, body_types) =
        list.fold(
          arguments,
          #([], ctx.local_vars, ctx.local_var_types),
          fn(acc, param) {
            let #(pts, vars, types) = acc
            let pt = case param.type_ {
              Some(t) ->
                lower_ast_type_with_vars(
                  t,
                  ctx.mod_syms,
                  ctx.table.package_name,
                  ctx.ast_type_vars,
                  Some(ctx.table),
                )
              None -> IrTypeVar("T0")
            }
            let #(next_vars, next_types) = case param.name {
              glance.Named(n) -> #(
                set.insert(vars, n),
                dict.insert(types, n, pt),
              )
              glance.Discarded(_) -> #(vars, types)
            }
            #([pt, ..pts], next_vars, next_types)
          },
        )
      let ret_ty = case return_annotation {
        Some(t) ->
          lower_ast_type_with_vars(
            t,
            ctx.mod_syms,
            ctx.table.package_name,
            ctx.ast_type_vars,
            Some(ctx.table),
          )
        None ->
          case body {
            [glance.Expression(inner)] ->
              infer_local_expr_type(
                inner,
                LowerCtx(
                  ..ctx,
                  local_vars: body_vars,
                  local_var_types: body_types,
                ),
              )
              |> option.unwrap(IrTypeVar("T0"))
            _ -> IrTypeVar("T0")
          }
      }
      Some(IrTypeFn(list.reverse(rev_p_tys), ret_ty))
    }
    glance.Call(function:, ..) ->
      case infer_local_expr_type(function, ctx) {
        Some(IrTypeFn(_, ret)) -> Some(ret)
        _ -> None
      }
    _ -> None
  }
}

fn lookup_remote_fn_ir_type(
  table: SymbolTable,
  target_mod: String,
  symbol: String,
  ctx: LowerCtx,
) -> Option(IrType) {
  case dict.get(table.modules, target_mod) {
    Ok(ms) ->
      case dict.get(ms.functions, symbol) {
        Ok(fi) -> Some(fn_info_to_ir_type(fi, ctx))
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn fn_info_to_ir_type(fi: FunctionInfo, ctx: LowerCtx) -> IrType {
  let param_tys =
    list.map(fi.parameters, fn(p) {
      case p.resolved_type {
        Some(rt) ->
          resolved_type_to_ir_with_table(
            rt,
            None,
            ctx.mod_syms,
            Some(ctx.table),
          )
        None -> IrTypeVar("T0")
      }
    })
  let ret_ty = case fi.return_type {
    Some(rt) ->
      resolved_type_to_ir_with_table(rt, None, ctx.mod_syms, Some(ctx.table))
    None -> IrTypeUnit
  }
  IrTypeFn(param_tys, ret_ty)
}

fn lookup_remote_arity(
  table: SymbolTable,
  target_mod: String,
  symbol: String,
) -> Option(#(Int, List(Option(String)))) {
  case dict.get(table.modules, target_mod) {
    Ok(ms) ->
      case dict.get(ms.functions, symbol) {
        Ok(fn_info) -> Some(fn_info_arity_labels(fn_info))
        Error(_) ->
          case dict.get(ms.constructors, symbol) {
            Ok(ctor) ->
              Some(#(
                list.length(ctor.fields),
                list.map(ctor.fields, fn(f) { f.label }),
              ))
            Error(_) -> None
          }
      }
    Error(_) -> None
  }
}

fn fn_info_arity_labels(fn_info: FunctionInfo) -> #(Int, List(Option(String))) {
  #(fn_info.arity, list.map(fn_info.parameters, fn(p) { p.label }))
}

fn find_pipe_slot_label(
  param_labels: List(Option(String)),
  supplied_args: List(glance.Field(glance.Expression)),
) -> Option(String) {
  let supplied_labels =
    list.fold(supplied_args, set.new(), fn(acc, arg) {
      case arg {
        glance.LabelledField(label:, ..) | glance.ShorthandField(label:, ..) ->
          set.insert(acc, label)
        glance.UnlabelledField(_) -> acc
      }
    })

  let remaining_params =
    list.filter(param_labels, fn(lbl_opt) {
      case lbl_opt {
        Some(lbl) -> !set.contains(supplied_labels, lbl)
        None -> True
      }
    })

  case remaining_params {
    [first, ..] -> option.map(first, mangle.mangle_ident)
    [] -> None
  }
}

fn lower_field_access(
  container: glance.Expression,
  label: String,
  ctx: LowerCtx,
) -> #(IrExpr, LowerCtx) {
  case container {
    glance.Variable(name: alias, ..) ->
      case resolve_module_alias_for_access(alias, label, ctx) {
        Some(target_mod) ->
          case
            symbol_table.lookup_constructor(
              ctx.table,
              ctx.current_module,
              Some(alias),
              label,
            )
          {
            Some(ctor) -> #(
              IrConstructor(
                module_alias: Some(alias),
                target_module: Some(ctor.module),
                name: ctor.variant_name,
              ),
              ctx,
            )
            None -> #(
              IrModuleRef(
                module_alias: Some(alias),
                target_module: target_mod,
                symbol: mangle.mangle_ident(label),
              ),
              ctx,
            )
          }
        None ->
          case set.contains(ctx.local_vars, alias) {
            True -> #(
              IrGetterCall(
                receiver: IrVar(mangle.mangle_ident(alias)),
                field: mangle.mangle_ident(label),
              ),
              ctx,
            )
            False -> #(
              IrGetterCall(
                receiver: resolve_variable(alias, ctx),
                field: mangle.mangle_ident(label),
              ),
              ctx,
            )
          }
      }

    _ -> {
      let #(lowered_container, ctx1) = lower_expr(container, ctx)
      #(
        IrGetterCall(
          receiver: lowered_container,
          field: mangle.mangle_ident(label),
        ),
        ctx1,
      )
    }
  }
}

fn resolve_module_alias_for_access(
  alias: String,
  label: String,
  ctx: LowerCtx,
) -> Option(String) {
  case dict.get(ctx.mod_syms.alias_to_module, alias) {
    Error(_) -> None
    Ok(target_mod) ->
      case set.contains(ctx.local_vars, alias) {
        False -> Some(target_mod)
        True ->
          case
            module_has_value(ctx.table, target_mod, label)
            && !scope_has_record_field(ctx.table, ctx.mod_syms, label)
          {
            True -> Some(target_mod)
            False -> None
          }
      }
  }
}

fn module_has_value(
  table: SymbolTable,
  target_mod: String,
  symbol: String,
) -> Bool {
  case dict.get(table.modules, target_mod) {
    Error(_) -> False
    Ok(ms) ->
      dict.has_key(ms.functions, symbol)
      || dict.has_key(ms.constructors, symbol)
      || dict.has_key(ms.constants, symbol)
  }
}

fn scope_has_record_field(
  table: SymbolTable,
  mod_syms: ModuleSymbols,
  label: String,
) -> Bool {
  let imported_mods = list.map(mod_syms.imports, fn(imp) { imp.module })
  let scope_mods = [mod_syms.name, ..imported_mods]
  list.any(scope_mods, fn(mod_name) {
    case dict.get(table.modules, mod_name) {
      Error(_) -> False
      Ok(ms) ->
        dict.values(ms.types)
        |> list.any(fn(ti) {
          dict.has_key(ti.shared_fields, label)
          || list.any(ti.variants, fn(v) {
            list.any(v.fields, fn(f) { f.label == Some(label) })
          })
        })
    }
  })
}

fn lower_record_update(
  module: Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
  ctx: LowerCtx,
) -> #(IrExpr, LowerCtx) {
  let #(lowered_record, ctx1) = lower_expr(record, ctx)
  let #(updates_map, ctx2) =
    list.fold(fields, #(dict.new(), ctx1), fn(acc, ruf) {
      let #(map_acc, cur_ctx) = acc
      let #(val_expr, next_ctx) = case ruf.item {
        Some(e) -> lower_expr(e, cur_ctx)
        None -> #(resolve_variable(ruf.label, cur_ctx), cur_ctx)
      }
      #(dict.insert(map_acc, ruf.label, val_expr), next_ctx)
    })

  case
    symbol_table.lookup_constructor(
      ctx2.table,
      ctx2.current_module,
      module,
      constructor,
    )
  {
    Some(ctor) -> {
      let is_single_variant = case dict.get(ctx2.table.modules, ctor.module) {
        Ok(target_syms) ->
          case dict.get(target_syms.types, ctor.type_name) {
            Ok(ti) -> ti.is_single_variant
            Error(_) -> False
          }
        Error(_) -> False
      }

      let #(mod_alias, target_mod) = case ctor.module == ctx2.current_module {
        True -> #(None, None)
        False -> {
          let alias = case module {
            Some(a) -> a
            None -> find_import_alias(ctx2.mod_syms, ctor.module)
          }
          #(Some(alias), Some(ctor.module))
        }
      }

      let update_id = ctx2.next_id
      let ctx3 = LowerCtx(..ctx2, next_id: update_id + 1)

      let #(rev_pat_args, rev_call_args) =
        list.index_fold(ctor.fields, #([], []), fn(acc, field, idx) {
          let #(pats, calls) = acc
          case field.label {
            Some(lbl) -> {
              let mangled_lbl = mangle.mangle_ident(lbl)
              case dict.get(updates_map, lbl) {
                Ok(new_val) -> #(
                  [IrPatArg(Some(mangled_lbl), IrPatDiscard), ..pats],
                  [IrCallArg(Some(mangled_lbl), new_val), ..calls],
                )
                Error(_) -> {
                  let synth =
                    "__upd_" <> int.to_string(update_id) <> "_" <> mangled_lbl
                  #([IrPatArg(Some(mangled_lbl), IrPatVar(synth)), ..pats], [
                    IrCallArg(Some(mangled_lbl), IrVar(synth)),
                    ..calls
                  ])
                }
              }
            }
            None -> {
              let synth =
                "__upd_"
                <> int.to_string(update_id)
                <> "_"
                <> int.to_string(idx)
              #([IrPatArg(None, IrPatVar(synth)), ..pats], [
                IrCallArg(None, IrVar(synth)),
                ..calls
              ])
            }
          }
        })

      let match_pat =
        IrPatVariant(
          module_alias: mod_alias,
          target_module: target_mod,
          constructor: ctor.variant_name,
          args: list.reverse(rev_pat_args),
          with_spread: False,
        )

      let reconstruct_expr =
        IrCall(
          function: IrConstructor(mod_alias, target_mod, ctor.variant_name),
          args: list.reverse(rev_call_args),
        )

      let main_clause =
        IrClause(
          patterns: [[match_pat]],
          guard: None,
          prefix_bindings: [],
          body: reconstruct_expr,
        )

      let clauses = case is_single_variant {
        True -> [main_clause]
        False -> [
          main_clause,
          IrClause(
            patterns: [[IrPatDiscard]],
            guard: None,
            prefix_bindings: [],
            body: IrAbort(
              PanicAbort,
              Some(IrString("unreachable record update variant")),
            ),
          ),
        ]
      }

      #(IrMatch(subjects: [lowered_record], clauses:), ctx3)
    }

    None -> {
      // Fallback if constructor wasn't indexed (e.g. external unindexed type)
      let fallback_args =
        list.map(fields, fn(ruf) {
          let val = case dict.get(updates_map, ruf.label) {
            Ok(v) -> v
            Error(_) -> resolve_variable(ruf.label, ctx2)
          }
          IrCallArg(Some(mangle.mangle_ident(ruf.label)), val)
        })
      #(
        IrCall(
          function: IrConstructor(module, None, constructor),
          args: fallback_args,
        ),
        ctx2,
      )
    }
  }
}

fn lower_clauses(
  clauses: List(glance.Clause),
  ctx: LowerCtx,
) -> #(List(IrClause), LowerCtx) {
  let #(rev_clauses, final_ctx) =
    list.fold(clauses, #([], ctx), fn(acc, clause) {
      let #(clauses_acc, cur_ctx) = acc
      let #(lowered_alts, next_ctx) = lower_clause(clause, cur_ctx)
      let next_acc =
        list.fold(lowered_alts, clauses_acc, fn(c_acc, c) { [c, ..c_acc] })
      #(next_acc, next_ctx)
    })
  #(list.reverse(rev_clauses), final_ctx)
}

fn lower_clause(
  clause: glance.Clause,
  ctx: LowerCtx,
) -> #(List(IrClause), LowerCtx) {
  let #(rev_alts, ctx1) =
    list.fold(clause.patterns, #([], ctx), fn(acc, alt_patterns) {
      let #(alts_acc, cur_ctx) = acc
      let #(rev_ir_pats, g_acc, b_acc, n_acc, cur_id) =
        list.fold(
          alt_patterns,
          #([], [], [], [], cur_ctx.next_id),
          fn(inner, p) {
            let #(ps, gs, bs, ns, id_acc) = inner
            let lp =
              pattern.lower_pattern(
                p,
                cur_ctx.table,
                cur_ctx.current_module,
                id_acc,
              )
            #(
              [lp.pattern, ..ps],
              list.append(gs, lp.guards),
              list.append(bs, lp.prefix_bindings),
              list.append(ns, lp.bound_names),
              lp.next_id,
            )
          },
        )
      let alt_tuple = #(list.reverse(rev_ir_pats), g_acc, b_acc, n_acc)
      #([alt_tuple, ..alts_acc], LowerCtx(..cur_ctx, next_id: cur_id))
    })

  let alts = list.reverse(rev_alts)
  let any_synthetic = list.any(alts, fn(a) { a.1 != [] || a.2 != [] })

  case any_synthetic {
    False -> {
      let all_patterns = list.map(alts, fn(a) { a.0 })
      let bound_vars =
        list.fold(alts, ctx1.local_vars, fn(vars, a) {
          list.fold(a.3, vars, fn(v, n) { set.insert(v, n) })
        })
      let bound_types =
        list.fold(alts, ctx1.local_var_types, fn(ts, a) {
          list.fold(a.3, ts, fn(t, n) { dict.delete(t, n) })
        })
      let arm_ctx =
        LowerCtx(..ctx1, local_vars: bound_vars, local_var_types: bound_types)
      let #(guard_ir, ctx2) = lower_opt_expr(clause.guard, arm_ctx)
      let #(body_ir, ctx3) = lower_expr(clause.body, ctx2)
      #(
        [
          IrClause(
            patterns: all_patterns,
            guard: guard_ir,
            prefix_bindings: [],
            body: body_ir,
          ),
        ],
        LowerCtx(..ctx1, next_id: ctx3.next_id),
      )
    }

    True -> {
      let #(rev_clauses, final_ctx) =
        list.fold(alts, #([], ctx1), fn(acc, alt) {
          let #(c_acc, cur_ctx) = acc
          let #(pats, synth_guards, prefix_bindings, bound_names) = alt
          let bound_vars =
            list.fold(bound_names, cur_ctx.local_vars, fn(v, n) {
              set.insert(v, n)
            })
          let bound_types =
            list.fold(bound_names, cur_ctx.local_var_types, fn(ts, n) {
              dict.delete(ts, n)
            })
          let arm_ctx =
            LowerCtx(
              ..cur_ctx,
              local_vars: bound_vars,
              local_var_types: bound_types,
            )
          let #(user_guard, ctx_g) = lower_opt_expr(clause.guard, arm_ctx)
          let combined_guard =
            build_clause_guard(synth_guards, prefix_bindings, user_guard)
          let #(body_ir, ctx_b) = lower_expr(clause.body, ctx_g)
          let pruned_prefix_bindings =
            ir_util.prune_bindings(
              prefix_bindings,
              ir_util.free_vars_expr(body_ir),
            )
          let ir_clause =
            IrClause(
              patterns: [pats],
              guard: combined_guard,
              prefix_bindings: pruned_prefix_bindings,
              body: body_ir,
            )
          #([ir_clause, ..c_acc], LowerCtx(..cur_ctx, next_id: ctx_b.next_id))
        })
      #(list.reverse(rev_clauses), final_ctx)
    }
  }
}

fn build_clause_guard(
  synth_guards: List(IrExpr),
  prefix_bindings: List(#(String, IrExpr)),
  user_guard: Option(IrExpr),
) -> Option(IrExpr) {
  let synth_opt = combine_guards(synth_guards)
  let user_opt = case user_guard {
    None -> None
    Some(ug) ->
      case ir_util.prune_bindings(prefix_bindings, ir_util.free_vars_expr(ug)) {
        [] -> Some(ug)
        kept -> {
          let lets =
            list.map(kept, fn(binding) {
              IrStmtLet(IrPatVar(binding.0), None, binding.1)
            })
          Some(IrBlock(list.append(lets, [IrStmtExpr(ug)])))
        }
      }
  }
  case synth_opt, user_opt {
    None, None -> None
    Some(s), None -> Some(s)
    None, Some(u) -> Some(u)
    Some(s), Some(u) -> Some(IrBinOp(IrAnd, s, u))
  }
}

fn combine_guards(guards: List(IrExpr)) -> Option(IrExpr) {
  case guards {
    [] -> None
    [first, ..rest] ->
      Some(list.fold(rest, first, fn(acc, g) { IrBinOp(IrAnd, acc, g) }))
  }
}

fn prune_use_preambles(
  preambles: List(IrStmt),
  rest_stmts: List(IrStmt),
) -> List(IrStmt) {
  case preambles {
    [] -> []
    [first, ..more] -> {
      let pruned_more = prune_use_preambles(more, rest_stmts)
      let tail_fv =
        ir_util.free_vars_stmts(list.append(pruned_more, rest_stmts))
      let updated_first = case first {
        IrStmtGuard(
          value:,
          pattern:,
          guard_condition:,
          abort_message:,
          post_bindings:,
        ) ->
          IrStmtGuard(
            value:,
            pattern:,
            guard_condition:,
            abort_message:,
            post_bindings: ir_util.prune_bindings(post_bindings, tail_fv),
          )
        other -> other
      }
      [updated_first, ..pruned_more]
    }
  }
}

fn lower_call_args(
  fields: List(glance.Field(glance.Expression)),
  ctx: LowerCtx,
) -> #(List(IrCallArg), LowerCtx) {
  let #(rev_args, final_ctx) =
    list.fold(fields, #([], ctx), fn(acc, field) {
      let #(args_acc, cur_ctx) = acc
      case field {
        glance.UnlabelledField(item:) -> {
          let #(val, next_ctx) = lower_expr(item, cur_ctx)
          #([IrCallArg(None, val), ..args_acc], next_ctx)
        }
        glance.LabelledField(label:, item:, ..) -> {
          let #(val, next_ctx) = lower_expr(item, cur_ctx)
          #(
            [IrCallArg(Some(mangle.mangle_ident(label)), val), ..args_acc],
            next_ctx,
          )
        }
        glance.ShorthandField(label:, ..) -> {
          let mangled = mangle.mangle_ident(label)
          let val = resolve_variable(label, cur_ctx)
          #([IrCallArg(Some(mangled), val), ..args_acc], cur_ctx)
        }
      }
    })
  #(list.reverse(rev_args), final_ctx)
}

fn lower_bit_expr_options(
  opts: List(glance.BitStringSegmentOption(glance.Expression)),
  ctx: LowerCtx,
) -> #(List(glance.BitStringSegmentOption(IrExpr)), LowerCtx) {
  let #(rev_opts, final_ctx) =
    list.fold(opts, #([], ctx), fn(acc, opt) {
      let #(opts_acc, cur_ctx) = acc
      case opt {
        glance.BytesOption -> #([glance.BytesOption, ..opts_acc], cur_ctx)
        glance.IntOption -> #([glance.IntOption, ..opts_acc], cur_ctx)
        glance.FloatOption -> #([glance.FloatOption, ..opts_acc], cur_ctx)
        glance.BitsOption -> #([glance.BitsOption, ..opts_acc], cur_ctx)
        glance.Utf8Option -> #([glance.Utf8Option, ..opts_acc], cur_ctx)
        glance.Utf16Option -> #([glance.Utf16Option, ..opts_acc], cur_ctx)
        glance.Utf32Option -> #([glance.Utf32Option, ..opts_acc], cur_ctx)
        glance.Utf8CodepointOption -> #(
          [glance.Utf8CodepointOption, ..opts_acc],
          cur_ctx,
        )
        glance.Utf16CodepointOption -> #(
          [glance.Utf16CodepointOption, ..opts_acc],
          cur_ctx,
        )
        glance.Utf32CodepointOption -> #(
          [glance.Utf32CodepointOption, ..opts_acc],
          cur_ctx,
        )
        glance.SignedOption -> #([glance.SignedOption, ..opts_acc], cur_ctx)
        glance.UnsignedOption -> #([glance.UnsignedOption, ..opts_acc], cur_ctx)
        glance.BigOption -> #([glance.BigOption, ..opts_acc], cur_ctx)
        glance.LittleOption -> #([glance.LittleOption, ..opts_acc], cur_ctx)
        glance.NativeOption -> #([glance.NativeOption, ..opts_acc], cur_ctx)
        glance.SizeOption(n) -> #([glance.SizeOption(n), ..opts_acc], cur_ctx)
        glance.UnitOption(u) -> #([glance.UnitOption(u), ..opts_acc], cur_ctx)
        glance.SizeValueOption(expr) -> {
          let #(lowered, next_ctx) = lower_expr(expr, cur_ctx)
          #([glance.SizeValueOption(lowered), ..opts_acc], next_ctx)
        }
      }
    })
  #(list.reverse(rev_opts), final_ctx)
}

fn lower_bin_op(op: glance.BinaryOperator) -> IrBinOp {
  case op {
    glance.And -> IrAnd
    glance.Or -> IrOr
    glance.Eq -> IrEq
    glance.NotEq -> IrNotEq
    glance.LtInt -> IrLtInt
    glance.LtEqInt -> IrLtEqInt
    glance.GtInt -> IrGtInt
    glance.GtEqInt -> IrGtEqInt
    glance.LtFloat -> IrLtFloat
    glance.LtEqFloat -> IrLtEqFloat
    glance.GtFloat -> IrGtFloat
    glance.GtEqFloat -> IrGtEqFloat
    glance.AddInt -> IrAddInt
    glance.SubInt -> IrSubInt
    glance.MultInt -> IrMultInt
    glance.DivInt -> IrDivInt
    glance.RemainderInt -> IrRemInt
    glance.AddFloat -> IrAddFloat
    glance.SubFloat -> IrSubFloat
    glance.MultFloat -> IrMultFloat
    glance.DivFloat -> IrDivFloat
    glance.Concatenate -> IrStringConcat
    glance.Pipe -> panic as "Pipe operator must be handled by lower_pipe"
  }
}

fn resolve_variable(name: String, ctx: LowerCtx) -> IrExpr {
  case set.contains(ctx.local_vars, name) {
    True -> IrVar(mangle.mangle_ident(name))
    False ->
      case dict.get(ctx.mod_syms.constructors, name) {
        Ok(ctor) -> IrConstructor(None, None, ctor.variant_name)
        Error(_) ->
          case dict.get(ctx.mod_syms.unqualified_values, name) {
            Ok(#(target_mod, orig_name)) -> {
              let alias = find_import_alias(ctx.mod_syms, target_mod)
              case
                symbol_table.lookup_constructor(
                  ctx.table,
                  ctx.current_module,
                  None,
                  name,
                )
              {
                Some(ctor) ->
                  IrConstructor(
                    module_alias: Some(alias),
                    target_module: Some(ctor.module),
                    name: ctor.variant_name,
                  )
                None ->
                  IrModuleRef(
                    module_alias: Some(alias),
                    target_module: target_mod,
                    symbol: mangle.mangle_ident(orig_name),
                  )
              }
            }
            Error(_) ->
              case name {
                "True" -> IrBool(True)
                "False" -> IrBool(False)
                "Nil" -> IrUnit
                "Ok" -> IrConstructor(None, None, "Ok")
                "Error" -> IrConstructor(None, None, "Err")
                _ -> IrVar(mangle.mangle_ident(name))
              }
          }
      }
  }
}

fn find_import_alias(mod_syms: ModuleSymbols, target_mod: String) -> String {
  case list.find(mod_syms.imports, fn(imp) { imp.module == target_mod }) {
    Ok(imp) ->
      case imp.alias {
        Some(a) -> a
        None -> mangle.module_to_alias(target_mod)
      }
    Error(_) -> mangle.module_to_alias(target_mod)
  }
}

fn lower_expr_list(
  exprs: List(glance.Expression),
  ctx: LowerCtx,
) -> #(List(IrExpr), LowerCtx) {
  let #(rev_exprs, final_ctx) =
    list.fold(exprs, #([], ctx), fn(acc, e) {
      let #(exprs_acc, cur_ctx) = acc
      let #(lowered, next_ctx) = lower_expr(e, cur_ctx)
      #([lowered, ..exprs_acc], next_ctx)
    })
  #(list.reverse(rev_exprs), final_ctx)
}

fn lower_opt_expr(
  opt: Option(glance.Expression),
  ctx: LowerCtx,
) -> #(Option(IrExpr), LowerCtx) {
  case opt {
    None -> #(None, ctx)
    Some(e) -> {
      let #(lowered, next_ctx) = lower_expr(e, ctx)
      #(Some(lowered), next_ctx)
    }
  }
}

/// Convert a `ResolvedType` from `package-interface` into `IrType`.
pub fn resolved_type_to_ir(
  ty: ResolvedType,
  named_type_params: Option(List(String)),
  mod_syms: ModuleSymbols,
) -> IrType {
  resolved_type_to_ir_with_table(ty, named_type_params, mod_syms, None)
}

fn resolved_type_to_ir_with_table(
  ty: ResolvedType,
  named_type_params: Option(List(String)),
  mod_syms: ModuleSymbols,
  table_opt: Option(SymbolTable),
) -> IrType {
  case ty {
    NamedType(name:, package:, module:, parameters:) -> {
      let lowered_args =
        list.map(parameters, fn(p) {
          resolved_type_to_ir_with_table(
            p,
            named_type_params,
            mod_syms,
            table_opt,
          )
        })
      case module, name, lowered_args {
        "gleam", "Int", [] -> IrTypeInt64
        "gleam", "Float", [] -> IrTypeDouble
        "gleam", "String", [] -> IrTypeString
        "gleam", "Bool", [] -> IrTypeBool
        "gleam", "Nil", [] -> IrTypeUnit
        "gleam", "BitArray", [] -> IrTypeBitArray
        "gleam", "List", [inner] -> IrTypeList(inner)
        "gleam", "Result", [ok_t, err_t] -> IrTypeResult(ok_t, err_t)
        _, _, _ -> {
          let alias = case module == mod_syms.name {
            True -> None
            False -> Some(find_import_alias(mod_syms, module))
          }
          IrTypeNamed(
            module_alias: alias,
            package:,
            module:,
            name: mangle_referenced_type_name(table_opt, module, name),
            args: lowered_args,
          )
        }
      }
    }

    TupleType(elements:) ->
      IrTypeTuple(
        list.map(elements, fn(el) {
          resolved_type_to_ir_with_table(
            el,
            named_type_params,
            mod_syms,
            table_opt,
          )
        }),
      )

    FnType(parameters:, return:) ->
      IrTypeFn(
        params: list.map(parameters, fn(p) {
          resolved_type_to_ir_with_table(
            p,
            named_type_params,
            mod_syms,
            table_opt,
          )
        }),
        return: resolved_type_to_ir_with_table(
          return,
          named_type_params,
          mod_syms,
          table_opt,
        ),
      )

    VariableType(id:) -> {
      let name = case named_type_params {
        Some(names) ->
          case list_at(names, id) {
            Some(n) -> mangle.mangle_type_param(n)
            None -> mangle.type_var_id_to_name(id)
          }
        None -> mangle.type_var_id_to_name(id)
      }
      IrTypeVar(name)
    }
  }
}

/// Lower an AST `glance.Type` annotation into `IrType`.
pub fn lower_ast_type(
  ty: glance.Type,
  mod_syms: ModuleSymbols,
  package_name: String,
) -> IrType {
  lower_ast_type_with_table(ty, mod_syms, package_name, None)
}

fn lower_ast_type_with_table(
  ty: glance.Type,
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
) -> IrType {
  lower_ast_type_with_vars(ty, mod_syms, package_name, dict.new(), table_opt)
}

fn lower_ast_type_with_vars(
  ty: glance.Type,
  mod_syms: ModuleSymbols,
  package_name: String,
  ast_type_vars: dict.Dict(String, String),
  table_opt: Option(SymbolTable),
) -> IrType {
  case ty {
    glance.NamedType(name:, module: mod_opt, parameters:, ..) -> {
      let args =
        list.map(parameters, fn(p) {
          lower_ast_type_with_vars(
            p,
            mod_syms,
            package_name,
            ast_type_vars,
            table_opt,
          )
        })
      case mod_opt, name, args {
        None, "Int", [] -> IrTypeInt64
        None, "Float", [] -> IrTypeDouble
        None, "String", [] -> IrTypeString
        None, "Bool", [] -> IrTypeBool
        None, "Nil", [] -> IrTypeUnit
        None, "BitArray", [] -> IrTypeBitArray
        None, "UtfCodepoint", [] ->
          IrTypeNamed(
            module_alias: None,
            package: "gleam",
            module: "gleam",
            name: "UtfCodepoint",
            args: [],
          )
        None, "List", [inner] -> IrTypeList(inner)
        None, "Result", [ok_t, err_t] -> IrTypeResult(ok_t, err_t)
        Some(alias), _, _ -> {
          let target_mod = case dict.get(mod_syms.alias_to_module, alias) {
            Ok(m) -> m
            Error(_) -> alias
          }
          IrTypeNamed(
            module_alias: Some(alias),
            package: package_name,
            module: target_mod,
            name: mangle_referenced_type_name(table_opt, target_mod, name),
            args:,
          )
        }
        None, _, _ ->
          case dict.get(mod_syms.unqualified_types, name) {
            Ok(#(target_mod, orig_name)) ->
              IrTypeNamed(
                module_alias: Some(find_import_alias(mod_syms, target_mod)),
                package: package_name,
                module: target_mod,
                name: mangle_referenced_type_name(
                  table_opt,
                  target_mod,
                  orig_name,
                ),
                args:,
              )
            Error(_) ->
              IrTypeNamed(
                module_alias: None,
                package: package_name,
                module: mod_syms.name,
                name: mangle_referenced_type_name(
                  table_opt,
                  mod_syms.name,
                  name,
                ),
                args:,
              )
          }
      }
    }

    glance.TupleType(elements:, ..) ->
      IrTypeTuple(
        list.map(elements, fn(el) {
          lower_ast_type_with_vars(
            el,
            mod_syms,
            package_name,
            ast_type_vars,
            table_opt,
          )
        }),
      )

    glance.FunctionType(parameters:, return:, ..) ->
      IrTypeFn(
        params: list.map(parameters, fn(p) {
          lower_ast_type_with_vars(
            p,
            mod_syms,
            package_name,
            ast_type_vars,
            table_opt,
          )
        }),
        return: lower_ast_type_with_vars(
          return,
          mod_syms,
          package_name,
          ast_type_vars,
          table_opt,
        ),
      )

    glance.VariableType(name:, ..) | glance.HoleType(name:, ..) -> {
      let mangled = mangle.mangle_type_param(name)
      case dict.get(ast_type_vars, mangled) {
        Ok(canon) -> IrTypeVar(canon)
        Error(_) -> IrTypeVar(mangled)
      }
    }
  }
}

fn build_ast_type_var_map(
  ast_params: List(glance.FunctionParameter),
  ir_params: List(IrParam),
  ast_return: Option(glance.Type),
  ir_return: IrType,
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
) -> dict.Dict(String, String) {
  let acc0 =
    list.fold(list.zip(ast_params, ir_params), dict.new(), fn(acc, pair) {
      let #(ap, ip) = pair
      case ap.type_ {
        Some(ast_t) ->
          collect_ast_type_var_map(
            lower_ast_type_with_table(ast_t, mod_syms, package_name, table_opt),
            ip.param_type,
            mod_syms,
            package_name,
            table_opt,
            set.new(),
            acc,
          )
        None -> acc
      }
    })
  case ast_return {
    Some(ast_r) ->
      collect_ast_type_var_map(
        lower_ast_type_with_table(ast_r, mod_syms, package_name, table_opt),
        ir_return,
        mod_syms,
        package_name,
        table_opt,
        set.new(),
        acc0,
      )
    None -> acc0
  }
}

fn collect_ast_type_var_map(
  ast_ir: IrType,
  resolved_ir: IrType,
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
  visited: Set(#(String, String)),
  acc: dict.Dict(String, String),
) -> dict.Dict(String, String) {
  case ast_ir, resolved_ir {
    IrTypeVar(a), IrTypeVar(b) -> dict.insert(acc, a, b)
    IrTypeList(a), IrTypeList(b) ->
      collect_ast_type_var_map(
        a,
        b,
        mod_syms,
        package_name,
        table_opt,
        visited,
        acc,
      )
    IrTypeResult(ao, ae), IrTypeResult(bo, be) ->
      collect_ast_type_var_map(
        ae,
        be,
        mod_syms,
        package_name,
        table_opt,
        visited,
        collect_ast_type_var_map(
          ao,
          bo,
          mod_syms,
          package_name,
          table_opt,
          visited,
          acc,
        ),
      )
    IrTypeTuple(as_), IrTypeTuple(bs) ->
      list.fold(list.zip(as_, bs), acc, fn(s, pair) {
        collect_ast_type_var_map(
          pair.0,
          pair.1,
          mod_syms,
          package_name,
          table_opt,
          visited,
          s,
        )
      })
    IrTypeFn(ap, ar), IrTypeFn(bp, br) -> {
      let s1 =
        list.fold(list.zip(ap, bp), acc, fn(s, pair) {
          collect_ast_type_var_map(
            pair.0,
            pair.1,
            mod_syms,
            package_name,
            table_opt,
            visited,
            s,
          )
        })
      collect_ast_type_var_map(
        ar,
        br,
        mod_syms,
        package_name,
        table_opt,
        visited,
        s1,
      )
    }
    IrTypeNamed(module: am, name: an, args: a_args, ..),
      IrTypeNamed(module: rm, name: rn, args: b_args, ..)
      if am == rm && an == rn
    ->
      list.fold(list.zip(a_args, b_args), acc, fn(s, pair) {
        collect_ast_type_var_map(
          pair.0,
          pair.1,
          mod_syms,
          package_name,
          table_opt,
          visited,
          s,
        )
      })
    IrTypeNamed(module:, name:, args:, ..), _ ->
      case
        expand_ast_type_alias(
          module,
          name,
          args,
          mod_syms,
          package_name,
          table_opt,
          visited,
        )
      {
        Some(#(expanded, next_mod_syms)) ->
          collect_ast_type_var_map(
            expanded,
            resolved_ir,
            next_mod_syms,
            package_name,
            table_opt,
            set.insert(visited, #(module, name)),
            acc,
          )
        None -> acc
      }
    _, _ -> acc
  }
}

fn expand_ast_type_alias(
  module: String,
  name: String,
  args: List(IrType),
  mod_syms: ModuleSymbols,
  package_name: String,
  table_opt: Option(SymbolTable),
  visited: Set(#(String, String)),
) -> Option(#(IrType, ModuleSymbols)) {
  case set.contains(visited, #(module, name)) {
    True -> None
    False -> {
      let target_syms = case module == mod_syms.name || module == "" {
        True -> Some(mod_syms)
        False ->
          case table_opt {
            Some(tbl) -> dict.get(tbl.modules, module) |> option.from_result
            None -> None
          }
      }
      case target_syms {
        None -> None
        Some(ts) -> {
          let found =
            dict.values(ts.type_aliases)
            |> list.find(fn(ta) {
              ta.name == name || mangle.mangle_type_name(ta.name) == name
            })
          case found {
            Ok(ta) ->
              case list.length(ta.parameters) == list.length(args) {
                False -> None
                True -> {
                  let lowered_body =
                    lower_ast_type_with_table(
                      ta.aliased,
                      ts,
                      package_name,
                      table_opt,
                    )
                  let subst =
                    list.zip(
                      list.map(ta.parameters, mangle.mangle_type_param),
                      args,
                    )
                    |> dict.from_list
                  Some(#(substitute_ir_type_vars(lowered_body, subst), ts))
                }
              }
            Error(_) -> None
          }
        }
      }
    }
  }
}

fn substitute_ir_type_vars(
  ty: IrType,
  subst: dict.Dict(String, IrType),
) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(replacement) -> replacement
        Error(_) -> ty
      }
    IrTypeList(inner) -> IrTypeList(substitute_ir_type_vars(inner, subst))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(
        substitute_ir_type_vars(ok_t, subst),
        substitute_ir_type_vars(err_t, subst),
      )
    IrTypeTuple(els) ->
      IrTypeTuple(list.map(els, substitute_ir_type_vars(_, subst)))
    IrTypeFn(ps, r) ->
      IrTypeFn(
        list.map(ps, substitute_ir_type_vars(_, subst)),
        substitute_ir_type_vars(r, subst),
      )
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, substitute_ir_type_vars(_, subst)))
    _ -> ty
  }
}

fn is_builtin_external_type(
  table_opt: Option(SymbolTable),
  module: String,
  name: String,
) -> Bool {
  case table_opt {
    None -> False
    Some(tbl) ->
      case dict.get(tbl.modules, module) {
        Error(_) -> False
        Ok(ms) ->
          case dict.get(ms.types, name) {
            Ok(ti) ->
              case ti.external_type {
                Some(ExternalType(package: pkg, type_name:)) ->
                  { pkg == "" || pkg == "builtin" } && type_name == name
                _ -> False
              }
            Error(_) -> False
          }
      }
  }
}

fn mangle_referenced_type_name(
  table_opt: Option(SymbolTable),
  module: String,
  name: String,
) -> String {
  case module == "gleam" || is_builtin_external_type(table_opt, module, name) {
    True -> name
    False -> mangle.mangle_type_name(name)
  }
}

fn list_at(items: List(a), index: Int) -> Option(a) {
  case items, index {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], i if i > 0 -> list_at(tail, i - 1)
    _, _ -> None
  }
}
