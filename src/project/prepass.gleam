import glance
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glexer
import glexer/token.{type Token}
import project/text_edit.{
  type TextEdit, TextEdit, apply_edits, skip_trivia,
  stripped_comment_preserving_lines, token_end,
}

/// Target MoonBit binding kind for an `@external(moonbit, ...)` directive.
pub type FfiKind {
  /// Calls a function inside another MoonBit package: `@pkg_alias.function(...)`
  PackageCall(package: String, function: String)
  /// Emits a raw WebAssembly import stub: `fn __ffi_name(...) -> ... = "mod" "import"`
  WasmImport(wasm_module: String, import_name: String)
}

/// How the FFI mapping was declared in the Gleam source file.
pub type FfiSource {
  DocPragma
  RawAttribute
}

/// An extracted `@external(moonbit, ...)` mapping bound to a top-level function.
pub type FfiEntry {
  FfiEntry(
    module: String,
    function_name: String,
    kind: FfiKind,
    source: FfiSource,
    line: Int,
  )
}

/// Output of running the source pre-pass over a single Gleam module.
pub type PrepassResult {
  PrepassResult(cleaned_source: String, ffi_entries: List(FfiEntry))
}

type PendingFfi {
  PendingFfi(kind: FfiKind, source: FfiSource, line: Int)
}

/// Parse a target string + function name into `PackageCall` or `WasmImport`.
pub fn parse_ffi_kind(target: String, function: String) -> FfiKind {
  case string.split_once(target, on: "wasm:") {
    Ok(#("", wasm_module)) -> WasmImport(wasm_module:, import_name: function)
    _ -> PackageCall(package: target, function:)
  }
}

/// Scan `source` for `/// @external(moonbit, ...)` doc-comment pragmas and raw
/// `@external(moonbit, ...)` attributes, strip raw attributes while preserving
/// exact line numbers, and inject `{ panic as "external" }` for bodyless FFI
/// functions so `glance` and `gleam export package-interface` succeed.
pub fn preprocess_module(module_name: String, source: String) -> PrepassResult {
  let tokens =
    glexer.new(source)
    |> glexer.lex

  let #(entries, edits) =
    scan_tokens(tokens, source, module_name, 0, [], [], [])

  let cleaned_source = apply_edits(source, edits)

  PrepassResult(cleaned_source:, ffi_entries: list.reverse(entries))
}

/// Run the pre-pass and parse the cleaned source with `glance.module`.
pub fn parse_module(
  module_name: String,
  source: String,
) -> Result(#(glance.Module, PrepassResult), glance.Error) {
  let result = preprocess_module(module_name, source)
  use parsed <- result.try(glance.module(result.cleaned_source))
  Ok(#(parsed, result))
}

fn scan_tokens(
  tokens: List(#(Token, glexer.Position)),
  source: String,
  module_name: String,
  brace_depth: Int,
  pending: List(PendingFfi),
  entries: List(FfiEntry),
  edits: List(TextEdit),
) -> #(List(FfiEntry), List(TextEdit)) {
  case tokens {
    [] -> #(entries, edits)

    [#(token.LeftBrace, _), ..rest] ->
      scan_tokens(
        rest,
        source,
        module_name,
        brace_depth + 1,
        [],
        entries,
        edits,
      )

    [#(token.RightBrace, _), ..rest] ->
      scan_tokens(
        rest,
        source,
        module_name,
        int.max(0, brace_depth - 1),
        [],
        entries,
        edits,
      )

    // Skip whitespace & regular/module comments without dropping pending FFI pragmas.
    [#(token.Space(_), _), ..rest]
    | [#(token.CommentNormal(_), _), ..rest]
    | [#(token.CommentModule(_), _), ..rest] ->
      scan_tokens(
        rest,
        source,
        module_name,
        brace_depth,
        pending,
        entries,
        edits,
      )

    // Doc comment at top level: check for `/// @external(moonbit, "pkg", "fn")`
    [#(token.CommentDoc(doc_text), pos), ..rest] if brace_depth == 0 -> {
      let pending = case parse_doc_pragma(doc_text) {
        Some(kind) -> {
          let line = line_at_offset(source, pos.byte_offset)
          [PendingFfi(kind:, source: DocPragma, line:), ..pending]
        }
        None -> pending
      }
      scan_tokens(
        rest,
        source,
        module_name,
        brace_depth,
        pending,
        entries,
        edits,
      )
    }

    // Raw attribute at top level: check for `@external(moonbit, "pkg", "fn")`
    [#(token.At, pos), ..after_at] if brace_depth == 0 -> {
      case match_raw_external_moonbit(after_at) {
        Some(#(kind, end_offset, remaining)) -> {
          let start_offset = pos.byte_offset
          let line = line_at_offset(source, start_offset)
          let replacement =
            stripped_comment_preserving_lines(
              source,
              start_offset,
              end_offset,
              "// @external_moonbit_stripped",
            )
          let edit =
            TextEdit(start: start_offset, end: end_offset, replacement:)
          let pending = [
            PendingFfi(kind:, source: RawAttribute, line:),
            ..pending
          ]
          scan_tokens(
            remaining,
            source,
            module_name,
            brace_depth,
            pending,
            entries,
            [edit, ..edits],
          )
        }
        None ->
          scan_tokens(
            after_at,
            source,
            module_name,
            brace_depth,
            pending,
            entries,
            edits,
          )
      }
    }

    // Top-level `pub fn <name>(...)` or `fn <name>(...)`
    [#(token.Pub, _), ..after_pub] if brace_depth == 0 -> {
      let after_ws = skip_trivia(after_pub)
      case after_ws {
        [#(token.Fn, _), ..after_fn] ->
          handle_top_fn(after_fn, source, module_name, pending, entries, edits)
        [#(token.Type, _), ..rest]
        | [#(token.Opaque, _), ..rest]
        | [#(token.Const, _), ..rest] ->
          scan_tokens(
            rest,
            source,
            module_name,
            brace_depth,
            [],
            entries,
            edits,
          )
        _ ->
          scan_tokens(
            after_ws,
            source,
            module_name,
            brace_depth,
            [],
            entries,
            edits,
          )
      }
    }

    [#(token.Fn, _), ..after_fn] if brace_depth == 0 ->
      handle_top_fn(after_fn, source, module_name, pending, entries, edits)

    // Non-function top-level declaration clears any stray pending FFI pragma
    [#(token.Type, _), ..rest]
      | [#(token.Opaque, _), ..rest]
      | [#(token.Const, _), ..rest]
      | [#(token.Import, _), ..rest]
      if brace_depth == 0
    -> scan_tokens(rest, source, module_name, brace_depth, [], entries, edits)

    [_, ..rest] ->
      scan_tokens(
        rest,
        source,
        module_name,
        brace_depth,
        pending,
        entries,
        edits,
      )
  }
}

fn handle_top_fn(
  after_fn: List(#(Token, glexer.Position)),
  source: String,
  module_name: String,
  pending: List(PendingFfi),
  entries: List(FfiEntry),
  edits: List(TextEdit),
) -> #(List(FfiEntry), List(TextEdit)) {
  case skip_trivia(after_fn) {
    [#(token.Name(fn_name), _), ..after_name] -> {
      case skip_trivia(after_name) {
        [#(token.LeftParen, _), ..] as params_tokens -> {
          let new_entries =
            pending
            |> list.reverse
            |> list.map(fn(p) {
              FfiEntry(
                module: module_name,
                function_name: fn_name,
                kind: p.kind,
                source: p.source,
                line: p.line,
              )
            })
          let entries =
            list.fold(new_entries, entries, fn(acc, e) { [e, ..acc] })

          let #(edits, remaining) = case pending {
            [] -> #(edits, params_tokens)
            [_, ..] ->
              case find_fn_signature_end(params_tokens) {
                Some(#(sig_end, has_body, rest_tokens)) ->
                  case has_body {
                    True -> #(edits, rest_tokens)
                    False -> {
                      let edit =
                        TextEdit(
                          start: sig_end,
                          end: sig_end,
                          replacement: " { panic as \"external\" }",
                        )
                      #([edit, ..edits], rest_tokens)
                    }
                  }
                None -> #(edits, params_tokens)
              }
          }
          scan_tokens(remaining, source, module_name, 0, [], entries, edits)
        }
        other -> scan_tokens(other, source, module_name, 0, [], entries, edits)
      }
    }
    other -> scan_tokens(other, source, module_name, 0, [], entries, edits)
  }
}

fn parse_doc_pragma(doc_text: String) -> Option(FfiKind) {
  let trimmed = string.trim(doc_text)
  case string.starts_with(trimmed, "@external") {
    False -> None
    True -> {
      let tokens =
        glexer.new(trimmed)
        |> glexer.lex
      case tokens {
        [#(token.At, _), ..after_at] ->
          case match_raw_external_moonbit(after_at) {
            Some(#(kind, _, remaining)) ->
              case skip_trivia(remaining) {
                [] -> Some(kind)
                _ -> None
              }
            None -> None
          }
        _ -> None
      }
    }
  }
}

fn match_raw_external_moonbit(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(FfiKind, Int, List(#(Token, glexer.Position)))) {
  case skip_trivia(tokens) {
    [#(token.Name("external"), _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.LeftParen, _), ..rest] ->
          case skip_trivia(rest) {
            [#(token.Name("moonbit"), _), ..rest] ->
              case skip_trivia(rest) {
                [#(token.Comma, _), ..rest] ->
                  case skip_trivia(rest) {
                    [#(token.String(target), _), ..rest] ->
                      case skip_trivia(rest) {
                        [#(token.Comma, _), ..rest] ->
                          case skip_trivia(rest) {
                            [#(token.String(fn_name), _), ..rest] ->
                              match_trailing_close_paren(
                                rest,
                                parse_ffi_kind(target, fn_name),
                              )
                            _ -> None
                          }
                        _ -> None
                      }
                    _ -> None
                  }
                _ -> None
              }
            _ -> None
          }
        _ -> None
      }
    _ -> None
  }
}

fn match_trailing_close_paren(
  tokens: List(#(Token, glexer.Position)),
  kind: FfiKind,
) -> Option(#(FfiKind, Int, List(#(Token, glexer.Position)))) {
  case skip_trivia(tokens) {
    [#(token.Comma, _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.RightParen, pos), ..after] ->
          Some(#(kind, pos.byte_offset + 1, after))
        _ -> None
      }
    [#(token.RightParen, pos), ..after] ->
      Some(#(kind, pos.byte_offset + 1, after))
    _ -> None
  }
}

fn find_fn_signature_end(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(Int, Bool, List(#(Token, glexer.Position)))) {
  case tokens {
    [#(token.LeftParen, _), ..rest] -> {
      use #(params_end, after_params) <- option.then(consume_balanced_parens(
        rest,
        1,
      ))
      let #(sig_end, after_sig) = case skip_trivia(after_params) {
        [#(token.RightArrow, _), ..after_arrow] ->
          case skip_type(after_arrow) {
            Some(#(ret_end, after_ret)) -> #(ret_end, after_ret)
            None -> #(params_end, after_params)
          }
        _ -> #(params_end, after_params)
      }
      case skip_trivia(after_sig) {
        [#(token.LeftBrace, _), ..] -> Some(#(sig_end, True, after_sig))
        _ -> Some(#(sig_end, False, after_sig))
      }
    }
    _ -> None
  }
}

fn consume_balanced_parens(
  tokens: List(#(Token, glexer.Position)),
  depth: Int,
) -> Option(#(Int, List(#(Token, glexer.Position)))) {
  case tokens {
    [] -> None
    [#(token.LeftParen, _), ..rest] -> consume_balanced_parens(rest, depth + 1)
    [#(token.RightParen, pos), ..rest] ->
      case depth == 1 {
        True -> Some(#(pos.byte_offset + 1, rest))
        False -> consume_balanced_parens(rest, depth - 1)
      }
    [_, ..rest] -> consume_balanced_parens(rest, depth)
  }
}

fn skip_type(
  tokens: List(#(Token, glexer.Position)),
) -> Option(#(Int, List(#(Token, glexer.Position)))) {
  case skip_trivia(tokens) {
    [#(token.Fn, _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.LeftParen, _), ..after_lp] -> {
          use #(_, after_rp) <- option.then(consume_balanced_parens(after_lp, 1))
          case skip_trivia(after_rp) {
            [#(token.RightArrow, _), ..after_arrow] -> skip_type(after_arrow)
            _ -> None
          }
        }
        _ -> None
      }

    [#(token.Hash, _), ..rest] ->
      case skip_trivia(rest) {
        [#(token.LeftParen, _), ..after_lp] ->
          consume_balanced_parens(after_lp, 1)
        _ -> None
      }

    [#(token.DiscardName(_) as tok, pos), ..rest] ->
      Some(#(token_end(tok, pos), rest))

    [#(token.Name(_) as tok, pos), ..rest]
    | [#(token.UpperName(_) as tok, pos), ..rest] -> {
      let #(end1, after_name) = case skip_trivia(rest) {
        [#(token.Dot, _), ..after_dot] ->
          case skip_trivia(after_dot) {
            [#(token.UpperName(_) as qual_tok, qual_pos), ..after_qual] -> #(
              token_end(qual_tok, qual_pos),
              after_qual,
            )
            _ -> #(token_end(tok, pos), rest)
          }
        _ -> #(token_end(tok, pos), rest)
      }
      case skip_trivia(after_name) {
        [#(token.LeftParen, _), ..after_lp] ->
          consume_balanced_parens(after_lp, 1)
        _ -> Some(#(end1, after_name))
      }
    }

    _ -> None
  }
}

fn line_at_offset(source: String, offset: Int) -> Int {
  let bytes = bit_array.from_string(source)
  let prefix = case bit_array.slice(bytes, 0, offset) {
    Ok(slice) ->
      bit_array.to_string(slice)
      |> result.unwrap("")
    Error(_) -> ""
  }
  prefix
  |> string.split("\n")
  |> list.length
}
