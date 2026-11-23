import glance
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import index/symbol_table.{type ModuleSymbols, type SymbolTable}

/// Minimum value representable in MoonBit `Int64` (`-2^63`).
pub const int64_min = -9_223_372_036_854_775_808

/// Maximum value representable in MoonBit `Int64` (`2^63 - 1`).
pub const int64_max = 9_223_372_036_854_775_807

type ValidateCtx {
  ValidateCtx(
    package_name: String,
    table: SymbolTable,
    module_name: String,
    source: String,
  )
}

/// Parse a Gleam integer literal string (decimal, `0x`, `0o`, `0b`, with
/// optional leading `-` and `_` separators) into an exact Gleam `Int`.
pub fn parse_gleam_int_literal(raw: String) -> Result(Int, Nil) {
  let #(is_neg, mag_str) = case string.starts_with(raw, "-") {
    True -> #(True, string.drop_start(raw, 1))
    False -> #(False, raw)
  }
  let #(base, digits_with_underscores) = case mag_str {
    "0x" <> rest | "0X" <> rest -> #(16, rest)
    "0o" <> rest | "0O" <> rest -> #(8, rest)
    "0b" <> rest | "0B" <> rest -> #(2, rest)
    _ -> #(10, mag_str)
  }
  let digits = string.replace(digits_with_underscores, "_", "")
  case
    digits == ""
    || string.starts_with(digits, "-")
    || string.starts_with(digits, "+")
  {
    True -> Error(Nil)
    False -> {
      use parsed <- result.try(int.base_parse(digits, base))
      case is_neg {
        True -> Ok(0 - parsed)
        False -> Ok(parsed)
      }
    }
  }
}

/// Validate all emitted integer literals in a module belonging to the root package.
pub fn validate_module_int_literals(
  ast_mod: glance.Module,
  table: SymbolTable,
  module_name: String,
) -> Result(Nil, String) {
  validate_module_int_literals_in_package(
    table.package_name,
    ast_mod,
    table,
    module_name,
  )
}

/// Validate all emitted integer literals in a module belonging to `package_name`.
pub fn validate_module_int_literals_in_package(
  package_name: String,
  ast_mod: glance.Module,
  table: SymbolTable,
  module_name: String,
) -> Result(Nil, String) {
  let mod_syms = case dict.get(table.modules, module_name) {
    Ok(ms) -> ms
    Error(_) -> empty_module_symbols(module_name)
  }
  let ctx =
    ValidateCtx(package_name:, table:, module_name:, source: mod_syms.source)

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

  let rev_after_consts =
    list.fold(ast_constants, [], fn(acc, def) {
      validate_expr(def.definition.value, ctx, acc)
    })

  let rev_errs =
    list.fold(ast_functions, rev_after_consts, fn(acc, def) {
      let has_ffi = case dict.get(mod_syms.functions, def.definition.name) {
        Ok(fn_info) -> option.is_some(fn_info.ffi)
        Error(_) -> False
      }
      case has_ffi {
        True -> acc
        False -> validate_stmts(def.definition.body, ctx, acc)
      }
    })

  case rev_errs {
    [] -> Ok(Nil)
    _ -> Error(string.join(list.reverse(rev_errs), "\n"))
  }
}

fn empty_module_symbols(module_name: String) -> ModuleSymbols {
  symbol_table.empty_module_symbols(module_name)
}

fn validate_stmts(
  stmts: List(glance.Statement),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  list.fold(stmts, acc, fn(cur_acc, stmt) { validate_stmt(stmt, ctx, cur_acc) })
}

fn validate_stmt(
  stmt: glance.Statement,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case stmt {
    glance.Use(patterns:, function:, ..) -> {
      let acc1 =
        list.fold(patterns, acc, fn(cur_acc, up) {
          validate_pattern(up.pattern, ctx, cur_acc)
        })
      validate_expr(function, ctx, acc1)
    }

    glance.Assignment(kind:, pattern:, value:, ..) -> {
      let acc1 = validate_pattern(pattern, ctx, acc)
      let acc2 = validate_expr(value, ctx, acc1)
      case kind {
        glance.Let -> acc2
        glance.LetAssert(message:) -> validate_opt_expr(message, ctx, acc2)
      }
    }

    glance.Assert(expression:, message:, ..) -> {
      let acc1 = validate_expr(expression, ctx, acc)
      validate_opt_expr(message, ctx, acc1)
    }

    glance.Expression(expr) -> validate_expr(expr, ctx, acc)
  }
}

fn validate_opt_expr(
  expr_opt: Option(glance.Expression),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case expr_opt {
    Some(e) -> validate_expr(e, ctx, acc)
    None -> acc
  }
}

fn validate_exprs(
  exprs: List(glance.Expression),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  list.fold(exprs, acc, fn(cur_acc, e) { validate_expr(e, ctx, cur_acc) })
}

fn validate_field_expr(
  field: glance.Field(glance.Expression),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case field {
    glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
      validate_expr(item, ctx, acc)
    glance.ShorthandField(..) -> acc
  }
}

fn validate_expr(
  expr: glance.Expression,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case expr {
    glance.Int(location:, value:) -> check_int_str(location, value, ctx, acc)
    glance.Float(..) | glance.String(..) | glance.Variable(..) -> acc
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      validate_expr(value, ctx, acc)
    glance.Block(statements:, ..) -> validate_stmts(statements, ctx, acc)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      validate_opt_expr(message, ctx, acc)
    glance.Tuple(elements:, ..) -> validate_exprs(elements, ctx, acc)
    glance.List(elements:, rest:, ..) -> {
      let acc1 = validate_exprs(elements, ctx, acc)
      validate_opt_expr(rest, ctx, acc1)
    }
    glance.Fn(body:, ..) -> validate_stmts(body, ctx, acc)
    glance.RecordUpdate(record:, fields:, ..) -> {
      let acc1 = validate_expr(record, ctx, acc)
      list.fold(fields, acc1, fn(cur_acc, ruf) {
        validate_opt_expr(ruf.item, ctx, cur_acc)
      })
    }
    glance.FieldAccess(container:, ..) -> validate_expr(container, ctx, acc)
    glance.Call(function:, arguments:, ..) -> {
      let acc1 = validate_expr(function, ctx, acc)
      list.fold(arguments, acc1, fn(cur_acc, arg) {
        validate_field_expr(arg, ctx, cur_acc)
      })
    }
    glance.TupleIndex(tuple:, ..) -> validate_expr(tuple, ctx, acc)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) -> {
      let acc1 = validate_expr(function, ctx, acc)
      let acc2 =
        list.fold(arguments_before, acc1, fn(cur_acc, arg) {
          validate_field_expr(arg, ctx, cur_acc)
        })
      list.fold(arguments_after, acc2, fn(cur_acc, arg) {
        validate_field_expr(arg, ctx, cur_acc)
      })
    }
    glance.BitString(location:, segments:) ->
      list.fold(segments, acc, fn(cur_acc, seg) {
        let #(val_expr, opts) = seg
        let acc1 = validate_expr(val_expr, ctx, cur_acc)
        validate_bit_expr_opts(opts, location, ctx, acc1)
      })
    glance.Case(subjects:, clauses:, ..) -> {
      let acc1 = validate_exprs(subjects, ctx, acc)
      list.fold(clauses, acc1, fn(cur_acc, clause) {
        let acc2 =
          list.fold(clause.patterns, cur_acc, fn(p_acc, pat_row) {
            validate_patterns(pat_row, ctx, p_acc)
          })
        let acc3 = validate_opt_expr(clause.guard, ctx, acc2)
        validate_expr(clause.body, ctx, acc3)
      })
    }
    glance.BinaryOperator(left:, right:, ..) -> {
      let acc1 = validate_expr(left, ctx, acc)
      validate_expr(right, ctx, acc1)
    }
    glance.Echo(expression:, message:, ..) -> {
      let acc1 = validate_opt_expr(expression, ctx, acc)
      validate_opt_expr(message, ctx, acc1)
    }
  }
}

fn validate_bit_expr_opts(
  opts: List(glance.BitStringSegmentOption(glance.Expression)),
  parent_span: glance.Span,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  list.fold(opts, acc, fn(cur_acc, opt) {
    case opt {
      glance.BytesOption
      | glance.IntOption
      | glance.FloatOption
      | glance.BitsOption
      | glance.Utf8Option
      | glance.Utf16Option
      | glance.Utf32Option
      | glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption
      | glance.SignedOption
      | glance.UnsignedOption
      | glance.BigOption
      | glance.LittleOption
      | glance.NativeOption -> cur_acc
      glance.SizeValueOption(expr) -> validate_expr(expr, ctx, cur_acc)
      glance.SizeOption(n) | glance.UnitOption(n) ->
        check_int_value(parent_span, int.to_string(n), n, ctx, cur_acc)
    }
  })
}

fn validate_patterns(
  pats: List(glance.Pattern),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  list.fold(pats, acc, fn(cur_acc, p) { validate_pattern(p, ctx, cur_acc) })
}

fn validate_opt_pattern(
  pat_opt: Option(glance.Pattern),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case pat_opt {
    Some(p) -> validate_pattern(p, ctx, acc)
    None -> acc
  }
}

fn validate_field_pattern(
  field: glance.Field(glance.Pattern),
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case field {
    glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
      validate_pattern(item, ctx, acc)
    glance.ShorthandField(..) -> acc
  }
}

fn validate_pattern(
  pat: glance.Pattern,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case pat {
    glance.PatternInt(location:, value:) ->
      check_int_str(location, value, ctx, acc)
    glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..)
    | glance.PatternVariable(..)
    | glance.PatternConcatenate(..) -> acc
    glance.PatternTuple(elements:, ..) -> validate_patterns(elements, ctx, acc)
    glance.PatternList(elements:, tail:, ..) -> {
      let acc1 = validate_patterns(elements, ctx, acc)
      validate_opt_pattern(tail, ctx, acc1)
    }
    glance.PatternAssignment(pattern:, ..) ->
      validate_pattern(pattern, ctx, acc)
    glance.PatternBitString(location:, segments:) ->
      list.fold(segments, acc, fn(cur_acc, seg) {
        let #(inner_pat, opts) = seg
        let acc1 = validate_pattern(inner_pat, ctx, cur_acc)
        validate_bit_pat_opts(opts, location, ctx, acc1)
      })
    glance.PatternVariant(arguments:, ..) ->
      list.fold(arguments, acc, fn(cur_acc, arg) {
        validate_field_pattern(arg, ctx, cur_acc)
      })
  }
}

fn validate_bit_pat_opts(
  opts: List(glance.BitStringSegmentOption(glance.BitArraySize)),
  parent_span: glance.Span,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  list.fold(opts, acc, fn(cur_acc, opt) {
    case opt {
      glance.BytesOption
      | glance.IntOption
      | glance.FloatOption
      | glance.BitsOption
      | glance.Utf8Option
      | glance.Utf16Option
      | glance.Utf32Option
      | glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption
      | glance.SignedOption
      | glance.UnsignedOption
      | glance.BigOption
      | glance.LittleOption
      | glance.NativeOption -> cur_acc
      glance.SizeValueOption(size) -> validate_bit_size(size, ctx, cur_acc)
      glance.SizeOption(n) | glance.UnitOption(n) ->
        check_int_value(parent_span, int.to_string(n), n, ctx, cur_acc)
    }
  })
}

fn validate_bit_size(
  size: glance.BitArraySize,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case size {
    glance.BitArraySizeInt(location:, value:) ->
      check_int_str(location, value, ctx, acc)
    glance.BitArraySizeVariable(..) -> acc
    glance.BitArraySizeBinaryOperator(left:, right:, ..) -> {
      let acc1 = validate_bit_size(left, ctx, acc)
      validate_bit_size(right, ctx, acc1)
    }
    glance.BitArraySizeBlock(inner:, ..) -> validate_bit_size(inner, ctx, acc)
  }
}

fn check_int_str(
  span: glance.Span,
  raw: String,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case parse_gleam_int_literal(raw) {
    Ok(value) -> check_int_value(span, raw, value, ctx, acc)
    Error(_) -> acc
  }
}

fn check_int_value(
  span: glance.Span,
  raw: String,
  value: Int,
  ctx: ValidateCtx,
  acc: List(String),
) -> List(String) {
  case value < int64_min || value > int64_max {
    True -> [format_range_error(span, raw, ctx), ..acc]
    False -> acc
  }
}

fn format_range_error(
  span: glance.Span,
  raw: String,
  ctx: ValidateCtx,
) -> String {
  let base_path = case string.starts_with(ctx.module_name, "test/") {
    True -> ctx.module_name <> ".gleam"
    False -> "src/" <> ctx.module_name <> ".gleam"
  }
  let file_path = case
    ctx.package_name == ctx.table.package_name || ctx.package_name == ""
  {
    True -> base_path
    False -> ctx.package_name <> ":" <> base_path
  }
  let #(line, col) = offset_to_line_col(ctx.source, span.start)
  file_path
  <> ":"
  <> int.to_string(line)
  <> ":"
  <> int.to_string(col)
  <> ": Integer literal `"
  <> raw
  <> "` is out of signed 64-bit Int64 range (-9223372036854775808..9223372036854775807)"
}

fn offset_to_line_col(source: String, byte_offset: Int) -> #(Int, Int) {
  let src_bits = bit_array.from_string(source)
  let limit = int.min(int.max(byte_offset, 0), bit_array.byte_size(src_bits))
  case bit_array.slice(src_bits, at: 0, take: limit) {
    Ok(prefix) ->
      case bit_array.to_string(prefix) {
        Ok(prefix_str) -> {
          let lines = string.split(prefix_str, "\n")
          let line = list.length(lines)
          let col = case list.last(lines) {
            Ok(last) -> string.length(last) + 1
            Error(_) -> 1
          }
          #(line, col)
        }
        Error(_) -> #(count_newlines(prefix, 1), 1)
      }
    Error(_) -> #(1, 1)
  }
}

fn count_newlines(bits: BitArray, line: Int) -> Int {
  case bits {
    <<10, rest:bits>> -> count_newlines(rest, line + 1)
    <<_, rest:bits>> -> count_newlines(rest, line)
    _ -> line
  }
}
