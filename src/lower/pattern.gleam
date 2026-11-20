import glance
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import index/symbol_table.{type SymbolTable}
import lower/ir.{
  type IrExpr, type IrPattern, type IrStmt, IrAddInt, IrAnd, IrBinOp,
  IrBitString, IrBlock, IrBool, IrCall, IrCallArg, IrClause, IrDivInt, IrEq,
  IrFloat, IrInt, IrMatch, IrModuleRef, IrMultInt, IrPatArg, IrPatAs,
  IrPatBitString, IrPatBool, IrPatDiscard, IrPatFloat, IrPatInt, IrPatString,
  IrPatTuple, IrPatUnit, IrPatVar, IrPatVariant, IrRemInt, IrStmtAssert,
  IrStmtExpr, IrStmtGuard, IrStmtLet, IrString, IrSubInt, IrTupleIndex, IrVar,
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
          IrPatVariant(Some("gprelude"), None, "Nil", [], False),
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
            module_alias: Some("gprelude"),
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
      case lowered.pattern {
        IrPatVar(existing) ->
          case string.starts_with(existing, "__") {
            True ->
              LoweredPattern(
                pattern: IrPatVar(existing),
                guards: lowered.guards,
                prefix_bindings: [
                  #(mangled, IrVar(existing)),
                  ..lowered.prefix_bindings
                ],
                bound_names: [name, ..lowered.bound_names],
                next_id: lowered.next_id,
              )
            False ->
              LoweredPattern(
                pattern: IrPatAs(lowered.pattern, mangled),
                guards: lowered.guards,
                prefix_bindings: lowered.prefix_bindings,
                bound_names: [name, ..lowered.bound_names],
                next_id: lowered.next_id,
              )
          }
        _ ->
          LoweredPattern(
            pattern: IrPatAs(lowered.pattern, mangled),
            guards: lowered.guards,
            prefix_bindings: lowered.prefix_bindings,
            bound_names: [name, ..lowered.bound_names],
            next_id: lowered.next_id,
          )
      }
    }

    glance.PatternConcatenate(prefix:, prefix_name:, rest_name:, ..) -> {
      let synth_var = "__str_pfx_" <> int.to_string(next_id)
      let cur_id = next_id + 1

      let prefix_check =
        IrCall(
          function: IrModuleRef(
            module_alias: Some("gprelude"),
            target_module: "gprelude",
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
                module_alias: Some("gprelude"),
                target_module: "gprelude",
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

    glance.PatternBitString(segments:, ..) ->
      lower_bit_string_pattern(segments, next_id)

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

fn lower_bit_string_pattern(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  next_id: Int,
) -> LoweredPattern {
  case segments {
    [] ->
      LoweredPattern(
        pattern: IrPatBitString([]),
        guards: [],
        prefix_bindings: [],
        bound_names: [],
        next_id:,
      )
    [#(glance.PatternDiscard(..), opts)] ->
      case is_trivial_catch_all_bits(opts) {
        True ->
          LoweredPattern(
            pattern: IrPatDiscard,
            guards: [],
            prefix_bindings: [],
            bound_names: [],
            next_id:,
          )
        False -> lower_non_empty_bit_string(segments, next_id)
      }
    [#(glance.PatternVariable(name:, ..), opts)] ->
      case is_trivial_catch_all_bits(opts) {
        True ->
          LoweredPattern(
            pattern: IrPatVar(mangle.mangle_ident(name)),
            guards: [],
            prefix_bindings: [],
            bound_names: [name],
            next_id:,
          )
        False -> lower_non_empty_bit_string(segments, next_id)
      }
    _ -> lower_non_empty_bit_string(segments, next_id)
  }
}

fn is_trivial_catch_all_bits(
  opts: List(glance.BitStringSegmentOption(glance.BitArraySize)),
) -> Bool {
  list.contains(opts, glance.BitsOption)
  && !list.any(opts, fn(o) {
    case o {
      glance.BytesOption
      | glance.SizeOption(_)
      | glance.SizeValueOption(_)
      | glance.Utf8Option
      | glance.Utf16Option
      | glance.Utf32Option
      | glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption
      | glance.FloatOption
      | glance.IntOption -> True
      _ -> False
    }
  })
}

fn lower_non_empty_bit_string(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  next_id: Int,
) -> LoweredPattern {
  let synth_var = "__bits_" <> int.to_string(next_id)
  let #(guard_opt, bindings, names, final_id) =
    lower_bit_string_for_subject(synth_var, segments, next_id + 1)
  let guards = case guard_opt {
    None -> []
    Some(IrBool(True)) -> []
    Some(g) -> [g]
  }
  LoweredPattern(
    pattern: IrPatVar(synth_var),
    guards:,
    prefix_bindings: bindings,
    bound_names: names,
    next_id: final_id,
  )
}

type UtfEncoding {
  EncUtf8
  EncUtf16
  EncUtf32
}

type BitSegKind {
  SegUtfString(value: String, encoding: UtfEncoding, big_endian: Bool)
  SegUtfCodepoint(encoding: UtfEncoding, big_endian: Bool)
  SegSizedBits(bits_expr: IrExpr)
  SegRest(require_byte_aligned: Bool)
  SegFloat(bits_expr: IrExpr, big_endian: Bool)
  SegInt(bits_expr: IrExpr, signed: Bool, big_endian: Bool)
}

type ParsedBitSeg {
  ParsedBitSeg(
    core_pat: glance.Pattern,
    mangled_aliases: List(String),
    raw_aliases: List(String),
    kind: BitSegKind,
    nested_sub_var: Option(String),
    nested_guard: Option(IrExpr),
    nested_bindings: List(#(String, IrExpr)),
    nested_raw_names: List(String),
    nested_mangled_names: List(String),
  )
}

fn unwrap_pat_aliases(
  pat: glance.Pattern,
) -> #(glance.Pattern, List(String), List(String)) {
  unwrap_pat_aliases_acc(pat, [], [])
}

fn unwrap_pat_aliases_acc(
  pat: glance.Pattern,
  mangled_acc: List(String),
  raw_acc: List(String),
) -> #(glance.Pattern, List(String), List(String)) {
  case pat {
    glance.PatternAssignment(pattern: inner, name:, ..) ->
      unwrap_pat_aliases_acc(inner, [mangle.mangle_ident(name), ..mangled_acc], [
        name,
        ..raw_acc
      ])
    _ -> #(pat, mangled_acc, raw_acc)
  }
}

fn bit_size_to_ir_expr(size: glance.BitArraySize) -> IrExpr {
  case size {
    glance.BitArraySizeInt(value:, ..) -> IrInt(value)
    glance.BitArraySizeVariable(name:, ..) -> IrVar(mangle.mangle_ident(name))
    glance.BitArraySizeBinaryOperator(operator:, left:, right:, ..) -> {
      let ir_op = case operator {
        glance.BitArraySizeAdd -> IrAddInt
        glance.BitArraySizeSubtract -> IrSubInt
        glance.BitArraySizeMultiply -> IrMultInt
        glance.BitArraySizeDivide -> IrDivInt
        glance.BitArraySizeRemainder -> IrRemInt
      }
      IrBinOp(ir_op, bit_size_to_ir_expr(left), bit_size_to_ir_expr(right))
    }
    glance.BitArraySizeBlock(inner:, ..) -> bit_size_to_ir_expr(inner)
  }
}

fn compute_pat_segment_bits_expr(
  opts: List(glance.BitStringSegmentOption(glance.BitArraySize)),
  default_size: Int,
  default_unit: Int,
) -> #(Bool, IrExpr) {
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
        glance.SizeValueOption(s) -> Ok(Error(s))
        _ -> Error(Nil)
      }
    })
  case size_opt {
    Ok(Ok(n)) -> #(True, IrInt(int.to_string(n * unit)))
    Ok(Error(size_ast)) -> {
      let lowered = bit_size_to_ir_expr(size_ast)
      case lowered, unit {
        IrInt(v), _ ->
          case int.parse(v) {
            Ok(n) -> #(True, IrInt(int.to_string(n * unit)))
            Error(_) ->
              case unit {
                1 -> #(True, lowered)
                u -> #(
                  True,
                  IrBinOp(IrMultInt, lowered, IrInt(int.to_string(u))),
                )
              }
          }
        _, 1 -> #(True, lowered)
        _, u -> #(True, IrBinOp(IrMultInt, lowered, IrInt(int.to_string(u))))
      }
    }
    Error(_) -> #(False, IrInt(int.to_string(default_size * unit)))
  }
}

fn classify_bit_segment(
  core_pat: glance.Pattern,
  opts: List(glance.BitStringSegmentOption(glance.BitArraySize)),
) -> BitSegKind {
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
  let has_signed = list.contains(opts, glance.SignedOption)
  let big_endian =
    !list.any(opts, fn(o) {
      o == glance.LittleOption || o == glance.NativeOption
    })

  case
    has_bytes || has_bits,
    has_utf8_cp,
    has_utf16_cp,
    has_utf32_cp,
    has_utf8,
    has_utf16,
    has_utf32
  {
    True, _, _, _, _, _, _ -> {
      let default_unit = case has_bytes {
        True -> 8
        False -> 1
      }
      let #(has_size, bits_expr) =
        compute_pat_segment_bits_expr(opts, 1, default_unit)
      case has_size {
        True -> SegSizedBits(bits_expr)
        False -> SegRest(require_byte_aligned: has_bytes)
      }
    }
    _, True, _, _, _, _, _ -> SegUtfCodepoint(EncUtf8, True)
    _, _, True, _, _, _, _ -> SegUtfCodepoint(EncUtf16, big_endian)
    _, _, _, True, _, _, _ -> SegUtfCodepoint(EncUtf32, big_endian)
    _, _, _, _, True, _, _ ->
      case core_pat {
        glance.PatternString(value:, ..) -> SegUtfString(value, EncUtf8, True)
        _ -> SegUtfCodepoint(EncUtf8, True)
      }
    _, _, _, _, _, True, _ ->
      case core_pat {
        glance.PatternString(value:, ..) ->
          SegUtfString(value, EncUtf16, big_endian)
        _ -> SegUtfCodepoint(EncUtf16, big_endian)
      }
    _, _, _, _, _, _, True ->
      case core_pat {
        glance.PatternString(value:, ..) ->
          SegUtfString(value, EncUtf32, big_endian)
        _ -> SegUtfCodepoint(EncUtf32, big_endian)
      }
    _, _, _, _, _, _, _ ->
      case core_pat {
        glance.PatternString(value:, ..) if !has_int && !has_float ->
          SegUtfString(value, EncUtf8, True)
        glance.PatternFloat(..) if !has_int -> {
          let #(_, bits_expr) = compute_pat_segment_bits_expr(opts, 64, 1)
          SegFloat(bits_expr, big_endian)
        }
        _ if has_float -> {
          let #(_, bits_expr) = compute_pat_segment_bits_expr(opts, 64, 1)
          SegFloat(bits_expr, big_endian)
        }
        _ -> {
          let #(_, bits_expr) = compute_pat_segment_bits_expr(opts, 8, 1)
          SegInt(bits_expr, has_signed, big_endian)
        }
      }
  }
}

fn lower_bit_string_for_subject(
  subject_var: String,
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  next_id: Int,
) -> #(Option(IrExpr), List(#(String, IrExpr)), List(String), Int) {
  let #(parsed_segs, id_after_parse) = parse_bit_segments(segments, next_id)
  let needed_later = compute_later_size_refs(parsed_segs)
  let zipped_segs = list.zip(parsed_segs, needed_later)
  let #(guard_expr, id_after_guard) =
    build_bit_guard(zipped_segs, subject_var, IrInt("0"), id_after_parse)
  let #(bindings, final_id) =
    build_bit_bindings(parsed_segs, subject_var, IrInt("0"), id_after_guard)
  let bound_names =
    list.flat_map(parsed_segs, fn(seg) {
      let core_names = case seg.core_pat {
        glance.PatternVariable(name:, ..) -> [name]
        _ -> []
      }
      list.flatten([core_names, seg.raw_aliases, seg.nested_raw_names])
    })
  let guard_opt = case guard_expr {
    IrBool(True) -> None
    _ -> Some(guard_expr)
  }
  #(guard_opt, bindings, bound_names, final_id)
}

fn parse_bit_segments(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  next_id: Int,
) -> #(List(ParsedBitSeg), Int) {
  let #(rev_segs, final_id) =
    list.fold(segments, #([], next_id), fn(acc, seg) {
      let #(acc_segs, cur_id) = acc
      let #(raw_pat, opts) = seg
      let #(core_pat, mangled_aliases, raw_aliases) =
        unwrap_pat_aliases(raw_pat)
      let kind = classify_bit_segment(core_pat, opts)
      let #(
        sub_var,
        nested_guard,
        nested_bindings,
        nested_raw_names,
        next_cur_id,
      ) = case core_pat {
        glance.PatternBitString(segments: inner_segs, ..) -> {
          let sv = "__bits_" <> int.to_string(cur_id)
          case inner_segs {
            [] -> #(
              Some(sv),
              Some(IrBinOp(
                IrEq,
                gprelude_call("bit_array_bit_size", [IrVar(sv)]),
                IrInt("0"),
              )),
              [],
              [],
              cur_id + 1,
            )
            _ -> {
              let #(ng, nb, nn, nid) =
                lower_bit_string_for_subject(sv, inner_segs, cur_id + 1)
              #(Some(sv), ng, nb, nn, nid)
            }
          }
        }
        _ -> #(None, None, [], [], cur_id)
      }
      let nested_mangled_names = list.map(nested_raw_names, mangle.mangle_ident)
      let parsed =
        ParsedBitSeg(
          core_pat:,
          mangled_aliases:,
          raw_aliases:,
          kind:,
          nested_sub_var: sub_var,
          nested_guard:,
          nested_bindings:,
          nested_raw_names:,
          nested_mangled_names:,
        )
      #([parsed, ..acc_segs], next_cur_id)
    })
  #(list.reverse(rev_segs), final_id)
}

fn compute_later_size_refs(segs: List(ParsedBitSeg)) -> List(Set(String)) {
  let seg_inputs = list.map(segs, seg_referenced_vars)
  let rev_inputs = list.reverse(seg_inputs)
  let #(rev_later, _) =
    list.fold(rev_inputs, #([], set.new()), fn(acc, inp) {
      let #(out, running) = acc
      #([running, ..out], set.union(running, inp))
    })
  rev_later
}

fn seg_referenced_vars(seg: ParsedBitSeg) -> Set(String) {
  let kind_vars = case seg.kind {
    SegSizedBits(b) | SegFloat(b, _) | SegInt(b, _, _) ->
      collect_ir_expr_vars(b, set.new())
    SegUtfString(_, _, _) | SegUtfCodepoint(_, _) | SegRest(_) -> set.new()
  }
  let ng_vars = case seg.nested_guard {
    Some(g) -> collect_ir_expr_vars(g, set.new())
    None -> set.new()
  }
  let nb_vars =
    list.fold(seg.nested_bindings, set.new(), fn(acc, b) {
      collect_ir_expr_vars(b.1, acc)
    })
  let inner_all = set.union(ng_vars, nb_vars)
  let own_nested = case seg.nested_sub_var {
    Some(sv) -> set.from_list([sv, ..seg.nested_mangled_names])
    None -> set.from_list(seg.nested_mangled_names)
  }
  set.union(kind_vars, set.difference(inner_all, own_nested))
}

fn build_bit_guard(
  segs: List(#(ParsedBitSeg, Set(String))),
  subject_var: String,
  pos_expr: IrExpr,
  next_id: Int,
) -> #(IrExpr, Int) {
  case segs {
    [] -> #(
      IrBinOp(
        IrEq,
        pos_expr,
        gprelude_call("bit_array_bit_size", [IrVar(subject_var)]),
      ),
      next_id,
    )
    [#(seg, later_refs), ..rest] -> {
      let seg_user_vars = seg_user_mangled_vars(seg)
      let guard_vars =
        list.filter(seg_user_vars, fn(v) { set.contains(later_refs, v) })
        |> dedup_preserve_order
      case seg.kind {
        SegRest(require_byte_aligned) -> {
          let base_guard = case seg.nested_sub_var {
            None ->
              case require_byte_aligned {
                True ->
                  gprelude_call("bit_array_rest_is_bytes", [
                    IrVar(subject_var),
                    pos_expr,
                  ])
                False -> IrBool(True)
              }
            Some(sub_var) -> {
              let reader = case require_byte_aligned {
                True -> "bit_array_rest_bytes"
                False -> "bit_array_rest_bits"
              }
              let arm_body = case seg.nested_guard {
                Some(ng) -> ng
                None -> IrBool(True)
              }
              let sub_pat = case ir_expr_uses_var(arm_body, sub_var) {
                True -> IrPatVar(sub_var)
                False -> IrPatDiscard
              }
              match_some_else_false(
                gprelude_call(reader, [IrVar(subject_var), pos_expr]),
                sub_pat,
                arm_body,
              )
            }
          }
          #(base_guard, next_id)
        }

        SegInt(bits_expr, signed, big_endian) -> {
          let lit_opt = case seg.core_pat {
            glance.PatternInt(value:, ..) -> Some(value)
            _ -> None
          }
          let needs_decode = option.is_some(lit_opt) || guard_vars != []
          let pos_var = "__gpos_" <> int.to_string(next_id)
          let can_fold = is_ir_int(pos_expr) && is_ir_int(bits_expr)
          let next_pos_arg = case needs_decode && !can_fold {
            True -> IrVar(pos_var)
            False -> add_pos_expr(pos_expr, bits_expr)
          }
          let #(rest_guard, id1) =
            build_bit_guard(rest, subject_var, next_pos_arg, next_id + 1)
          case needs_decode {
            False -> {
              let has_call =
                gprelude_call("bit_array_has_bits", [
                  IrVar(subject_var),
                  pos_expr,
                  bits_expr,
                ])
              #(and_bool(has_call, rest_guard), id1)
            }
            True -> {
              let val_var = "__gval_" <> int.to_string(id1)
              let id2 = id1 + 1
              let with_binds =
                wrap_guard_lets(
                  guard_vars,
                  IrVar(val_var),
                  rest_guard,
                  pos_var,
                  pos_expr,
                  bits_expr,
                  !can_fold,
                )
              let arm_body = case lit_opt {
                Some(lit) ->
                  and_bool(
                    IrBinOp(IrEq, IrVar(val_var), IrInt(lit)),
                    with_binds,
                  )
                None -> with_binds
              }
              let val_pat = case ir_expr_uses_var(arm_body, val_var) {
                True -> IrPatVar(val_var)
                False -> IrPatDiscard
              }
              let match_expr =
                match_some_else_false(
                  gprelude_call("bit_array_read_int", [
                    IrVar(subject_var),
                    pos_expr,
                    bits_expr,
                    IrBool(signed),
                    IrBool(big_endian),
                  ]),
                  val_pat,
                  arm_body,
                )
              #(match_expr, id2)
            }
          }
        }

        SegFloat(bits_expr, big_endian) -> {
          let lit_opt = case seg.core_pat {
            glance.PatternFloat(value:, ..) -> Some(value)
            _ -> None
          }
          let next_pos = add_pos_expr(pos_expr, bits_expr)
          let #(rest_guard, id1) =
            build_bit_guard(rest, subject_var, next_pos, next_id)
          let val_var = "__gflt_" <> int.to_string(id1)
          let id2 = id1 + 1
          let arm_body = case lit_opt {
            Some(lit) ->
              and_bool(IrBinOp(IrEq, IrVar(val_var), IrFloat(lit)), rest_guard)
            None -> rest_guard
          }
          let val_pat = case ir_expr_uses_var(arm_body, val_var) {
            True -> IrPatVar(val_var)
            False -> IrPatDiscard
          }
          let match_expr =
            match_some_else_false(
              gprelude_call("bit_array_read_float", [
                IrVar(subject_var),
                pos_expr,
                bits_expr,
                IrBool(big_endian),
              ]),
              val_pat,
              arm_body,
            )
          #(match_expr, id2)
        }

        SegSizedBits(bits_expr) -> {
          let nested_guard_vars =
            list.filter(seg.nested_mangled_names, fn(v) {
              set.contains(later_refs, v)
            })
            |> dedup_preserve_order
          let pos_var = "__gpos_" <> int.to_string(next_id)
          let can_fold = is_ir_int(pos_expr) && is_ir_int(bits_expr)
          let use_pos_var = nested_guard_vars != [] && !can_fold
          let next_pos_arg = case use_pos_var {
            True -> IrVar(pos_var)
            False -> add_pos_expr(pos_expr, bits_expr)
          }
          let #(rest_guard, id1) =
            build_bit_guard(rest, subject_var, next_pos_arg, next_id + 1)
          case seg.nested_sub_var {
            None -> {
              let has_call =
                gprelude_call("bit_array_has_bits", [
                  IrVar(subject_var),
                  pos_expr,
                  bits_expr,
                ])
              #(and_bool(has_call, rest_guard), id1)
            }
            Some(sub_var) -> {
              let after_nested_ok = case nested_guard_vars {
                [] -> rest_guard
                _ -> {
                  let needed_in_rest =
                    collect_ir_expr_vars(rest_guard, set.new())
                  let kept_nb =
                    prune_bit_bindings(seg.nested_bindings, needed_in_rest)
                  wrap_lets_block(kept_nb, rest_guard)
                }
              }
              let checked = case seg.nested_guard {
                Some(ng) -> and_bool(ng, after_nested_ok)
                None -> after_nested_ok
              }
              let arm_body = case
                use_pos_var && ir_expr_uses_var(checked, pos_var)
              {
                True ->
                  IrBlock([
                    IrStmtLet(
                      IrPatVar(pos_var),
                      None,
                      add_pos_expr(pos_expr, bits_expr),
                    ),
                    IrStmtExpr(checked),
                  ])
                False -> checked
              }
              let sub_pat = case ir_expr_uses_var(arm_body, sub_var) {
                True -> IrPatVar(sub_var)
                False -> IrPatDiscard
              }
              let match_expr =
                match_some_else_false(
                  gprelude_call("bit_array_read_bits", [
                    IrVar(subject_var),
                    pos_expr,
                    bits_expr,
                  ]),
                  sub_pat,
                  arm_body,
                )
              #(match_expr, id1)
            }
          }
        }

        SegUtfString(value, enc, big_endian) -> {
          let expected_expr = utf_string_expr(value, enc, big_endian)
          let pos_var = "__gpos_" <> int.to_string(next_id)
          let #(rest_guard, id1) =
            build_bit_guard(rest, subject_var, IrVar(pos_var), next_id + 1)
          let pos_pat = case ir_expr_uses_var(rest_guard, pos_var) {
            True -> IrPatVar(pos_var)
            False -> IrPatDiscard
          }
          let match_expr =
            match_some_else_false(
              gprelude_call("bit_array_match_bits", [
                IrVar(subject_var),
                pos_expr,
                expected_expr,
              ]),
              pos_pat,
              rest_guard,
            )
          #(match_expr, id1)
        }

        SegUtfCodepoint(enc, big_endian) -> {
          let pos_var = "__gpos_" <> int.to_string(next_id)
          let #(rest_guard, id1) =
            build_bit_guard(rest, subject_var, IrVar(pos_var), next_id + 1)
          let reader_call = case enc {
            EncUtf8 ->
              gprelude_call("bit_array_read_utf8_codepoint", [
                IrVar(subject_var),
                pos_expr,
              ])
            EncUtf16 ->
              gprelude_call("bit_array_read_utf16_codepoint", [
                IrVar(subject_var),
                pos_expr,
                IrBool(big_endian),
              ])
            EncUtf32 ->
              gprelude_call("bit_array_read_utf32_codepoint", [
                IrVar(subject_var),
                pos_expr,
                IrBool(big_endian),
              ])
          }
          let pos_pat = case ir_expr_uses_var(rest_guard, pos_var) {
            True -> IrPatVar(pos_var)
            False -> IrPatDiscard
          }
          let pair_pat = IrPatTuple([IrPatDiscard, pos_pat])
          #(match_some_else_false(reader_call, pair_pat, rest_guard), id1)
        }
      }
    }
  }
}

fn build_bit_bindings(
  segs: List(ParsedBitSeg),
  subject_var: String,
  pos_expr: IrExpr,
  next_id: Int,
) -> #(List(#(String, IrExpr)), Int) {
  case segs {
    [] -> #([], next_id)
    [seg, ..rest] -> {
      let user_names = seg_user_mangled_vars(seg) |> dedup_preserve_order
      case seg.kind {
        SegRest(require_byte_aligned) -> {
          let reader = case require_byte_aligned {
            True -> "bit_array_rest_bytes"
            False -> "bit_array_rest_bits"
          }
          case seg.nested_sub_var {
            None ->
              case user_names {
                [] -> #([], next_id)
                [first, ..others] -> {
                  let val_expr =
                    gprelude_call("bit_array_unwrap", [
                      gprelude_call(reader, [IrVar(subject_var), pos_expr]),
                    ])
                  let extra = list.map(others, fn(o) { #(o, IrVar(first)) })
                  #([#(first, val_expr), ..extra], next_id)
                }
              }
            Some(sub_var) -> {
              let sub_expr =
                gprelude_call("bit_array_unwrap", [
                  gprelude_call(reader, [IrVar(subject_var), pos_expr]),
                ])
              let alias_binds =
                list.map(seg.mangled_aliases, fn(a) { #(a, IrVar(sub_var)) })
              #(
                list.flatten([
                  [#(sub_var, sub_expr)],
                  alias_binds,
                  seg.nested_bindings,
                ]),
                next_id,
              )
            }
          }
        }

        SegInt(bits_expr, signed, big_endian) -> {
          let #(pos_binds, next_pos, id1) =
            advance_binding_pos(rest, pos_expr, bits_expr, next_id)
          let seg_binds = case user_names {
            [] -> []
            [first, ..others] -> {
              let val_expr =
                gprelude_call("bit_array_unwrap", [
                  gprelude_call("bit_array_read_int", [
                    IrVar(subject_var),
                    pos_expr,
                    bits_expr,
                    IrBool(signed),
                    IrBool(big_endian),
                  ]),
                ])
              let extra = list.map(others, fn(o) { #(o, IrVar(first)) })
              [#(first, val_expr), ..extra]
            }
          }
          let #(rest_binds, final_id) =
            build_bit_bindings(rest, subject_var, next_pos, id1)
          #(list.flatten([pos_binds, seg_binds, rest_binds]), final_id)
        }

        SegFloat(bits_expr, big_endian) -> {
          let #(pos_binds, next_pos, id1) =
            advance_binding_pos(rest, pos_expr, bits_expr, next_id)
          let seg_binds = case user_names {
            [] -> []
            [first, ..others] -> {
              let val_expr =
                gprelude_call("bit_array_unwrap", [
                  gprelude_call("bit_array_read_float", [
                    IrVar(subject_var),
                    pos_expr,
                    bits_expr,
                    IrBool(big_endian),
                  ]),
                ])
              let extra = list.map(others, fn(o) { #(o, IrVar(first)) })
              [#(first, val_expr), ..extra]
            }
          }
          let #(rest_binds, final_id) =
            build_bit_bindings(rest, subject_var, next_pos, id1)
          #(list.flatten([pos_binds, seg_binds, rest_binds]), final_id)
        }

        SegSizedBits(bits_expr) -> {
          let #(pos_binds, next_pos, id1) =
            advance_binding_pos(rest, pos_expr, bits_expr, next_id)
          let seg_binds = case seg.nested_sub_var {
            None ->
              case user_names {
                [] -> []
                [first, ..others] -> {
                  let val_expr =
                    gprelude_call("bit_array_unwrap", [
                      gprelude_call("bit_array_read_bits", [
                        IrVar(subject_var),
                        pos_expr,
                        bits_expr,
                      ]),
                    ])
                  let extra = list.map(others, fn(o) { #(o, IrVar(first)) })
                  [#(first, val_expr), ..extra]
                }
              }
            Some(sub_var) -> {
              let sub_expr =
                gprelude_call("bit_array_unwrap", [
                  gprelude_call("bit_array_read_bits", [
                    IrVar(subject_var),
                    pos_expr,
                    bits_expr,
                  ]),
                ])
              let alias_binds =
                list.map(seg.mangled_aliases, fn(a) { #(a, IrVar(sub_var)) })
              list.flatten([
                [#(sub_var, sub_expr)],
                alias_binds,
                seg.nested_bindings,
              ])
            }
          }
          let #(rest_binds, final_id) =
            build_bit_bindings(rest, subject_var, next_pos, id1)
          #(list.flatten([pos_binds, seg_binds, rest_binds]), final_id)
        }

        SegUtfString(value, enc, _big_endian) -> {
          let bits_len = utf_string_bit_length(value, enc)
          let next_pos = add_pos_expr(pos_expr, IrInt(int.to_string(bits_len)))
          let seg_binds =
            list.map(seg.mangled_aliases, fn(a) { #(a, IrString(value)) })
          let #(rest_binds, final_id) =
            build_bit_bindings(rest, subject_var, next_pos, next_id)
          #(list.append(seg_binds, rest_binds), final_id)
        }

        SegUtfCodepoint(enc, big_endian) ->
          case user_names, rest {
            [], [] -> #([], next_id)
            _, _ -> {
              let utf_var = "__utf_" <> int.to_string(next_id)
              let id1 = next_id + 1
              let reader_call = case enc {
                EncUtf8 ->
                  gprelude_call("bit_array_read_utf8_codepoint", [
                    IrVar(subject_var),
                    pos_expr,
                  ])
                EncUtf16 ->
                  gprelude_call("bit_array_read_utf16_codepoint", [
                    IrVar(subject_var),
                    pos_expr,
                    IrBool(big_endian),
                  ])
                EncUtf32 ->
                  gprelude_call("bit_array_read_utf32_codepoint", [
                    IrVar(subject_var),
                    pos_expr,
                    IrBool(big_endian),
                  ])
              }
              let utf_bind = #(
                utf_var,
                gprelude_call("bit_array_unwrap", [reader_call]),
              )
              let user_binds =
                list.map(user_names, fn(u) {
                  #(u, IrTupleIndex(IrVar(utf_var), 0))
                })
              let next_pos = IrTupleIndex(IrVar(utf_var), 1)
              let #(rest_binds, final_id) =
                build_bit_bindings(rest, subject_var, next_pos, id1)
              #(list.flatten([[utf_bind], user_binds, rest_binds]), final_id)
            }
          }
      }
    }
  }
}

fn advance_binding_pos(
  rest: List(ParsedBitSeg),
  pos_expr: IrExpr,
  bits_expr: IrExpr,
  next_id: Int,
) -> #(List(#(String, IrExpr)), IrExpr, Int) {
  case rest {
    [] -> #([], pos_expr, next_id)
    _ ->
      case is_ir_int(pos_expr) && is_ir_int(bits_expr) {
        True -> #([], add_pos_expr(pos_expr, bits_expr), next_id)
        False -> {
          let pos_var = "__bpos_" <> int.to_string(next_id)
          #(
            [#(pos_var, add_pos_expr(pos_expr, bits_expr))],
            IrVar(pos_var),
            next_id + 1,
          )
        }
      }
  }
}

fn seg_user_mangled_vars(seg: ParsedBitSeg) -> List(String) {
  let core_vars = case seg.core_pat {
    glance.PatternVariable(name:, ..) -> [mangle.mangle_ident(name)]
    _ -> []
  }
  list.append(core_vars, seg.mangled_aliases)
}

fn gprelude_call(symbol: String, args: List(IrExpr)) -> IrExpr {
  IrCall(
    function: IrModuleRef(
      module_alias: Some("gprelude"),
      target_module: "gprelude",
      symbol:,
    ),
    args: list.map(args, IrCallArg(None, _)),
  )
}

fn match_some_else_false(
  subject: IrExpr,
  some_pat: IrPattern,
  arm_body: IrExpr,
) -> IrExpr {
  IrMatch(subjects: [subject], clauses: [
    IrClause(
      patterns: [
        [IrPatVariant(None, None, "Some", [IrPatArg(None, some_pat)], False)],
      ],
      guard: None,
      prefix_bindings: [],
      body: arm_body,
    ),
    IrClause(
      patterns: [[IrPatVariant(None, None, "None", [], False)]],
      guard: None,
      prefix_bindings: [],
      body: IrBool(False),
    ),
  ])
}

fn utf_string_expr(
  value: String,
  enc: UtfEncoding,
  big_endian: Bool,
) -> IrExpr {
  case enc {
    EncUtf8 ->
      IrCall(
        function: IrModuleRef(
          module_alias: Some("gprelude"),
          target_module: "gprelude",
          symbol: "BitArray::from_string",
        ),
        args: [IrCallArg(None, IrString(value))],
      )
    EncUtf16 ->
      IrCall(
        function: IrModuleRef(
          module_alias: Some("gprelude"),
          target_module: "gprelude",
          symbol: "BitArray::from_utf16",
        ),
        args: [
          IrCallArg(None, IrString(value)),
          IrCallArg(None, IrBool(big_endian)),
        ],
      )
    EncUtf32 ->
      IrCall(
        function: IrModuleRef(
          module_alias: Some("gprelude"),
          target_module: "gprelude",
          symbol: "BitArray::from_utf32",
        ),
        args: [
          IrCallArg(None, IrString(value)),
          IrCallArg(None, IrBool(big_endian)),
        ],
      )
  }
}

fn utf_string_bit_length(value: String, enc: UtfEncoding) -> Int {
  case enc {
    EncUtf8 -> bit_array.byte_size(bit_array.from_string(value)) * 8
    EncUtf16 ->
      string.to_utf_codepoints(value)
      |> list.fold(0, fn(acc, cp) {
        case string.utf_codepoint_to_int(cp) > 0xFFFF {
          True -> acc + 32
          False -> acc + 16
        }
      })
    EncUtf32 -> list.length(string.to_utf_codepoints(value)) * 32
  }
}

fn is_ir_int(expr: IrExpr) -> Bool {
  case expr {
    IrInt(_) -> True
    _ -> False
  }
}

fn add_pos_expr(a: IrExpr, b: IrExpr) -> IrExpr {
  case a, b {
    IrInt(x), IrInt(y) ->
      case int.parse(x), int.parse(y) {
        Ok(ix), Ok(iy) -> IrInt(int.to_string(ix + iy))
        _, _ -> IrBinOp(IrAddInt, a, b)
      }
    IrInt("0"), _ -> b
    _, IrInt("0") -> a
    _, _ -> IrBinOp(IrAddInt, a, b)
  }
}

fn and_bool(a: IrExpr, b: IrExpr) -> IrExpr {
  case a, b {
    IrBool(True), _ -> b
    _, IrBool(True) -> a
    IrBool(False), _ | _, IrBool(False) -> IrBool(False)
    _, _ -> IrBinOp(IrAnd, a, b)
  }
}

fn wrap_guard_lets(
  vars: List(String),
  val_expr: IrExpr,
  rest_guard: IrExpr,
  pos_var: String,
  pos_expr: IrExpr,
  bits_expr: IrExpr,
  include_pos: Bool,
) -> IrExpr {
  let var_lets =
    list.filter_map(vars, fn(v) {
      case ir_expr_uses_var(rest_guard, v) {
        True -> Ok(IrStmtLet(IrPatVar(v), None, val_expr))
        False -> Error(Nil)
      }
    })
  let pos_lets = case include_pos && ir_expr_uses_var(rest_guard, pos_var) {
    True -> [
      IrStmtLet(IrPatVar(pos_var), None, add_pos_expr(pos_expr, bits_expr)),
    ]
    False -> []
  }
  let all_lets = list.append(pos_lets, var_lets)
  case all_lets {
    [] -> rest_guard
    _ -> IrBlock(list.append(all_lets, [IrStmtExpr(rest_guard)]))
  }
}

fn wrap_lets_block(bindings: List(#(String, IrExpr)), body: IrExpr) -> IrExpr {
  case bindings {
    [] -> body
    _ -> {
      let lets =
        list.map(bindings, fn(b) { IrStmtLet(IrPatVar(b.0), None, b.1) })
      IrBlock(list.append(lets, [IrStmtExpr(body)]))
    }
  }
}

fn prune_bit_bindings(
  bindings: List(#(String, IrExpr)),
  needed: Set(String),
) -> List(#(String, IrExpr)) {
  let #(kept, _) =
    list.fold_right(bindings, #([], needed), fn(acc, b) {
      let #(kept_acc, need_set) = acc
      case set.contains(need_set, b.0) {
        True -> {
          let next_need =
            set.union(
              set.delete(need_set, b.0),
              collect_ir_expr_vars(b.1, set.new()),
            )
          #([b, ..kept_acc], next_need)
        }
        False -> #(kept_acc, need_set)
      }
    })
  kept
}

fn dedup_preserve_order(items: List(String)) -> List(String) {
  let #(rev, _) =
    list.fold(items, #([], set.new()), fn(acc, item) {
      let #(out, seen) = acc
      case set.contains(seen, item) {
        True -> acc
        False -> #([item, ..out], set.insert(seen, item))
      }
    })
  list.reverse(rev)
}

fn ir_expr_uses_var(expr: IrExpr, name: String) -> Bool {
  set.contains(collect_ir_expr_vars(expr, set.new()), name)
}

fn collect_ir_expr_vars(expr: IrExpr, acc: Set(String)) -> Set(String) {
  case expr {
    IrVar(name) -> set.insert(acc, name)
    ir.IrNegateInt(inner)
    | ir.IrNegateBool(inner)
    | ir.IrBreak(inner)
    | ir.IrGetterCall(receiver: inner, ..)
    | IrTupleIndex(tuple: inner, ..) -> collect_ir_expr_vars(inner, acc)
    IrBinOp(left:, right:, ..) ->
      collect_ir_expr_vars(right, collect_ir_expr_vars(left, acc))
    ir.IrTuple(els) | ir.IrContinue(els) ->
      list.fold(els, acc, fn(a, e) { collect_ir_expr_vars(e, a) })
    ir.IrList(elements:, tail:) -> {
      let a1 = list.fold(elements, acc, fn(a, e) { collect_ir_expr_vars(e, a) })
      case tail {
        Some(t) -> collect_ir_expr_vars(t, a1)
        None -> a1
      }
    }
    IrBitString(segments:) ->
      list.fold(segments, acc, fn(a, seg) {
        let a1 = collect_ir_expr_vars(seg.0, a)
        list.fold(seg.1, a1, fn(inner_a, opt) {
          case opt {
            glance.SizeValueOption(se) -> collect_ir_expr_vars(se, inner_a)
            _ -> inner_a
          }
        })
      })
    IrCall(function:, args:) -> {
      let a1 = collect_ir_expr_vars(function, acc)
      list.fold(args, a1, fn(a, arg) { collect_ir_expr_vars(arg.value, a) })
    }
    IrBlock(stmts) -> set.union(acc, collect_ir_stmts_vars(stmts))
    ir.IrFn(params:, body:, ..) -> {
      let bound = set.from_list(list.map(params, fn(p) { p.name }))
      set.union(acc, set.difference(collect_ir_stmts_vars(body), bound))
    }
    ir.IrForLoop(bindings:, body:) -> {
      let b_vals =
        list.fold(bindings, acc, fn(a, b) { collect_ir_expr_vars(b.1, a) })
      let bound = set.from_list(list.map(bindings, fn(b) { b.0 }))
      set.union(b_vals, set.difference(collect_ir_stmts_vars(body), bound))
    }
    IrMatch(subjects:, clauses:) -> {
      let a1 = list.fold(subjects, acc, fn(a, s) { collect_ir_expr_vars(s, a) })
      list.fold(clauses, a1, fn(a, c) {
        let pat_vars = case c.patterns {
          [first_alt, ..] ->
            list.fold(first_alt, set.new(), fn(ps, p) {
              set.union(ps, ir_pat_bound_vars(p))
            })
          [] -> set.new()
        }
        let body_fv = collect_ir_expr_vars(c.body, set.new())
        let after_pb =
          list.fold_right(c.prefix_bindings, body_fv, fn(fv, pb) {
            set.union(
              set.delete(fv, pb.0),
              collect_ir_expr_vars(pb.1, set.new()),
            )
          })
        let g_fv = case c.guard {
          Some(g) -> collect_ir_expr_vars(g, after_pb)
          None -> after_pb
        }
        set.union(a, set.difference(g_fv, pat_vars))
      })
    }
    ir.IrEcho(expr: inner, message:, ..) -> {
      let a1 = collect_ir_expr_vars(inner, acc)
      case message {
        Some(m) -> collect_ir_expr_vars(m, a1)
        None -> a1
      }
    }
    ir.IrAbort(message: Some(m), ..) -> collect_ir_expr_vars(m, acc)
    _ -> acc
  }
}

fn collect_ir_stmts_vars(stmts: List(IrStmt)) -> Set(String) {
  list.fold_right(stmts, set.new(), fn(rest_fv, stmt) {
    case stmt {
      IrStmtLet(pattern:, value:, ..) ->
        set.union(
          collect_ir_expr_vars(value, set.new()),
          set.difference(rest_fv, ir_pat_bound_vars(pattern)),
        )
      IrStmtGuard(
        value:,
        pattern:,
        guard_condition:,
        abort_message:,
        post_bindings:,
      ) -> {
        let pat_vars = ir_pat_bound_vars(pattern)
        let after_pb =
          list.fold_right(post_bindings, rest_fv, fn(fv, pb) {
            set.union(
              set.delete(fv, pb.0),
              collect_ir_expr_vars(pb.1, set.new()),
            )
          })
        let cond_fv = case guard_condition {
          Some(g) -> collect_ir_expr_vars(g, after_pb)
          None -> after_pb
        }
        let msg_fv = case abort_message {
          Some(m) -> collect_ir_expr_vars(m, set.new())
          None -> set.new()
        }
        set.union(
          collect_ir_expr_vars(value, set.new()),
          set.union(msg_fv, set.difference(cond_fv, pat_vars)),
        )
      }
      IrStmtAssert(condition:, abort_message:) -> {
        let a1 = collect_ir_expr_vars(condition, rest_fv)
        case abort_message {
          Some(m) -> collect_ir_expr_vars(m, a1)
          None -> a1
        }
      }
      IrStmtExpr(e) -> set.union(rest_fv, collect_ir_expr_vars(e, set.new()))
    }
  })
}

fn ir_pat_bound_vars(pat: IrPattern) -> Set(String) {
  case pat {
    IrPatVar(name) -> set.from_list([name])
    IrPatAs(inner, alias) -> set.insert(ir_pat_bound_vars(inner), alias)
    IrPatTuple(els) ->
      list.fold(els, set.new(), fn(acc, el) {
        set.union(acc, ir_pat_bound_vars(el))
      })
    IrPatVariant(args:, ..) ->
      list.fold(args, set.new(), fn(acc, arg) {
        set.union(acc, ir_pat_bound_vars(arg.pattern))
      })
    IrPatBitString(segments:) ->
      list.fold(segments, set.new(), fn(acc, seg) {
        set.union(acc, ir_pat_bound_vars(seg.0))
      })
    _ -> set.new()
  }
}
