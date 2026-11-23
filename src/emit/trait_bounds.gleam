import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrCallArg, type IrExpr, type IrFunction, type IrModule, type IrParam,
  type IrPatArg, type IrPattern, type IrStmt, type IrType, type IrTypeDef,
  type IrVariant, IrAbort, IrAddFloat, IrAddInt, IrAnd, IrBinOp, IrBitString,
  IrBlock, IrBool, IrBreak, IrCall, IrConstructor, IrContinue, IrDivFloat,
  IrDivInt, IrEcho, IrEq, IrFloat, IrFn, IrForLoop, IrGetterCall, IrGtEqFloat,
  IrGtEqInt, IrGtFloat, IrGtInt, IrInt, IrList, IrLtEqFloat, IrLtEqInt,
  IrLtFloat, IrLtInt, IrMatch, IrModuleRef, IrMultFloat, IrMultInt, IrNegateBool,
  IrNegateInt, IrNotEq, IrOr, IrParam, IrPatAs, IrPatTuple, IrPatVar,
  IrPatVariant, IrRemInt, IrStmtAssert, IrStmtExpr, IrStmtGuard, IrStmtLet,
  IrString, IrStringConcat, IrSubFloat, IrSubInt, IrTuple, IrTupleIndex,
  IrTypeBitArray, IrTypeBool, IrTypeDouble, IrTypeFn, IrTypeInt64, IrTypeList,
  IrTypeNamed, IrTypeResult, IrTypeString, IrTypeTuple, IrTypeUnit, IrTypeVar,
  IrUnit, IrVar,
}
import lower/mangle
import moonbit/ffi_meta.{type FfiMetadata, type MbtType}
import project/prepass.{type ExternalType, ExternalType, PackageCall}

/// Generic trait bounds inferred for a single top-level function.
pub type FnTraitBounds {
  FnTraitBounds(
    eq_vars: Set(String),
    to_dynamic_vars: Set(String),
    inspect_vars: Set(String),
  )
}

/// Whole-project trait bounds and `Eq`-`Hash` propagation results.
pub type ProjectTraitBounds {
  ProjectTraitBounds(
    fn_bounds: Dict(#(String, String), FnTraitBounds),
    type_eq_hash_params: Dict(#(String, String), Set(Int)),
    all_fns: Dict(#(String, String), IrFunction),
    all_consts: Dict(#(String, String), IrType),
  )
}

type GetterSig {
  GetterSig(type_params: List(String), return_type: IrType)
}

type AnalyzeCtx {
  AnalyzeCtx(
    all_fns: Dict(#(String, String), IrFunction),
    all_consts: Dict(#(String, String), IrType),
    all_types: Dict(#(String, String), IrTypeDef),
    all_type_aliases: Dict(#(String, String), ir.IrTypeAlias),
    all_ctors: Dict(#(String, String), #(IrTypeDef, IrVariant)),
    all_getters: Dict(#(String, String, String), GetterSig),
    table: Option(SymbolTable),
    ffi_metadata: FfiMetadata,
  )
}

/// Empty `FnTraitBounds` value.
pub fn empty_fn_bounds() -> FnTraitBounds {
  FnTraitBounds(
    eq_vars: set.new(),
    to_dynamic_vars: set.new(),
    inspect_vars: set.new(),
  )
}

/// Look up inferred trait bounds for `(module_name, fn_name)`.
pub fn lookup_fn_bounds(
  bounds: ProjectTraitBounds,
  module_name: String,
  fn_name: String,
) -> FnTraitBounds {
  case dict.get(bounds.fn_bounds, #(module_name, fn_name)) {
    Ok(fb) -> fb
    Error(_) -> empty_fn_bounds()
  }
}

/// Return True when `param_idx` is a pure inspect sink: its type is a bare
/// `IrTypeVar(v)` present in `bounds.inspect_vars`, and `v` neither escapes
/// into `f.return_type` nor appears in any other parameter of `f`.
pub fn param_is_pure_inspect_sink(
  f: IrFunction,
  param_idx: Int,
  bounds: FnTraitBounds,
) -> Bool {
  case list_at_idx(f.params, param_idx) {
    Some(IrParam(param_type: IrTypeVar(tp), ..)) ->
      case set.contains(bounds.inspect_vars, tp) {
        False -> False
        True -> {
          let ret_vars = collect_type_var_names(f.return_type, set.new())
          let other_vars =
            list.index_fold(f.params, set.new(), fn(acc, p, idx) {
              case idx == param_idx {
                True -> acc
                False -> collect_type_var_names(p.param_type, acc)
              }
            })
          !set.contains(ret_vars, tp) && !set.contains(other_vars, tp)
        }
      }
    _ -> False
  }
}

/// Infer trait bounds and `Eq`->`Hash` type-parameter dependencies across all modules.
pub fn analyze_project(
  modules: List(IrModule),
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
) -> ProjectTraitBounds {
  let ctx = build_analyze_ctx(modules, table, ffi_metadata)
  let type_eq_hash_params = compute_type_eq_hash_params(modules, ctx)
  let initial_bounds = seed_all_fn_bounds(modules, ctx)
  let fn_bounds = propagate_fixpoint(modules, ctx, initial_bounds, 1024)
  ProjectTraitBounds(
    fn_bounds:,
    type_eq_hash_params:,
    all_fns: ctx.all_fns,
    all_consts: ctx.all_consts,
  )
}

fn build_analyze_ctx(
  modules: List(IrModule),
  table: Option(SymbolTable),
  ffi_metadata: FfiMetadata,
) -> AnalyzeCtx {
  let #(
    all_fns,
    all_consts,
    all_types,
    all_type_aliases,
    all_ctors,
    all_getters,
  ) =
    list.fold(
      modules,
      #(dict.new(), dict.new(), dict.new(), dict.new(), dict.new(), dict.new()),
      fn(acc, mod) {
        let #(fns, consts, types, aliases, ctors, getters) = acc
        let next_fns =
          list.fold(mod.functions, fns, fn(m, f) {
            dict.insert(m, #(mod.module_name, f.name), f)
          })
        let next_consts =
          list.fold(mod.constants, consts, fn(m, c) {
            dict.insert(m, #(mod.module_name, c.name), c.value_type)
          })
        let next_types =
          list.fold(mod.types, types, fn(m, td) {
            m
            |> dict.insert(#(mod.module_name, td.name), td)
            |> dict.insert(#(mod.module_name, td.unmangled_name), td)
          })
        let next_aliases =
          list.fold(mod.type_aliases, aliases, fn(m, ta) {
            dict.insert(m, #(mod.module_name, ta.name), ta)
          })
        let next_ctors =
          list.fold(mod.types, ctors, fn(m, td) {
            list.fold(td.variants, m, fn(cm, v) {
              dict.insert(cm, #(mod.module_name, v.name), #(td, v))
            })
          })
        let next_getters =
          list.fold(mod.getters, getters, fn(m, g) {
            let sig =
              GetterSig(type_params: g.type_params, return_type: g.return_type)
            dict.insert(m, #(mod.module_name, g.type_name, g.field_name), sig)
          })
        #(
          next_fns,
          next_consts,
          next_types,
          next_aliases,
          next_ctors,
          next_getters,
        )
      },
    )
  AnalyzeCtx(
    all_fns:,
    all_consts:,
    all_types:,
    all_type_aliases:,
    all_ctors:,
    all_getters:,
    table:,
    ffi_metadata:,
  )
}

// -----------------------------------------------------------------------------
// Stage 1: Compute type parameters requiring `Hash` for `Eq` across types
// -----------------------------------------------------------------------------

fn compute_type_eq_hash_params(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
) -> Dict(#(String, String), Set(Int)) {
  let seeded =
    list.fold(modules, dict.new(), fn(acc, mod) {
      list.fold(mod.types, acc, fn(inner, td) {
        case td.external_type {
          Some(ExternalType(package:, type_name:)) -> {
            let req =
              ffi_meta.eq_requires_hash_params(
                ctx.ffi_metadata,
                package,
                type_name,
              )
            case set.is_empty(req) {
              True -> inner
              False -> dict.insert(inner, #(mod.module_name, td.name), req)
            }
          }
          None -> inner
        }
      })
    })
  iterate_type_eq_hash_params(modules, ctx, seeded, 1024)
}

fn iterate_type_eq_hash_params(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
  cur: Dict(#(String, String), Set(Int)),
  iters_left: Int,
) -> Dict(#(String, String), Set(Int)) {
  case iters_left <= 0 {
    True -> cur
    False -> {
      let #(next, changed) =
        list.fold(modules, #(cur, False), fn(acc, mod) {
          list.fold(mod.types, acc, fn(inner, td) {
            let #(map, ch) = inner
            case td.external_type, td.derive_eq_debug_hash, td.type_params {
              None, True, [_, ..] -> {
                let key = #(mod.module_name, td.name)
                let existing = case dict.get(map, key) {
                  Ok(s) -> s
                  Error(_) -> set.new()
                }
                let used_vars =
                  list.fold(td.variants, set.new(), fn(v_acc, v) {
                    list.fold(v.fields, v_acc, fn(f_acc, fld) {
                      collect_type_hash_vars(
                        fld.field_type,
                        mod.module_name,
                        map,
                        ctx,
                        f_acc,
                      )
                    })
                  })
                let new_indices =
                  list.index_fold(td.type_params, existing, fn(s, tp, idx) {
                    case set.contains(used_vars, tp) {
                      True -> set.insert(s, idx)
                      False -> s
                    }
                  })
                let grew = set.size(new_indices) > set.size(existing)
                let next_map = case set.is_empty(new_indices) {
                  True -> map
                  False -> dict.insert(map, key, new_indices)
                }
                #(next_map, ch || grew)
              }
              _, _, _ -> inner
            }
          })
        })
      case changed {
        True -> iterate_type_eq_hash_params(modules, ctx, next, iters_left - 1)
        False -> next
      }
    }
  }
}

fn collect_type_hash_vars(
  ty: IrType,
  cur_mod: String,
  type_map: Dict(#(String, String), Set(Int)),
  ctx: AnalyzeCtx,
  acc: Set(String),
) -> Set(String) {
  case expand_type_alias(ty, cur_mod, ctx) {
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let req_indices = case dict.get(type_map, #(resolved_mod, name)) {
        Ok(s) -> s
        Error(_) ->
          case lookup_external_type(resolved_mod, name, ctx) {
            Some(ext) ->
              ffi_meta.eq_requires_hash_params(
                ctx.ffi_metadata,
                ext.package,
                ext.type_name,
              )
            None -> set.new()
          }
      }
      let after_req =
        list.index_fold(args, acc, fn(s, arg_ty, idx) {
          case set.contains(req_indices, idx) {
            True -> collect_type_var_names(arg_ty, s)
            False -> s
          }
        })
      list.fold(args, after_req, fn(s, arg_ty) {
        collect_type_hash_vars(arg_ty, cur_mod, type_map, ctx, s)
      })
    }
    IrTypeList(inner) ->
      collect_type_hash_vars(inner, cur_mod, type_map, ctx, acc)
    IrTypeResult(ok_t, err_t) ->
      collect_type_hash_vars(
        err_t,
        cur_mod,
        type_map,
        ctx,
        collect_type_hash_vars(ok_t, cur_mod, type_map, ctx, acc),
      )
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) {
        collect_type_hash_vars(e, cur_mod, type_map, ctx, s)
      })
    IrTypeFn(_, _)
    | IrTypeVar(_)
    | IrTypeInt64
    | IrTypeDouble
    | IrTypeString
    | IrTypeBool
    | IrTypeUnit
    | IrTypeBitArray -> acc
  }
}

// -----------------------------------------------------------------------------
// Stage 2: Seed generic FFI bounds from MoonBit `.mbt` signatures
// -----------------------------------------------------------------------------

fn seed_all_fn_bounds(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
) -> Dict(#(String, String), FnTraitBounds) {
  list.fold(modules, dict.new(), fn(acc, mod) {
    list.fold(mod.functions, acc, fn(inner, f) {
      let key = #(mod.module_name, f.name)
      let seeded = case f.ffi, f.type_params {
        Some(PackageCall(pkg, target_fn)), [_, ..] ->
          case ffi_meta.lookup_function(ctx.ffi_metadata, pkg, target_fn) {
            Some(ext_meta) ->
              extract_ffi_bounds(f, mod.module_name, ext_meta, ctx)
            None -> empty_fn_bounds()
          }
        _, _ -> empty_fn_bounds()
      }
      dict.insert(inner, key, seeded)
    })
  })
}

fn extract_ffi_bounds(
  f: IrFunction,
  mod_name: String,
  ext_meta: ffi_meta.ExternalFnMeta,
  ctx: AnalyzeCtx,
) -> FnTraitBounds {
  let param_tys = list.map(f.params, fn(p) { p.param_type })
  let subst0 =
    list.fold(list.zip(ext_meta.param_types, param_tys), dict.new(), fn(s, pr) {
      unify_mbt_ir(pr.0, pr.1, mod_name, ctx, s)
    })
  let subst = case ext_meta.return_type {
    Some(ret_mbt) -> unify_mbt_ir(ret_mbt, f.return_type, mod_name, ctx, subst0)
    None -> subst0
  }
  let allowed = set.from_list(f.type_params)
  let raw =
    list.fold(ext_meta.type_params, empty_fn_bounds(), fn(acc, tp_entry) {
      let #(mbt_tp, traits) = tp_entry
      let matched_ir = dict.get(subst, mbt_tp) |> unwrap_or([])
      let raw_vars =
        list.fold(matched_ir, set.new(), fn(s, t) {
          collect_type_var_names(t, s)
        })
      let inspectable_vars =
        list.fold(matched_ir, set.new(), fn(s, t) {
          collect_inspectable_type_vars(t, mod_name, ctx, s)
        })
      let eq_v = case
        set.contains(traits, "Eq") || set.contains(traits, "Hash")
      {
        True -> set.union(acc.eq_vars, raw_vars)
        False -> acc.eq_vars
      }
      let dyn_v = case set.contains(traits, "ToDynamic") {
        True -> set.union(acc.to_dynamic_vars, raw_vars)
        False -> acc.to_dynamic_vars
      }
      let insp_v = case set.contains(traits, "GleamInspect") {
        True -> set.union(acc.inspect_vars, inspectable_vars)
        False -> acc.inspect_vars
      }
      FnTraitBounds(eq_vars: eq_v, to_dynamic_vars: dyn_v, inspect_vars: insp_v)
    })
  clamp_bounds(raw, allowed)
}

fn unify_mbt_ir(
  mbt_ty: MbtType,
  ir_ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  subst: Dict(String, List(IrType)),
) -> Dict(String, List(IrType)) {
  let expanded = expand_type_alias(ir_ty, cur_mod, ctx)
  case mbt_ty, expanded {
    ffi_meta.MbtVar(v), _ -> {
      let prev = dict.get(subst, v) |> unwrap_or([])
      dict.insert(subst, v, [expanded, ..prev])
    }
    ffi_meta.MbtNamed("GList", [m_in]), IrTypeList(ir_in) ->
      unify_mbt_ir(m_in, ir_in, cur_mod, ctx, subst)
    ffi_meta.MbtNamed("Result", [m_ok, m_err]), IrTypeResult(ir_ok, ir_err) ->
      unify_mbt_ir(
        m_err,
        ir_err,
        cur_mod,
        ctx,
        unify_mbt_ir(m_ok, ir_ok, cur_mod, ctx, subst),
      )
    ffi_meta.MbtNamed("Tuple1", [m_el]), IrTypeTuple([ir_el]) ->
      unify_mbt_ir(m_el, ir_el, cur_mod, ctx, subst)
    ffi_meta.MbtTuple(m_els), IrTypeTuple(ir_els) ->
      list.fold(list.zip(m_els, ir_els), subst, fn(s, pr) {
        unify_mbt_ir(pr.0, pr.1, cur_mod, ctx, s)
      })
    ffi_meta.MbtFn(m_ps, m_r), IrTypeFn(ir_ps, ir_r) -> {
      let s1 =
        list.fold(list.zip(m_ps, ir_ps), subst, fn(s, pr) {
          unify_mbt_ir(pr.0, pr.1, cur_mod, ctx, s)
        })
      unify_mbt_ir(m_r, ir_r, cur_mod, ctx, s1)
    }
    ffi_meta.MbtNamed(_, m_args), IrTypeNamed(args: ir_args, ..) ->
      list.fold(list.zip(m_args, ir_args), subst, fn(s, pr) {
        unify_mbt_ir(pr.0, pr.1, cur_mod, ctx, s)
      })
    _, _ -> subst
  }
}

// -----------------------------------------------------------------------------
// Stage 3: Cross-module fixpoint propagation
// -----------------------------------------------------------------------------

fn propagate_fixpoint(
  modules: List(IrModule),
  ctx: AnalyzeCtx,
  cur: Dict(#(String, String), FnTraitBounds),
  iters_left: Int,
) -> Dict(#(String, String), FnTraitBounds) {
  case iters_left <= 0 {
    True -> cur
    False -> {
      let #(next, changed) =
        list.fold(modules, #(cur, False), fn(acc, mod) {
          let const_env = build_module_const_env(mod)
          list.fold(mod.functions, acc, fn(inner, f) {
            let #(bmap, ch) = inner
            case f.ffi, f.type_params {
              None, [_, ..] -> {
                let key = #(mod.module_name, f.name)
                let existing = case dict.get(bmap, key) {
                  Ok(b) -> b
                  Error(_) -> empty_fn_bounds()
                }
                let allowed = set.from_list(f.type_params)
                let env0 =
                  list.fold(f.params, const_env, fn(e, p) {
                    dict.insert(e, p.name, p.param_type)
                  })
                let computed =
                  walk_stmts(
                    f.body,
                    env0,
                    mod.module_name,
                    f,
                    Some(f.return_type),
                    ctx,
                    bmap,
                    allowed,
                    existing,
                  )
                let clamped = clamp_bounds(computed, allowed)
                let grew = bounds_grew(existing, clamped)
                #(dict.insert(bmap, key, clamped), ch || grew)
              }
              _, _ -> inner
            }
          })
        })
      case changed {
        True -> propagate_fixpoint(modules, ctx, next, iters_left - 1)
        False -> next
      }
    }
  }
}

fn bounds_grew(old: FnTraitBounds, new: FnTraitBounds) -> Bool {
  set.size(new.eq_vars) > set.size(old.eq_vars)
  || set.size(new.to_dynamic_vars) > set.size(old.to_dynamic_vars)
  || set.size(new.inspect_vars) > set.size(old.inspect_vars)
}

fn clamp_bounds(b: FnTraitBounds, allowed: Set(String)) -> FnTraitBounds {
  FnTraitBounds(
    eq_vars: set.intersection(b.eq_vars, allowed),
    to_dynamic_vars: set.intersection(b.to_dynamic_vars, allowed),
    inspect_vars: set.intersection(b.inspect_vars, allowed),
  )
}

fn build_module_const_env(mod: IrModule) -> Dict(String, IrType) {
  list.fold(mod.constants, dict.new(), fn(acc, c) {
    dict.insert(acc, c.name, freshen_ir_type(c.value_type))
  })
}

fn freshen_ir_type(ty: IrType) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case is_free_var(v) {
        True -> ty
        False -> IrTypeVar("__free_" <> v)
      }
    IrTypeList(inner) -> IrTypeList(freshen_ir_type(inner))
    IrTypeResult(ok_t, err_t) ->
      IrTypeResult(freshen_ir_type(ok_t), freshen_ir_type(err_t))
    IrTypeTuple(els) -> IrTypeTuple(list.map(els, freshen_ir_type))
    IrTypeFn(ps, r) ->
      IrTypeFn(list.map(ps, freshen_ir_type), freshen_ir_type(r))
    IrTypeNamed(args:, ..) ->
      IrTypeNamed(..ty, args: list.map(args, freshen_ir_type))
    _ -> ty
  }
}

fn walk_stmts(
  stmts: List(IrStmt),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case stmts {
    [] -> acc
    [stmt, ..rest] -> {
      let stmt_expected = case rest {
        [] -> expected_ret
        _ -> None
      }
      case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let val_expected = case annotation {
            Some(_) -> annotation
            None -> stmt_expected
          }
          let acc1 =
            walk_expr(
              value,
              env,
              cur_mod,
              cur_fn,
              val_expected,
              ctx,
              bmap,
              allowed,
              acc,
            )
          let val_ty = case annotation {
            Some(t) -> Some(t)
            None -> infer_expr_type(value, env, cur_mod, ctx)
          }
          let env1 = case val_ty {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
          walk_stmts(
            rest,
            env1,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
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
            walk_expr(
              value,
              env,
              cur_mod,
              cur_fn,
              None,
              ctx,
              bmap,
              allowed,
              acc,
            )
          let env1 = case infer_expr_type(value, env, cur_mod, ctx) {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
          let env2 =
            list.fold(post_bindings, env1, fn(e, b) {
              case infer_expr_type(b.1, e, cur_mod, ctx) {
                Some(ty) -> dict.insert(e, b.0, ty)
                None -> e
              }
            })
          let acc2 = case guard_condition {
            Some(g) ->
              walk_expr(
                g,
                env2,
                cur_mod,
                cur_fn,
                Some(IrTypeBool),
                ctx,
                bmap,
                allowed,
                acc1,
              )
            None -> acc1
          }
          let acc3 = case abort_message {
            Some(m) ->
              walk_expr(
                m,
                env2,
                cur_mod,
                cur_fn,
                Some(IrTypeString),
                ctx,
                bmap,
                allowed,
                acc2,
              )
            None -> acc2
          }
          let acc4 =
            list.fold(post_bindings, acc3, fn(a, b) {
              walk_expr(b.1, env1, cur_mod, cur_fn, None, ctx, bmap, allowed, a)
            })
          walk_stmts(
            rest,
            env2,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc4,
          )
        }

        IrStmtAssert(condition:, abort_message:) -> {
          let acc1 =
            walk_expr(
              condition,
              env,
              cur_mod,
              cur_fn,
              Some(IrTypeBool),
              ctx,
              bmap,
              allowed,
              acc,
            )
          let acc2 = case abort_message {
            Some(m) ->
              walk_expr(
                m,
                env,
                cur_mod,
                cur_fn,
                Some(IrTypeString),
                ctx,
                bmap,
                allowed,
                acc1,
              )
            None -> acc1
          }
          walk_stmts(
            rest,
            env,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc2,
          )
        }

        IrStmtExpr(expr) -> {
          let acc1 =
            walk_expr(
              expr,
              env,
              cur_mod,
              cur_fn,
              stmt_expected,
              ctx,
              bmap,
              allowed,
              acc,
            )
          walk_stmts(
            rest,
            env,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc1,
          )
        }
      }
    }
  }
}

fn walk_expr(
  expr: IrExpr,
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case expr {
    IrBinOp(op: IrEq, left:, right:) | IrBinOp(op: IrNotEq, left:, right:) -> {
      let acc_children =
        walk_expr(left, env, cur_mod, cur_fn, None, ctx, bmap, allowed, acc)
        |> walk_expr(right, env, cur_mod, cur_fn, None, ctx, bmap, allowed, _)
      case
        is_nullary_multi_variant_ctor(left, cur_mod, ctx),
        is_nullary_multi_variant_ctor(right, cur_mod, ctx)
      {
        False, True | True, False -> acc_children
        _, _ -> {
          let next_eq = case
            infer_expr_type(left, env, cur_mod, ctx),
            infer_expr_type(right, env, cur_mod, ctx)
          {
            Some(ty), _ -> collect_type_var_names(ty, acc_children.eq_vars)
            None, Some(ty) -> collect_type_var_names(ty, acc_children.eq_vars)
            None, None -> acc_children.eq_vars
          }
          FnTraitBounds(..acc_children, eq_vars: next_eq)
        }
      }
    }

    IrBinOp(left:, right:, ..) ->
      walk_expr(left, env, cur_mod, cur_fn, None, ctx, bmap, allowed, acc)
      |> walk_expr(right, env, cur_mod, cur_fn, None, ctx, bmap, allowed, _)

    IrEcho(expr: inner, message:, ..) -> {
      let acc1 =
        walk_expr(inner, env, cur_mod, cur_fn, None, ctx, bmap, allowed, acc)
      let acc2 = case message {
        Some(m) ->
          walk_expr(
            m,
            env,
            cur_mod,
            cur_fn,
            Some(IrTypeString),
            ctx,
            bmap,
            allowed,
            acc1,
          )
        None -> acc1
      }
      let next_insp = case infer_expr_type(inner, env, cur_mod, ctx) {
        Some(ty) ->
          collect_inspectable_type_vars(ty, cur_mod, ctx, acc2.inspect_vars)
        None ->
          list.fold(
            [
              cur_fn.return_type,
              ..list.map(cur_fn.params, fn(p) { p.param_type })
            ],
            acc2.inspect_vars,
            fn(s, t) { collect_inspectable_type_vars(t, cur_mod, ctx, s) },
          )
      }
      FnTraitBounds(..acc2, inspect_vars: next_insp)
    }

    IrCall(function:, args:) ->
      walk_call(
        function,
        args,
        env,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrContinue(args) -> {
      let paired_params = list.map(cur_fn.params, fn(p) { Some(p.param_type) })
      walk_positional_args(
        args,
        paired_params,
        env,
        cur_mod,
        cur_fn,
        ctx,
        bmap,
        allowed,
        acc,
      )
    }

    IrVar(name) ->
      case dict.has_key(env, name), expected_ret {
        False, Some(IrTypeFn(exp_ps, exp_r)) ->
          walk_bare_fn_ref(cur_mod, name, exp_ps, exp_r, bmap, ctx, acc)
        _, _ -> acc
      }

    IrModuleRef(target_module:, symbol:, ..) ->
      case expected_ret {
        Some(IrTypeFn(exp_ps, exp_r)) ->
          walk_bare_fn_ref(target_module, symbol, exp_ps, exp_r, bmap, ctx, acc)
        _ -> acc
      }

    IrFn(params:, body:, ..) -> {
      let #(exp_ps, exp_r) = case expected_ret {
        Some(IrTypeFn(ps, r)) -> #(list.map(ps, Some), Some(r))
        _ -> #([], None)
      }
      let fn_env = bind_fn_param_types_opt(params, exp_ps, env)
      walk_stmts(body, fn_env, cur_mod, cur_fn, exp_r, ctx, bmap, allowed, acc)
    }

    IrBlock(stmts) ->
      walk_stmts(
        stmts,
        env,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrForLoop(bindings:, body:) -> {
      let #(acc1, env1) =
        list.fold(bindings, #(acc, env), fn(st, b) {
          let #(a, e) = st
          let a1 =
            walk_expr(b.1, env, cur_mod, cur_fn, None, ctx, bmap, allowed, a)
          let e1 = case infer_expr_type(b.1, env, cur_mod, ctx) {
            Some(ty) -> dict.insert(e, b.0, ty)
            None -> e
          }
          #(a1, e1)
        })
      walk_stmts(
        body,
        env1,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc1,
      )
    }

    IrMatch(subjects:, clauses:) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) {
          walk_expr(s, env, cur_mod, cur_fn, None, ctx, bmap, allowed, a)
        })
      let subj_tys =
        list.map(subjects, fn(s) { infer_expr_type(s, env, cur_mod, ctx) })
      list.fold(clauses, acc1, fn(a, c) {
        let c_env = case c.patterns {
          [first_alt, ..] ->
            list.fold(list.zip(first_alt, subj_tys), env, fn(e, pair) {
              case pair.1 {
                Some(ty) -> bind_pattern_types(pair.0, ty, cur_mod, ctx, e)
                None -> e
              }
            })
          [] -> env
        }
        let c_env2 =
          list.fold(c.prefix_bindings, c_env, fn(e, b) {
            case infer_expr_type(b.1, e, cur_mod, ctx) {
              Some(ty) -> dict.insert(e, b.0, ty)
              None -> e
            }
          })
        let a1 = case c.guard {
          Some(g) ->
            walk_expr(
              g,
              c_env2,
              cur_mod,
              cur_fn,
              Some(IrTypeBool),
              ctx,
              bmap,
              allowed,
              a,
            )
          None -> a
        }
        let a2 =
          list.fold(c.prefix_bindings, a1, fn(x, b) {
            walk_expr(b.1, c_env, cur_mod, cur_fn, None, ctx, bmap, allowed, x)
          })
        walk_expr(
          c.body,
          c_env2,
          cur_mod,
          cur_fn,
          expected_ret,
          ctx,
          bmap,
          allowed,
          a2,
        )
      })
    }

    IrNegateInt(inner)
    | IrNegateBool(inner)
    | IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..) ->
      walk_expr(inner, env, cur_mod, cur_fn, None, ctx, bmap, allowed, acc)

    IrBreak(inner) ->
      walk_expr(
        inner,
        env,
        cur_mod,
        cur_fn,
        expected_ret,
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrTuple(els) ->
      list.fold(els, acc, fn(a, e) {
        walk_expr(e, env, cur_mod, cur_fn, None, ctx, bmap, allowed, a)
      })

    IrList(elements:, tail:) -> {
      let elem_expected = case expected_ret {
        Some(IrTypeList(inner)) -> Some(inner)
        _ -> None
      }
      let acc1 =
        list.fold(elements, acc, fn(a, e) {
          walk_expr(
            e,
            env,
            cur_mod,
            cur_fn,
            elem_expected,
            ctx,
            bmap,
            allowed,
            a,
          )
        })
      case tail {
        Some(t) ->
          walk_expr(
            t,
            env,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc1,
          )
        None -> acc1
      }
    }

    IrBitString(segments:) ->
      list.fold(segments, acc, fn(a, seg) {
        let a1 =
          walk_expr(seg.0, env, cur_mod, cur_fn, None, ctx, bmap, allowed, a)
        list.fold(seg.1, a1, fn(inner_a, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              walk_expr(
                size_expr,
                env,
                cur_mod,
                cur_fn,
                Some(IrTypeInt64),
                ctx,
                bmap,
                allowed,
                inner_a,
              )
            _ -> inner_a
          }
        })
      })

    IrAbort(message: Some(m), ..) ->
      walk_expr(
        m,
        env,
        cur_mod,
        cur_fn,
        Some(IrTypeString),
        ctx,
        bmap,
        allowed,
        acc,
      )

    IrAbort(message: None, ..)
    | IrConstructor(..)
    | IrInt(_)
    | IrFloat(_)
    | IrString(_)
    | IrBool(_)
    | IrUnit -> acc
  }
}

fn walk_call(
  function: IrExpr,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case function {
    IrVar(name) ->
      case dict.get(env, name) {
        Ok(var_ty) ->
          case var_ty {
            IrTypeFn(params: exp_ps, ..) -> {
              let arg_vals = list.map(args, fn(a) { a.value })
              walk_positional_args(
                arg_vals,
                list.map(exp_ps, Some),
                env,
                cur_mod,
                cur_fn,
                ctx,
                bmap,
                allowed,
                acc,
              )
            }
            _ ->
              walk_untyped_call_args(
                args,
                env,
                cur_mod,
                cur_fn,
                ctx,
                bmap,
                allowed,
                acc,
              )
          }
        Error(_) ->
          case dict.get(ctx.all_fns, #(cur_mod, name)) {
            Ok(callee) ->
              walk_known_fn_call(
                cur_mod,
                callee,
                args,
                env,
                cur_mod,
                cur_fn,
                expected_ret,
                ctx,
                bmap,
                allowed,
                acc,
              )
            Error(_) ->
              walk_untyped_call_args(
                args,
                env,
                cur_mod,
                cur_fn,
                ctx,
                bmap,
                allowed,
                acc,
              )
          }
      }

    IrModuleRef(target_module:, symbol:, ..) ->
      case dict.get(ctx.all_fns, #(target_module, symbol)) {
        Ok(callee) ->
          walk_known_fn_call(
            target_module,
            callee,
            args,
            env,
            cur_mod,
            cur_fn,
            expected_ret,
            ctx,
            bmap,
            allowed,
            acc,
          )
        Error(_) ->
          walk_untyped_call_args(
            args,
            env,
            cur_mod,
            cur_fn,
            ctx,
            bmap,
            allowed,
            acc,
          )
      }

    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case lookup_ctor(ctx, ctor_mod, name) {
        Some(#(td, variant)) -> {
          let field_params =
            list.map(variant.fields, fn(f) {
              IrParam(
                label: f.label,
                name: option.unwrap(f.label, "_"),
                param_type: f.field_type,
              )
            })
          let ordered_args = align_ir_call_args(field_params, args)
          let subst0 =
            unify_aligned_args(field_params, ordered_args, env, cur_mod, ctx)
          let td_type =
            IrTypeNamed(
              module_alias: None,
              package: "",
              module: ctor_mod,
              name: td.name,
              args: list.map(td.type_params, IrTypeVar),
            )
          let subst = case expected_ret {
            Some(exp_ty) ->
              unify_ir_types(td_type, exp_ty, cur_mod, ctx, subst0)
            None -> subst0
          }
          let exp_types =
            list.map(field_params, fn(p) {
              Some(apply_call_ret_subst(p.param_type, subst))
            })
          walk_aligned_opt_args(
            ordered_args,
            exp_types,
            env,
            cur_mod,
            cur_fn,
            ctx,
            bmap,
            allowed,
            acc,
          )
        }
        None ->
          walk_untyped_call_args(
            args,
            env,
            cur_mod,
            cur_fn,
            ctx,
            bmap,
            allowed,
            acc,
          )
      }
    }

    _ -> {
      let acc1 =
        walk_expr(function, env, cur_mod, cur_fn, None, ctx, bmap, allowed, acc)
      walk_untyped_call_args(
        args,
        env,
        cur_mod,
        cur_fn,
        ctx,
        bmap,
        allowed,
        acc1,
      )
    }
  }
}

fn walk_known_fn_call(
  callee_mod: String,
  callee: IrFunction,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  expected_ret: Option(IrType),
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  let ordered_args = align_ir_call_args(callee.params, args)
  let subst0 =
    unify_aligned_args(callee.params, ordered_args, env, cur_mod, ctx)
  let subst = case expected_ret {
    Some(exp_ty) ->
      unify_ir_types(callee.return_type, exp_ty, cur_mod, ctx, subst0)
    None -> subst0
  }
  let callee_bounds = case dict.get(bmap, #(callee_mod, callee.name)) {
    Ok(b) -> b
    Error(_) -> empty_fn_bounds()
  }
  let acc1 =
    apply_callee_bounds_via_subst(callee_bounds, subst, cur_mod, ctx, acc)
  let exp_param_tys =
    list.map(callee.params, fn(p) {
      Some(apply_call_ret_subst(p.param_type, subst))
    })
  walk_aligned_opt_args(
    ordered_args,
    exp_param_tys,
    env,
    cur_mod,
    cur_fn,
    ctx,
    bmap,
    allowed,
    acc1,
  )
}

fn walk_bare_fn_ref(
  ref_mod: String,
  ref_name: String,
  exp_params: List(IrType),
  exp_ret: IrType,
  bmap: Dict(#(String, String), FnTraitBounds),
  ctx: AnalyzeCtx,
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case
    dict.get(ctx.all_fns, #(ref_mod, ref_name)),
    dict.get(bmap, #(ref_mod, ref_name))
  {
    Ok(ref_fn), Ok(ref_bounds) -> {
      let ref_fn_ty =
        IrTypeFn(
          params: list.map(ref_fn.params, fn(p) { p.param_type }),
          return: ref_fn.return_type,
        )
      let subst =
        unify_ir_types(
          ref_fn_ty,
          IrTypeFn(exp_params, exp_ret),
          ref_mod,
          ctx,
          dict.new(),
        )
      apply_callee_bounds_via_subst(ref_bounds, subst, ref_mod, ctx, acc)
    }
    _, _ -> acc
  }
}

fn apply_callee_bounds_via_subst(
  callee_bounds: FnTraitBounds,
  subst: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
  acc: FnTraitBounds,
) -> FnTraitBounds {
  let next_eq =
    set.fold(callee_bounds.eq_vars, acc.eq_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) -> collect_type_var_names(caller_ty, s)
        Error(_) -> s
      }
    })
  let next_dyn =
    set.fold(callee_bounds.to_dynamic_vars, acc.to_dynamic_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) -> collect_type_var_names(caller_ty, s)
        Error(_) -> s
      }
    })
  let next_insp =
    set.fold(callee_bounds.inspect_vars, acc.inspect_vars, fn(s, tp) {
      case dict.get(subst, tp) {
        Ok(caller_ty) ->
          collect_inspectable_type_vars(caller_ty, cur_mod, ctx, s)
        Error(_) -> s
      }
    })
  FnTraitBounds(
    eq_vars: next_eq,
    to_dynamic_vars: next_dyn,
    inspect_vars: next_insp,
  )
}

fn unify_aligned_args(
  params: List(IrParam),
  ordered_args: List(Option(IrExpr)),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Dict(String, IrType) {
  list.fold(list.zip(params, ordered_args), dict.new(), fn(s, pair) {
    let #(pi, maybe_arg) = pair
    case maybe_arg {
      Some(arg_val) ->
        case infer_expr_type(arg_val, env, cur_mod, ctx) {
          Some(arg_ty) -> unify_ir_types(pi.param_type, arg_ty, cur_mod, ctx, s)
          None -> s
        }
      None -> s
    }
  })
}

fn walk_aligned_opt_args(
  ordered_args: List(Option(IrExpr)),
  expected_types: List(Option(IrType)),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  list.fold(list.zip(ordered_args, expected_types), acc, fn(a, pair) {
    case pair.0 {
      Some(arg_val) ->
        walk_expr(arg_val, env, cur_mod, cur_fn, pair.1, ctx, bmap, allowed, a)
      None -> a
    }
  })
}

fn walk_positional_args(
  args: List(IrExpr),
  expected_types: List(Option(IrType)),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  walk_positional_loop(
    args,
    expected_types,
    env,
    cur_mod,
    cur_fn,
    ctx,
    bmap,
    allowed,
    acc,
  )
}

fn walk_positional_loop(
  args: List(IrExpr),
  expected_types: List(Option(IrType)),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  case args {
    [] -> acc
    [arg, ..rest_args] -> {
      let #(exp_ty, rest_exps) = case expected_types {
        [e, ..re] -> #(e, re)
        [] -> #(None, [])
      }
      let next_acc =
        walk_expr(arg, env, cur_mod, cur_fn, exp_ty, ctx, bmap, allowed, acc)
      walk_positional_loop(
        rest_args,
        rest_exps,
        env,
        cur_mod,
        cur_fn,
        ctx,
        bmap,
        allowed,
        next_acc,
      )
    }
  }
}

fn walk_untyped_call_args(
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  cur_fn: IrFunction,
  ctx: AnalyzeCtx,
  bmap: Dict(#(String, String), FnTraitBounds),
  allowed: Set(String),
  acc: FnTraitBounds,
) -> FnTraitBounds {
  list.fold(args, acc, fn(a, arg) {
    walk_expr(arg.value, env, cur_mod, cur_fn, None, ctx, bmap, allowed, a)
  })
}

// -----------------------------------------------------------------------------
// Expression type inference & pattern binding
// -----------------------------------------------------------------------------

fn infer_expr_type(
  expr: IrExpr,
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case expr {
    IrInt(_) -> Some(IrTypeInt64)
    IrFloat(_) -> Some(IrTypeDouble)
    IrString(_) -> Some(IrTypeString)
    IrBool(_) -> Some(IrTypeBool)
    IrUnit -> Some(IrTypeUnit)
    IrBitString(_) -> Some(IrTypeBitArray)
    IrVar(name) ->
      case dict.get(env, name) {
        Ok(ty) -> Some(ty)
        Error(_) ->
          case dict.get(ctx.all_consts, #(cur_mod, name)) {
            Ok(c_ty) -> Some(freshen_ir_type(c_ty))
            Error(_) ->
              case dict.get(ctx.all_fns, #(cur_mod, name)) {
                Ok(f) -> Some(freshen_fn_type(f))
                Error(_) -> None
              }
          }
      }
    IrModuleRef(target_module:, symbol:, ..) ->
      case dict.get(ctx.all_consts, #(target_module, symbol)) {
        Ok(c_ty) -> Some(freshen_ir_type(c_ty))
        Error(_) ->
          case dict.get(ctx.all_fns, #(target_module, symbol)) {
            Ok(f) -> Some(freshen_fn_type(f))
            Error(_) -> None
          }
      }
    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case lookup_ctor(ctx, ctor_mod, name) {
        Some(#(td, variant)) ->
          case variant.fields {
            [] ->
              Some(IrTypeNamed(
                module_alias: None,
                package: "",
                module: ctor_mod,
                name: td.name,
                args: list.map(td.type_params, fn(tp) {
                  IrTypeVar("__free_" <> tp)
                }),
              ))
            _ -> None
          }
        None -> None
      }
    }
    IrTuple(els) -> {
      let inferred =
        list.map(els, fn(e) { infer_expr_type(e, env, cur_mod, ctx) })
      case list.all(inferred, option.is_some) {
        True ->
          Some(IrTypeTuple(list.filter_map(inferred, option.to_result(_, Nil))))
        False -> None
      }
    }
    IrTupleIndex(tuple:, index:) ->
      case
        option.map(infer_expr_type(tuple, env, cur_mod, ctx), expand_type_alias(
          _,
          cur_mod,
          ctx,
        ))
      {
        Some(IrTypeTuple(els)) -> list_at_idx(els, index)
        _ -> None
      }
    IrList(elements:, tail:) ->
      case tail {
        Some(t) -> infer_expr_type(t, env, cur_mod, ctx)
        None ->
          case elements {
            [first, ..] ->
              option.map(infer_expr_type(first, env, cur_mod, ctx), IrTypeList)
            [] -> Some(IrTypeList(IrTypeVar("__free_elem")))
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
    IrEcho(expr: inner, ..) -> infer_expr_type(inner, env, cur_mod, ctx)
    IrGetterCall(receiver:, field:) ->
      case
        option.map(
          infer_expr_type(receiver, env, cur_mod, ctx),
          expand_type_alias(_, cur_mod, ctx),
        )
      {
        Some(IrTypeNamed(module:, name:, args:, ..)) -> {
          let target_mod = case module {
            "" -> cur_mod
            m -> m
          }
          case dict.get(ctx.all_getters, #(target_mod, name, field)) {
            Ok(sig) -> {
              let subst =
                list.zip(sig.type_params, args)
                |> dict.from_list
              Some(apply_ir_subst(sig.return_type, subst))
            }
            Error(_) -> None
          }
        }
        _ -> None
      }
    IrCall(function:, args:) ->
      infer_call_expr_type(function, args, env, cur_mod, ctx)
    IrBlock(stmts) -> infer_stmts_tail_type(stmts, env, cur_mod, ctx)
    IrMatch(subjects:, clauses:) -> {
      let subj_tys =
        list.map(subjects, fn(s) { infer_expr_type(s, env, cur_mod, ctx) })
      list.find_map(clauses, fn(c) {
        let c_env = case c.patterns {
          [first_alt, ..] ->
            list.fold(list.zip(first_alt, subj_tys), env, fn(e, pair) {
              case pair.1 {
                Some(ty) -> bind_pattern_types(pair.0, ty, cur_mod, ctx, e)
                None -> e
              }
            })
          [] -> env
        }
        let c_env2 =
          list.fold(c.prefix_bindings, c_env, fn(e, b) {
            case infer_expr_type(b.1, e, cur_mod, ctx) {
              Some(ty) -> dict.insert(e, b.0, ty)
              None -> e
            }
          })
        case infer_expr_type(c.body, c_env2, cur_mod, ctx) {
          Some(ty) -> Ok(ty)
          None -> Error(Nil)
        }
      })
      |> option.from_result
    }
    IrForLoop(bindings:, body:) -> {
      let env1 =
        list.fold(bindings, env, fn(e, b) {
          case infer_expr_type(b.1, env, cur_mod, ctx) {
            Some(ty) -> dict.insert(e, b.0, ty)
            None -> e
          }
        })
      infer_for_break_type(body, env1, cur_mod, ctx)
    }
    IrBreak(inner) -> infer_expr_type(inner, env, cur_mod, ctx)
    IrFn(params:, return_type:, body:) ->
      case list.all(params, fn(p) { option.is_some(p.param_type) }) {
        False -> None
        True -> {
          let p_tys =
            list.filter_map(params, fn(p) {
              option.to_result(p.param_type, Nil)
            })
          let ret = case return_type {
            Some(r) -> Some(r)
            None -> {
              let fn_env =
                list.fold(params, env, fn(e, p) {
                  case p.param_type {
                    Some(pt) -> dict.insert(e, p.name, pt)
                    None -> e
                  }
                })
              infer_stmts_tail_type(body, fn_env, cur_mod, ctx)
            }
          }
          option.map(ret, fn(r) { IrTypeFn(p_tys, r) })
        }
      }
    _ -> None
  }
}

fn freshen_fn_type(f: IrFunction) -> IrType {
  let subst =
    list.fold(f.type_params, dict.new(), fn(acc, tp) {
      dict.insert(acc, tp, IrTypeVar("__free_" <> tp))
    })
  IrTypeFn(
    params: list.map(f.params, fn(p) { apply_ir_subst(p.param_type, subst) }),
    return: apply_ir_subst(f.return_type, subst),
  )
}

fn infer_call_expr_type(
  function: IrExpr,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case function {
    IrVar(name) ->
      case dict.get(env, name) {
        Ok(IrTypeFn(return: ret, ..)) -> Some(ret)
        Ok(_) -> None
        Error(_) ->
          case dict.get(ctx.all_fns, #(cur_mod, name)) {
            Ok(callee) -> instantiate_fn_return(callee, args, env, cur_mod, ctx)
            Error(_) -> None
          }
      }
    IrModuleRef(target_module:, symbol:, ..) ->
      case dict.get(ctx.all_fns, #(target_module, symbol)) {
        Ok(callee) -> instantiate_fn_return(callee, args, env, cur_mod, ctx)
        Error(_) -> None
      }
    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case name, args {
        "Ok", [ok_arg] ->
          option.map(infer_expr_type(ok_arg.value, env, cur_mod, ctx), fn(t) {
            IrTypeResult(t, IrTypeVar("__free_err"))
          })
        "Err", [err_arg] ->
          option.map(infer_expr_type(err_arg.value, env, cur_mod, ctx), fn(t) {
            IrTypeResult(IrTypeVar("__free_ok"), t)
          })
        _, _ ->
          case lookup_ctor(ctx, ctor_mod, name) {
            Some(#(td, variant)) -> {
              let field_params =
                list.map(variant.fields, fn(f) {
                  IrParam(
                    label: f.label,
                    name: option.unwrap(f.label, "_"),
                    param_type: f.field_type,
                  )
                })
              let ordered = align_ir_call_args(field_params, args)
              let subst =
                unify_aligned_args(field_params, ordered, env, cur_mod, ctx)
              let raw_ret =
                IrTypeNamed(
                  module_alias: None,
                  package: "",
                  module: ctor_mod,
                  name: td.name,
                  args: list.map(td.type_params, IrTypeVar),
                )
              Some(apply_call_ret_subst(raw_ret, subst))
            }
            None -> None
          }
      }
    }
    _ ->
      case infer_expr_type(function, env, cur_mod, ctx) {
        Some(IrTypeFn(return: ret, ..)) -> Some(ret)
        _ -> None
      }
  }
}

fn instantiate_fn_return(
  callee: IrFunction,
  args: List(IrCallArg),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  let ordered = align_ir_call_args(callee.params, args)
  let subst = unify_aligned_args(callee.params, ordered, env, cur_mod, ctx)
  Some(apply_call_ret_subst(callee.return_type, subst))
}

fn infer_stmts_tail_type(
  stmts: List(IrStmt),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case stmts {
    [] -> None
    [IrStmtExpr(e)] -> infer_expr_type(e, env, cur_mod, ctx)
    [IrStmtLet(pattern:, annotation:, value:)] -> {
      let _ = pattern
      case annotation {
        Some(t) -> Some(t)
        None -> infer_expr_type(value, env, cur_mod, ctx)
      }
    }
    [IrStmtGuard(value:, ..)] -> infer_expr_type(value, env, cur_mod, ctx)
    [stmt, ..rest] -> {
      let next_env = case stmt {
        IrStmtLet(pattern:, annotation:, value:) -> {
          let val_ty = case annotation {
            Some(t) -> Some(t)
            None -> infer_expr_type(value, env, cur_mod, ctx)
          }
          case val_ty {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
        }
        IrStmtGuard(value:, pattern:, post_bindings:, ..) -> {
          let env1 = case infer_expr_type(value, env, cur_mod, ctx) {
            Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
            None -> env
          }
          list.fold(post_bindings, env1, fn(e, b) {
            case infer_expr_type(b.1, e, cur_mod, ctx) {
              Some(ty) -> dict.insert(e, b.0, ty)
              None -> e
            }
          })
        }
        IrStmtAssert(_, _) | IrStmtExpr(_) -> env
      }
      infer_stmts_tail_type(rest, next_env, cur_mod, ctx)
    }
  }
}

fn infer_for_break_type(
  stmts: List(IrStmt),
  env: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Option(IrType) {
  case stmts {
    [] -> None
    [stmt, ..rest] -> {
      let found = case stmt {
        IrStmtExpr(IrBreak(val)) -> infer_expr_type(val, env, cur_mod, ctx)
        IrStmtExpr(IrMatch(subjects:, clauses:)) -> {
          let subj_tys =
            list.map(subjects, fn(s) { infer_expr_type(s, env, cur_mod, ctx) })
          list.find_map(clauses, fn(c) {
            let c_env = case c.patterns {
              [first_alt, ..] ->
                list.fold(list.zip(first_alt, subj_tys), env, fn(e, pair) {
                  case pair.1 {
                    Some(ty) -> bind_pattern_types(pair.0, ty, cur_mod, ctx, e)
                    None -> e
                  }
                })
              [] -> env
            }
            case infer_expr_type(c.body, c_env, cur_mod, ctx) {
              Some(ty) -> Ok(ty)
              None -> Error(Nil)
            }
          })
          |> option.from_result
        }
        _ -> None
      }
      case found {
        Some(_) -> found
        None -> {
          let next_env = case stmt {
            IrStmtLet(pattern:, annotation:, value:) -> {
              let val_ty = case annotation {
                Some(t) -> Some(t)
                None -> infer_expr_type(value, env, cur_mod, ctx)
              }
              case val_ty {
                Some(ty) -> bind_pattern_types(pattern, ty, cur_mod, ctx, env)
                None -> env
              }
            }
            _ -> env
          }
          infer_for_break_type(rest, next_env, cur_mod, ctx)
        }
      }
    }
  }
}

fn bind_pattern_types(
  pat: IrPattern,
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  env: Dict(String, IrType),
) -> Dict(String, IrType) {
  let expanded_ty = expand_type_alias(ty, cur_mod, ctx)
  case pat, expanded_ty {
    IrPatVar(name), _ -> dict.insert(env, name, ty)
    IrPatAs(inner, alias), _ ->
      bind_pattern_types(inner, ty, cur_mod, ctx, dict.insert(env, alias, ty))
    IrPatTuple(pats), IrTypeTuple(tys) ->
      list.fold(list.zip(pats, tys), env, fn(e, pair) {
        bind_pattern_types(pair.0, pair.1, cur_mod, ctx, e)
      })
    IrPatVariant(constructor: "Cons", args: [h_arg, t_arg], ..), IrTypeList(in_)
    ->
      env
      |> bind_pattern_types(h_arg.pattern, in_, cur_mod, ctx, _)
      |> bind_pattern_types(t_arg.pattern, IrTypeList(in_), cur_mod, ctx, _)
    IrPatVariant(constructor: "Ok", args: [ok_arg], ..), IrTypeResult(ok_t, _)
    -> bind_pattern_types(ok_arg.pattern, ok_t, cur_mod, ctx, env)
    IrPatVariant(constructor: "Err", args: [err_arg], ..),
      IrTypeResult(_, err_t)
    -> bind_pattern_types(err_arg.pattern, err_t, cur_mod, ctx, env)
    IrPatVariant(target_module:, constructor:, args:, ..),
      IrTypeNamed(module: ty_mod, name: ty_name, args: ty_args, ..)
    -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      let resolved_ty_mod = case ty_mod {
        "" -> cur_mod
        m -> m
      }
      case lookup_ctor(ctx, ctor_mod, constructor) {
        Some(#(td, variant))
          if ctor_mod == resolved_ty_mod
          && { td.name == ty_name || td.unmangled_name == ty_name }
        -> {
          let subst =
            list.zip(td.type_params, ty_args)
            |> dict.from_list
          bind_variant_pat_args(args, variant.fields, subst, cur_mod, ctx, env)
        }
        _ -> env
      }
    }
    _, _ -> env
  }
}

fn bind_variant_pat_args(
  pat_args: List(IrPatArg),
  fields: List(ir.IrVariantField),
  subst: Dict(String, IrType),
  cur_mod: String,
  ctx: AnalyzeCtx,
  env: Dict(String, IrType),
) -> Dict(String, IrType) {
  let #(labelled, rev_pos) =
    list.fold(pat_args, #(dict.new(), []), fn(acc, arg) {
      let #(lm, pos) = acc
      case arg.label {
        Some(lbl) -> #(dict.insert(lm, lbl, arg.pattern), pos)
        None -> #(lm, [arg.pattern, ..pos])
      }
    })
  let #(next_env, _) =
    list.fold(fields, #(env, list.reverse(rev_pos)), fn(st, fld) {
      let #(e, pos_q) = st
      let fld_ty = apply_ir_subst(fld.field_type, subst)
      let matched_pat = case fld.label, fld.unmangled_label {
        Some(lbl), _ ->
          case dict.get(labelled, lbl) {
            Ok(p) -> #(Some(p), pos_q)
            Error(_) ->
              case fld.unmangled_label {
                Some(ul) ->
                  case dict.get(labelled, ul) {
                    Ok(p) -> #(Some(p), pos_q)
                    Error(_) -> pop_positional(pos_q)
                  }
                None -> pop_positional(pos_q)
              }
          }
        None, Some(ul) ->
          case dict.get(labelled, ul) {
            Ok(p) -> #(Some(p), pos_q)
            Error(_) -> pop_positional(pos_q)
          }
        None, None -> pop_positional(pos_q)
      }
      case matched_pat.0 {
        Some(pat) -> #(
          bind_pattern_types(pat, fld_ty, cur_mod, ctx, e),
          matched_pat.1,
        )
        None -> #(e, matched_pat.1)
      }
    })
  next_env
}

fn pop_positional(
  pos_q: List(IrPattern),
) -> #(Option(IrPattern), List(IrPattern)) {
  case pos_q {
    [p, ..rest] -> #(Some(p), rest)
    [] -> #(None, [])
  }
}

fn bind_fn_param_types_opt(
  params: List(ir.IrFnParam),
  expected: List(Option(IrType)),
  env: Dict(String, IrType),
) -> Dict(String, IrType) {
  case params {
    [] -> env
    [p, ..rest_ps] -> {
      let #(exp_opt, rest_exp) = case expected {
        [e, ..re] -> #(e, re)
        [] -> #(None, [])
      }
      let next_env = case option.or(p.param_type, exp_opt) {
        Some(ty) -> dict.insert(env, p.name, ty)
        None -> env
      }
      bind_fn_param_types_opt(rest_ps, rest_exp, next_env)
    }
  }
}

// -----------------------------------------------------------------------------
// Unification, substitution, and lookup helpers
// -----------------------------------------------------------------------------

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

fn unify_ir_types(
  pattern_ty: IrType,
  concrete_ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  subst: Dict(String, IrType),
) -> Dict(String, IrType) {
  let pat_exp = expand_type_alias(pattern_ty, cur_mod, ctx)
  let con_exp = expand_type_alias(concrete_ty, cur_mod, ctx)
  case pat_exp, con_exp {
    IrTypeVar(v), _ ->
      case is_free_var(v) {
        True -> subst
        False ->
          case con_exp {
            IrTypeVar(cv) ->
              case is_free_var(cv) {
                True -> subst
                False -> insert_or_merge_subst(subst, v, con_exp)
              }
            _ -> insert_or_merge_subst(subst, v, con_exp)
          }
      }
    IrTypeList(p_in), IrTypeList(c_in) ->
      unify_ir_types(p_in, c_in, cur_mod, ctx, subst)
    IrTypeResult(po, pe), IrTypeResult(co, ce) ->
      unify_ir_types(
        pe,
        ce,
        cur_mod,
        ctx,
        unify_ir_types(po, co, cur_mod, ctx, subst),
      )
    IrTypeTuple(ps), IrTypeTuple(cs) ->
      list.fold(list.zip(ps, cs), subst, fn(s, pair) {
        unify_ir_types(pair.0, pair.1, cur_mod, ctx, s)
      })
    IrTypeFn(pp, pr), IrTypeFn(cp, cr) -> {
      let s1 =
        list.fold(list.zip(pp, cp), subst, fn(s, pair) {
          unify_ir_types(pair.0, pair.1, cur_mod, ctx, s)
        })
      unify_ir_types(pr, cr, cur_mod, ctx, s1)
    }
    IrTypeNamed(module: pm, name: pn, args: pas, ..),
      IrTypeNamed(module: cm, name: cn, args: cas, ..)
      if pm == cm && pn == cn
    ->
      list.fold(list.zip(pas, cas), subst, fn(s, pair) {
        unify_ir_types(pair.0, pair.1, cur_mod, ctx, s)
      })
    _, _ -> subst
  }
}

fn is_free_var(name: String) -> Bool {
  case name {
    "__free_" <> _ -> True
    _ -> False
  }
}

fn insert_or_merge_subst(
  subst: Dict(String, IrType),
  key: String,
  val: IrType,
) -> Dict(String, IrType) {
  case dict.get(subst, key) {
    Ok(existing) -> dict.insert(subst, key, merge_bound_type(existing, val))
    Error(_) -> dict.insert(subst, key, val)
  }
}

fn merge_bound_type(existing: IrType, new: IrType) -> IrType {
  case existing, new {
    IrTypeVar(v), _ ->
      case is_free_var(v) {
        True -> new
        False -> existing
      }
    IrTypeList(e_in), IrTypeList(n_in) ->
      IrTypeList(merge_bound_type(e_in, n_in))
    IrTypeResult(eo, ee), IrTypeResult(no, ne) ->
      IrTypeResult(merge_bound_type(eo, no), merge_bound_type(ee, ne))
    IrTypeTuple(es), IrTypeTuple(ns) ->
      case list.length(es) == list.length(ns) {
        True ->
          IrTypeTuple(
            list.map(list.zip(es, ns), fn(p) { merge_bound_type(p.0, p.1) }),
          )
        False -> existing
      }
    IrTypeFn(ep, er), IrTypeFn(np, nr) ->
      case list.length(ep) == list.length(np) {
        True ->
          IrTypeFn(
            list.map(list.zip(ep, np), fn(p) { merge_bound_type(p.0, p.1) }),
            merge_bound_type(er, nr),
          )
        False -> existing
      }
    IrTypeNamed(module: em, name: en, args: eas, ..),
      IrTypeNamed(module: nm, name: nn, args: nas, ..)
      if em == nm && en == nn
    ->
      case list.length(eas) == list.length(nas) {
        True ->
          IrTypeNamed(
            ..existing,
            args: list.map(list.zip(eas, nas), fn(p) {
              merge_bound_type(p.0, p.1)
            }),
          )
        False -> existing
      }
    _, _ -> existing
  }
}

fn expand_type_alias(ty: IrType, cur_mod: String, ctx: AnalyzeCtx) -> IrType {
  expand_type_alias_loop(ty, cur_mod, ctx, set.new())
}

fn expand_type_alias_loop(
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  visited: Set(#(String, String)),
) -> IrType {
  case ty {
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      let key = #(resolved_mod, name)
      case set.contains(visited, key) {
        True -> ty
        False ->
          case dict.get(ctx.all_type_aliases, key) {
            Ok(ta) ->
              case list.length(ta.type_params) == list.length(args) {
                False -> ty
                True -> {
                  let subst =
                    list.zip(ta.type_params, args)
                    |> dict.from_list
                  let expanded = apply_ir_subst(ta.aliased, subst)
                  expand_type_alias_loop(
                    expanded,
                    resolved_mod,
                    ctx,
                    set.insert(visited, key),
                  )
                }
              }
            Error(_) -> ty
          }
      }
    }
    _ -> ty
  }
}

fn apply_call_ret_subst(ty: IrType, subst: Dict(String, IrType)) -> IrType {
  case ty {
    IrTypeVar(v) ->
      case dict.get(subst, v) {
        Ok(t) -> t
        Error(_) ->
          case is_free_var(v) {
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

fn apply_ir_subst(ty: IrType, subst: Dict(String, IrType)) -> IrType {
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

fn collect_inspectable_type_vars(
  ty: IrType,
  cur_mod: String,
  ctx: AnalyzeCtx,
  acc: Set(String),
) -> Set(String) {
  case expand_type_alias(ty, cur_mod, ctx) {
    IrTypeVar(v) -> set.insert(acc, v)
    IrTypeList(inner) -> collect_inspectable_type_vars(inner, cur_mod, ctx, acc)
    IrTypeResult(ok_t, err_t) ->
      collect_inspectable_type_vars(
        err_t,
        cur_mod,
        ctx,
        collect_inspectable_type_vars(ok_t, cur_mod, ctx, acc),
      )
    IrTypeTuple(els) ->
      list.fold(els, acc, fn(s, e) {
        collect_inspectable_type_vars(e, cur_mod, ctx, s)
      })
    IrTypeFn(_, _) -> acc
    IrTypeNamed(module:, name:, args:, ..) -> {
      let resolved_mod = case module {
        "" -> cur_mod
        m -> m
      }
      case is_uninspectable_external(resolved_mod, name, ctx) {
        True -> acc
        False ->
          list.fold(args, acc, fn(s, a) {
            collect_inspectable_type_vars(a, cur_mod, ctx, s)
          })
      }
    }
    _ -> acc
  }
}

fn is_uninspectable_external(
  module: String,
  name: String,
  ctx: AnalyzeCtx,
) -> Bool {
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
  ctx: AnalyzeCtx,
) -> Option(ExternalType) {
  case dict.get(ctx.all_types, #(module, name)) {
    Ok(td) -> td.external_type
    Error(_) ->
      case ctx.table {
        None -> None
        Some(tbl) ->
          case dict.get(tbl.modules, module) {
            Error(_) -> None
            Ok(ms) ->
              case dict.get(ms.types, name) {
                Ok(ti) -> ti.external_type
                Error(_) ->
                  dict.values(ms.types)
                  |> list.find(fn(ti) {
                    mangle.mangle_type_name(ti.name) == name
                  })
                  |> option.from_result
                  |> option.then(fn(ti) { ti.external_type })
              }
          }
      }
  }
}

fn is_nullary_multi_variant_ctor(
  expr: IrExpr,
  cur_mod: String,
  ctx: AnalyzeCtx,
) -> Bool {
  case expr {
    IrList(elements: [], tail: None) -> True
    IrConstructor(target_module:, name:, ..) -> {
      let ctor_mod = option.unwrap(target_module, cur_mod)
      case lookup_ctor(ctx, ctor_mod, name) {
        Some(#(td, variant)) ->
          variant.fields == [] && list.length(td.variants) >= 2
        None ->
          case ctx.table {
            None -> False
            Some(tbl) ->
              case dict.get(tbl.modules, ctor_mod) {
                Error(_) -> False
                Ok(ms) ->
                  case dict.get(ms.constructors, name) {
                    Error(_) -> False
                    Ok(ctor) ->
                      case ctor.fields, dict.get(ms.types, ctor.type_name) {
                        [], Ok(ti) -> list.length(ti.variants) >= 2
                        _, _ -> False
                      }
                  }
              }
          }
      }
    }
    _ -> False
  }
}

fn lookup_ctor(
  ctx: AnalyzeCtx,
  mod_name: String,
  ctor_name: String,
) -> Option(#(IrTypeDef, IrVariant)) {
  dict.get(ctx.all_ctors, #(mod_name, ctor_name)) |> option.from_result
}

fn list_at_idx(items: List(a), index: Int) -> Option(a) {
  case items, index {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], i if i > 0 -> list_at_idx(tail, i - 1)
    _, _ -> None
  }
}

fn unwrap_or(res: Result(a, b), default: a) -> a {
  case res {
    Ok(v) -> v
    Error(_) -> default
  }
}
