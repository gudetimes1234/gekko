import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lower/ir.{
  type IrCallArg, type IrClause, type IrExpr, type IrFunction, type IrModule,
  type IrParam, type IrPatArg, type IrPattern, type IrStmt, IrAbort, IrBlock,
  IrBreak, IrCall, IrClause, IrContinue, IrForLoop, IrFunction, IrMatch,
  IrModule, IrParam, IrPatAs, IrPatBitString, IrPatDiscard, IrPatTuple, IrPatVar,
  IrPatVariant, IrStmtAssert, IrStmtExpr, IrStmtGuard, IrStmtLet, IrVar,
}

/// Apply self-tail-call optimization across all functions in `module`.
pub fn optimize_module(module: IrModule) -> IrModule {
  IrModule(..module, functions: list.map(module.functions, optimize_function))
}

/// Detect direct self-tail calls in `func`. If at least one self-tail call is
/// present (and `ffi` is `None`), rewrite the function body into a MoonBit
/// functional `for` state loop (`IrForLoop` with `IrContinue` and `IrBreak`).
pub fn optimize_function(func: IrFunction) -> IrFunction {
  case func.ffi, func.body {
    Some(_), _ | _, [] -> func
    None, _ -> {
      let param_shadows = list.any(func.params, fn(p) { p.name == func.name })
      case param_shadows {
        True -> func
        False -> {
          let normalized_params = normalize_discard_params(func.params)
          let #(rewritten_body, found_tail_call) =
            rewrite_stmts_tail(func.body, func.name, normalized_params, False)
          case found_tail_call {
            False -> func
            True -> {
              let bindings =
                list.map(normalized_params, fn(p) { #(p.name, IrVar(p.name)) })
              let loop_stmt =
                IrStmtExpr(IrForLoop(bindings:, body: rewritten_body))
              IrFunction(..func, params: normalized_params, body: [loop_stmt])
            }
          }
        }
      }
    }
  }
}

fn normalize_discard_params(params: List(IrParam)) -> List(IrParam) {
  list.index_map(params, fn(p, idx) {
    case p.name {
      "_" -> IrParam(..p, name: "__tco_unused_" <> int.to_string(idx))
      _ -> p
    }
  })
}

fn rewrite_stmts_tail(
  stmts: List(IrStmt),
  fn_name: String,
  params: List(IrParam),
  shadowed: Bool,
) -> #(List(IrStmt), Bool) {
  case stmts {
    [] -> #([], False)
    [last] ->
      case last {
        IrStmtExpr(expr) -> {
          let #(rewritten_expr, found) =
            rewrite_expr_tail(expr, fn_name, params, shadowed)
          #([IrStmtExpr(rewritten_expr)], found)
        }
        IrStmtLet(_, _, _) | IrStmtGuard(_, _, _, _, _) | IrStmtAssert(_, _) -> #(
          [last],
          False,
        )
      }
    [head, ..tail] -> {
      let next_shadowed = shadowed || stmt_shadows_name(head, fn_name)
      let #(tail_stmts, found) =
        rewrite_stmts_tail(tail, fn_name, params, next_shadowed)
      #([head, ..tail_stmts], found)
    }
  }
}

fn rewrite_expr_tail(
  expr: IrExpr,
  fn_name: String,
  params: List(IrParam),
  shadowed: Bool,
) -> #(IrExpr, Bool) {
  case expr {
    IrCall(function: IrVar(callee), args:) if !shadowed && callee == fn_name ->
      case align_args_to_params(args, params) {
        Some(ordered_args) -> #(IrContinue(ordered_args), True)
        None -> #(IrBreak(expr), False)
      }

    IrBlock(stmts) -> {
      let #(rewritten_stmts, found) =
        rewrite_stmts_tail(stmts, fn_name, params, shadowed)
      #(IrBlock(rewritten_stmts), found)
    }

    IrMatch(subjects:, clauses:) -> {
      let #(rev_clauses, any_found) =
        list.fold(clauses, #([], False), fn(acc, clause) {
          let #(clauses_acc, found_acc) = acc
          let arm_shadowed = shadowed || clause_shadows_name(clause, fn_name)
          let #(rewritten_body, arm_found) =
            rewrite_expr_tail(clause.body, fn_name, params, arm_shadowed)
          let new_clause = IrClause(..clause, body: rewritten_body)
          #([new_clause, ..clauses_acc], found_acc || arm_found)
        })
      #(IrMatch(subjects:, clauses: list.reverse(rev_clauses)), any_found)
    }

    IrAbort(_, _) | IrContinue(_) | IrBreak(_) -> #(expr, False)

    _ -> #(IrBreak(expr), False)
  }
}

fn align_args_to_params(
  args: List(IrCallArg),
  params: List(IrParam),
) -> Option(List(IrExpr)) {
  case list.length(args) == list.length(params) {
    False -> None
    True -> {
      let has_labels = list.any(args, fn(arg) { option.is_some(arg.label) })
      case has_labels {
        False -> Some(list.map(args, fn(arg) { arg.value }))
        True -> {
          let #(labeled_map, rev_positional) =
            list.fold(args, #(dict.new(), []), fn(acc, arg) {
              let #(lmap, pos) = acc
              case arg.label {
                Some(lbl) -> #(dict.insert(lmap, lbl, arg.value), pos)
                None -> #(lmap, [arg.value, ..pos])
              }
            })
          let positional_queue = list.reverse(rev_positional)
          fill_params(params, labeled_map, positional_queue, [])
        }
      }
    }
  }
}

fn fill_params(
  params: List(IrParam),
  labeled_map: dict.Dict(String, IrExpr),
  positional: List(IrExpr),
  rev_acc: List(IrExpr),
) -> Option(List(IrExpr)) {
  case params {
    [] ->
      case positional {
        [] -> Some(list.reverse(rev_acc))
        _ -> None
      }
    [param, ..rest_params] ->
      case param.label {
        Some(lbl) ->
          case dict.get(labeled_map, lbl) {
            Ok(expr) ->
              fill_params(rest_params, labeled_map, positional, [
                expr,
                ..rev_acc
              ])
            Error(_) ->
              case positional {
                [p_expr, ..rest_pos] ->
                  fill_params(rest_params, labeled_map, rest_pos, [
                    p_expr,
                    ..rev_acc
                  ])
                [] -> None
              }
          }
        None ->
          case positional {
            [p_expr, ..rest_pos] ->
              fill_params(rest_params, labeled_map, rest_pos, [
                p_expr,
                ..rev_acc
              ])
            [] -> None
          }
      }
  }
}

fn stmt_shadows_name(stmt: IrStmt, name: String) -> Bool {
  case stmt {
    IrStmtLet(pattern:, ..) -> set.contains(pattern_bound_vars(pattern), name)
    IrStmtGuard(pattern:, post_bindings:, ..) ->
      set.contains(pattern_bound_vars(pattern), name)
      || list.any(post_bindings, fn(b) { b.0 == name })
    IrStmtAssert(_, _) | IrStmtExpr(_) -> False
  }
}

fn clause_shadows_name(clause: IrClause, name: String) -> Bool {
  let pat_shadows =
    list.any(clause.patterns, fn(alt) {
      list.any(alt, fn(p) { set.contains(pattern_bound_vars(p), name) })
    })
  let binding_shadows = list.any(clause.prefix_bindings, fn(b) { b.0 == name })
  pat_shadows || binding_shadows
}

fn pattern_bound_vars(pat: IrPattern) -> Set(String) {
  case pat {
    ir.IrPatInt(_)
    | ir.IrPatFloat(_)
    | ir.IrPatString(_)
    | ir.IrPatBool(_)
    | ir.IrPatUnit
    | IrPatDiscard -> set.new()
    IrPatVar(name) -> set.from_list([name])
    IrPatTuple(els) ->
      list.fold(els, set.new(), fn(acc, el) {
        set.union(acc, pattern_bound_vars(el))
      })
    IrPatVariant(args:, ..) ->
      list.fold(args, set.new(), fn(acc, arg: IrPatArg) {
        set.union(acc, pattern_bound_vars(arg.pattern))
      })
    IrPatAs(inner, alias) -> set.insert(pattern_bound_vars(inner), alias)
    IrPatBitString(segments:) ->
      list.fold(segments, set.new(), fn(acc, seg) {
        set.union(acc, pattern_bound_vars(seg.0))
      })
  }
}
