import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrBitSize, type IrExpr, type IrPattern, IrBitSizeBinOp, IrBitSizeInt,
  IrBitSizeVar, IrCall, IrCallArg, IrModuleRef, IrPatArg, IrPatAs,
  IrPatBitString, IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt, IrPatString,
  IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrString, IrVar,
}
import lower/mangle

/// Result of lowering a Gleam `glance.Pattern` along with any synthetic
/// string-prefix guards/bindings and newly bound local variable names.
pub type LoweredPattern {
  LoweredPattern(
    pattern: IrPattern,
    guards: List(IrExpr),
    prefix_bindings: List(#(String, IrExpr)),
    bound_names: List(String),
    next_id: Int,
  )
}

/// Lower a `glance.Pattern` into an `IrPattern`, extracting synthetic prefix
/// checks (`"pre" <> rest`), expanding shorthand variant fields, and converting
/// list patterns (`[h, ..t]`) into `@prelude.Cons` / `@prelude.Nil`.
pub fn lower_pattern(
  pattern: glance.Pattern,
  table: SymbolTable,
  current_module: String,
  next_id: Int,
) -> LoweredPattern {
  case pattern {
    glance.PatternInt(value:, ..) ->
      LoweredPattern(
        pattern: IrPatInt(value),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        next_id:,
      )

    glance.PatternFloat(value:, ..) ->
      LoweredPattern(
        pattern: IrPatFloat(value),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        next_id:,
      )

    glance.PatternString(value:, ..) ->
      LoweredPattern(
        pattern: IrPatString(value),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        next_id:,
      )

    glance.PatternDiscard(..) ->
      LoweredPattern(
        pattern: IrPatDiscard,
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        next_id:,
      )

    glance.PatternVariable(name:, ..) -> {
      let mangled = mangle.mangle_ident(name)
      LoweredPattern(
        pattern: IrPatVar(mangled),
        guards: [],
        prefix_bindings: [],
        bound_names: [name],
        next_id:,
      )
    }

    glance.PatternTuple(elements:, ..) -> {
      let #(rev_pats, guards, bindings, names, cur_id) =
        lower_pattern_list(elements, table, current_module, next_id)
      LoweredPattern(
        pattern: IrPatTuple(list.reverse(rev_pats)),
        guards:,
        prefix_bindings: bindings,
        bound_names: names,
        next_id: cur_id,
      )
    }

    glance.PatternList(elements:, tail:, ..) -> {
      let #(tail_pat, guards, bindings, names, cur_id) = case tail {
        None -> #(
          IrPatVariant(Some("prelude"), None, "Nil", [], False),
          [],
          [],
          [],
          next_id,
        )
        Some(t) -> {
          let lt = lower_pattern(t, table, current_module, next_id)
          #(
            lt.pattern,
            lt.guards,
            lt.prefix_bindings,
            lt.bound_names,
            lt.next_id,
          )
        }
      }

      let #(rev_els, el_guards, el_bindings, el_names, final_id) =
        lower_pattern_list(elements, table, current_module, cur_id)

      let list_pat =
        list.fold(rev_els, tail_pat, fn(acc_tail, el_pat) {
          IrPatVariant(
            module_alias: Some("prelude"),
            target_module: None,
            constructor: "Cons",
            args: [IrPatArg(None, el_pat), IrPatArg(None, acc_tail)],
            with_spread: False,
          )
        })

      LoweredPattern(
        pattern: list_pat,
        guards: list.append(el_guards, guards),
        prefix_bindings: list.append(el_bindings, bindings),
        bound_names: list.append(el_names, names),
        next_id: final_id,
      )
    }

    glance.PatternAssignment(pattern: inner, name:, ..) -> {
      let lowered = lower_pattern(inner, table, current_module, next_id)
      let mangled = mangle.mangle_ident(name)
      LoweredPattern(
        pattern: IrPatAs(lowered.pattern, mangled),
        guards: lowered.guards,
        prefix_bindings: lowered.prefix_bindings,
        bound_names: [name, ..lowered.bound_names],
        next_id: lowered.next_id,
      )
    }

    glance.PatternConcatenate(prefix:, prefix_name:, rest_name:, ..) -> {
      let synth_var = "__str_pfx_" <> int.to_string(next_id)
      let cur_id = next_id + 1

      let prefix_check =
        IrCall(
          function: IrModuleRef(
            module_alias: Some("prelude"),
            target_module: "prelude",
            symbol: "string_has_prefix",
          ),
          args: [
            IrCallArg(None, IrVar(synth_var)),
            IrCallArg(None, IrString(prefix)),
          ],
        )

      let #(pfx_bindings, pfx_names) = case prefix_name {
        Some(glance.Named(p_name)) -> #(
          [#(mangle.mangle_ident(p_name), IrString(prefix))],
          [p_name],
        )
        Some(glance.Discarded(_)) | None -> #([], [])
      }

      let #(rest_bindings, rest_names) = case rest_name {
        glance.Named(r_name) -> {
          let drop_call =
            IrCall(
              function: IrModuleRef(
                module_alias: Some("prelude"),
                target_module: "prelude",
                symbol: "string_drop_prefix",
              ),
              args: [
                IrCallArg(None, IrVar(synth_var)),
                IrCallArg(None, IrString(prefix)),
              ],
            )
          #([#(mangle.mangle_ident(r_name), drop_call)], [r_name])
        }
        glance.Discarded(_) -> #([], [])
      }

      LoweredPattern(
        pattern: IrPatVar(synth_var),
        guards: [prefix_check],
        prefix_bindings: list.append(pfx_bindings, rest_bindings),
        bound_names: list.append(pfx_names, rest_names),
        next_id: cur_id,
      )
    }

    glance.PatternBitString(segments:, ..) -> {
      let #(rev_segs, guards, bindings, names, cur_id) =
        list.fold(segments, #([], [], [], [], next_id), fn(acc, seg) {
          let #(segs_acc, g_acc, b_acc, n_acc, id_acc) = acc
          let #(pat, opts) = seg
          let lp = lower_pattern(pat, table, current_module, id_acc)
          let lowered_opts = list.map(opts, lower_bit_segment_option)
          #(
            [#(lp.pattern, lowered_opts), ..segs_acc],
            list.append(g_acc, lp.guards),
            list.append(b_acc, lp.prefix_bindings),
            list.append(n_acc, lp.bound_names),
            lp.next_id,
          )
        })
      LoweredPattern(
        pattern: IrPatBitString(list.reverse(rev_segs)),
        guards:,
        prefix_bindings: bindings,
        bound_names: names,
        next_id: cur_id,
      )
    }

    glance.PatternVariant(module:, constructor:, arguments:, with_spread:, ..) ->
      lower_pattern_variant(
        module,
        constructor,
        arguments,
        with_spread,
        table,
        current_module,
        next_id,
      )
  }
}

fn lower_pattern_variant(
  module: Option(String),
  constructor: String,
  arguments: List(glance.Field(glance.Pattern)),
  with_spread: Bool,
  table: SymbolTable,
  current_module: String,
  next_id: Int,
) -> LoweredPattern {
  case module, constructor, arguments {
    None, "True", [] -> LoweredPattern(IrPatBool(True), [], [], [], next_id)
    None, "False", [] -> LoweredPattern(IrPatBool(False), [], [], [], next_id)
    None, "Nil", [] -> LoweredPattern(IrPatUnit, [], [], [], next_id)
    _, _, _ -> {
      let #(rev_args, guards, bindings, names, cur_id) =
        list.fold(arguments, #([], [], [], [], next_id), fn(acc, field) {
          let #(args_acc, g_acc, b_acc, n_acc, id_acc) = acc
          case field {
            glance.UnlabelledField(item:) -> {
              let lp = lower_pattern(item, table, current_module, id_acc)
              #(
                [IrPatArg(None, lp.pattern), ..args_acc],
                list.append(g_acc, lp.guards),
                list.append(b_acc, lp.prefix_bindings),
                list.append(n_acc, lp.bound_names),
                lp.next_id,
              )
            }
            glance.LabelledField(label:, item:, ..) -> {
              let lp = lower_pattern(item, table, current_module, id_acc)
              #(
                [
                  IrPatArg(Some(mangle.mangle_ident(label)), lp.pattern),
                  ..args_acc
                ],
                list.append(g_acc, lp.guards),
                list.append(b_acc, lp.prefix_bindings),
                list.append(n_acc, lp.bound_names),
                lp.next_id,
              )
            }
            glance.ShorthandField(label:, ..) -> {
              let mangled = mangle.mangle_ident(label)
              #(
                [IrPatArg(Some(mangled), IrPatVar(mangled)), ..args_acc],
                g_acc,
                b_acc,
                [label, ..n_acc],
                id_acc,
              )
            }
          }
        })

      let #(mod_alias, target_mod, ctor_name) =
        resolve_variant_constructor(module, constructor, table, current_module)

      LoweredPattern(
        pattern: IrPatVariant(
          module_alias: mod_alias,
          target_module: target_mod,
          constructor: ctor_name,
          args: list.reverse(rev_args),
          with_spread:,
        ),
        guards:,
        prefix_bindings: bindings,
        bound_names: names,
        next_id: cur_id,
      )
    }
  }
}

fn resolve_variant_constructor(
  qualifier: Option(String),
  constructor: String,
  table: SymbolTable,
  current_module: String,
) -> #(Option(String), Option(String), String) {
  case qualifier, constructor {
    None, "Ok" -> #(None, None, "Ok")
    None, "Error" -> #(None, None, "Err")
    _, _ ->
      case
        symbol_table.lookup_constructor(
          table,
          current_module,
          qualifier,
          constructor,
        )
      {
        Some(ctor) ->
          case ctor.module == current_module {
            True -> #(None, None, ctor.variant_name)
            False -> {
              let alias =
                resolve_alias_for_module(
                  table,
                  current_module,
                  ctor.module,
                  qualifier,
                )
              #(alias, Some(ctor.module), ctor.variant_name)
            }
          }
        None -> #(qualifier, None, constructor)
      }
  }
}

fn resolve_alias_for_module(
  table: SymbolTable,
  current_module: String,
  target_module: String,
  fallback_qualifier: Option(String),
) -> Option(String) {
  case fallback_qualifier {
    Some(_) -> fallback_qualifier
    None ->
      case dict.get(table.modules, current_module) {
        Ok(mod_syms) -> {
          let found =
            list.find(mod_syms.imports, fn(imp) { imp.module == target_module })
          case found {
            Ok(imp) ->
              case imp.alias {
                Some(a) -> Some(a)
                None -> Some(mangle.module_to_alias(target_module))
              }
            Error(_) -> Some(mangle.module_to_alias(target_module))
          }
        }
        Error(_) -> Some(mangle.module_to_alias(target_module))
      }
  }
}

fn lower_pattern_list(
  patterns: List(glance.Pattern),
  table: SymbolTable,
  current_module: String,
  next_id: Int,
) -> #(
  List(IrPattern),
  List(IrExpr),
  List(#(String, IrExpr)),
  List(String),
  Int,
) {
  list.fold(patterns, #([], [], [], [], next_id), fn(acc, p) {
    let #(pats_acc, g_acc, b_acc, n_acc, id_acc) = acc
    let lp = lower_pattern(p, table, current_module, id_acc)
    #(
      [lp.pattern, ..pats_acc],
      list.append(g_acc, lp.guards),
      list.append(b_acc, lp.prefix_bindings),
      list.append(n_acc, lp.bound_names),
      lp.next_id,
    )
  })
}

fn lower_bit_segment_option(
  opt: glance.BitStringSegmentOption(glance.BitArraySize),
) -> glance.BitStringSegmentOption(IrBitSize) {
  case opt {
    glance.BytesOption -> glance.BytesOption
    glance.IntOption -> glance.IntOption
    glance.FloatOption -> glance.FloatOption
    glance.BitsOption -> glance.BitsOption
    glance.Utf8Option -> glance.Utf8Option
    glance.Utf16Option -> glance.Utf16Option
    glance.Utf32Option -> glance.Utf32Option
    glance.Utf8CodepointOption -> glance.Utf8CodepointOption
    glance.Utf16CodepointOption -> glance.Utf16CodepointOption
    glance.Utf32CodepointOption -> glance.Utf32CodepointOption
    glance.SignedOption -> glance.SignedOption
    glance.UnsignedOption -> glance.UnsignedOption
    glance.BigOption -> glance.BigOption
    glance.LittleOption -> glance.LittleOption
    glance.NativeOption -> glance.NativeOption
    glance.SizeValueOption(size_expr) ->
      glance.SizeValueOption(lower_bit_size(size_expr))
    glance.SizeOption(n) -> glance.SizeOption(n)
    glance.UnitOption(u) -> glance.UnitOption(u)
  }
}

fn lower_bit_size(size: glance.BitArraySize) -> IrBitSize {
  case size {
    glance.BitArraySizeInt(value:, ..) -> IrBitSizeInt(value)
    glance.BitArraySizeVariable(name:, ..) ->
      IrBitSizeVar(mangle.mangle_ident(name))
    glance.BitArraySizeBinaryOperator(operator:, left:, right:, ..) ->
      IrBitSizeBinOp(
        op: operator,
        left: lower_bit_size(left),
        right: lower_bit_size(right),
      )
    glance.BitArraySizeBlock(inner:, ..) -> lower_bit_size(inner)
  }
}
