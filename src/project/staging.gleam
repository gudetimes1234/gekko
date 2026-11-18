import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glexer
import glexer/token.{type Token}
import project/cmd
import project/interface.{type PackageInterface}
import project/prepass
import project/text_edit.{
  type TextEdit, TextEdit, apply_edits, skip_trivia, token_end,
}
import simplifile

/// Preprocess `@external(moonbit, ...)` directives and promote all top-level
/// private `fn`, `type`, `opaque type`, and `const` declarations to `pub`
/// (stripping `@internal` attributes) so `gleam export package-interface`
/// outputs compiler-inferred Hindley-Milner signatures for every item.
pub fn promote_private_to_pub(source: String) -> String {
  let cleaned = prepass.preprocess_module("", source).cleaned_source
  let tokens =
    glexer.new(cleaned)
    |> glexer.lex

  let edits = collect_pub_edits(tokens, 0, False, [])
  apply_edits(cleaned, edits)
}

/// Remove any root-table `internal_modules = [...]` setting in `gleam.toml`
/// and prepend `internal_modules = []` so internal modules are included in
/// `gleam export package-interface`.
pub fn override_gleam_toml_internal_modules(toml_src: String) -> String {
  let lines = string.split(toml_src, "\n")
  let filtered = filter_root_internal_modules(lines, True, False, 0, [])
  "internal_modules = []\n" <> string.join(filtered, "\n")
}

/// Stage a transformed copy of `project_root` inside `staging_dir`, run
/// `gleam export package-interface --out interface.json`, and decode the result.
pub fn extract_project_interface(
  project_root: String,
  staging_dir: String,
) -> Result(PackageInterface, String) {
  extract_package_interface_with_deps(project_root, project_root, staging_dir)
}

/// Stage `pkg_root` inside `staging_dir` while resolving `manifest.toml` and
/// `build/packages` from `deps_root` (falling back to `pkg_root`), then run
/// `gleam export package-interface --out interface.json`.
pub fn extract_package_interface_with_deps(
  pkg_root: String,
  deps_root: String,
  staging_dir: String,
) -> Result(PackageInterface, String) {
  use _ <- result.try(prepare_staging_dir(staging_dir))
  use _ <- result.try(stage_toml_and_deps(pkg_root, deps_root, staging_dir))
  use _ <- result.try(stage_sources(pkg_root, staging_dir))

  let res =
    cmd.run(
      command: "gleam",
      args: ["export", "package-interface", "--out", "interface.json"],
      cwd: staging_dir,
    )

  case res.exit_code {
    0 -> {
      let json_path = filepath.join(staging_dir, "interface.json")
      use json_str <- result.try(
        simplifile.read(json_path)
        |> result.map_error(fn(err) {
          "Failed to read staged interface.json: "
          <> simplifile.describe_error(err)
        }),
      )
      interface.decode_package_interface(json_str)
    }
    code ->
      Error(
        "gleam export package-interface failed (exit "
        <> int.to_string(code)
        <> "):\n"
        <> res.output,
      )
  }
}

fn prepare_staging_dir(staging_dir: String) -> Result(Nil, String) {
  let staging_packages =
    staging_dir
    |> filepath.join("build")
    |> filepath.join("packages")
  let _ = simplifile.delete(file_or_dir_at: staging_packages)

  let staging_src = filepath.join(staging_dir, "src")
  let _ = simplifile.delete(file_or_dir_at: staging_src)
  let _ =
    simplifile.delete_file(at: filepath.join(staging_dir, "interface.json"))
  let _ =
    simplifile.delete_file(at: filepath.join(staging_dir, "manifest.toml"))

  simplifile.create_directory_all(staging_src)
  |> result.map_error(fn(err) {
    "Failed to create staging directory "
    <> staging_src
    <> ": "
    <> simplifile.describe_error(err)
  })
}

fn stage_toml_and_deps(
  pkg_root: String,
  deps_root: String,
  staging_dir: String,
) -> Result(Nil, String) {
  let src_gleam_toml = filepath.join(pkg_root, "gleam.toml")
  let dest_gleam_toml = filepath.join(staging_dir, "gleam.toml")
  use toml_content <- result.try(
    simplifile.read(src_gleam_toml)
    |> result.map_error(fn(err) {
      "Failed to read "
      <> src_gleam_toml
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  let rewritten_toml = override_gleam_toml_internal_modules(toml_content)
  use _ <- result.try(
    simplifile.write(to: dest_gleam_toml, contents: rewritten_toml)
    |> result.map_error(fn(err) {
      "Failed to write "
      <> dest_gleam_toml
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )

  let src_manifest =
    first_existing_path(
      deps_root,
      pkg_root,
      "manifest.toml",
      simplifile.is_file,
    )
  let dest_manifest = filepath.join(staging_dir, "manifest.toml")
  use _ <- result.try(case src_manifest {
    Some(path) ->
      simplifile.copy_file(at: path, to: dest_manifest)
      |> result.map_error(fn(err) {
        "Failed to copy manifest.toml: " <> simplifile.describe_error(err)
      })
    None -> Ok(Nil)
  })

  let packages_rel = filepath.join("build", "packages")
  case
    first_existing_path(
      deps_root,
      pkg_root,
      packages_rel,
      simplifile.is_directory,
    )
  {
    Some(src_packages) -> {
      let staging_build = filepath.join(staging_dir, "build")
      use _ <- result.try(
        simplifile.create_directory_all(staging_build)
        |> result.map_error(fn(err) {
          "Failed to create staging build dir: "
          <> simplifile.describe_error(err)
        }),
      )
      let dest_packages = filepath.join(staging_build, "packages")
      let _ = simplifile.delete(file_or_dir_at: dest_packages)
      copy_packages_isolated(src_packages, dest_packages)
    }
    None -> Ok(Nil)
  }
}

fn copy_packages_isolated(
  src_packages: String,
  dest_packages: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(dest_packages)
    |> result.map_error(fn(err) {
      "Failed to create staged packages dir: " <> simplifile.describe_error(err)
    }),
  )
  use entries <- result.try(
    simplifile.read_directory(at: src_packages)
    |> result.map_error(fn(err) {
      "Failed to read build/packages: " <> simplifile.describe_error(err)
    }),
  )
  list.try_each(entries, fn(entry) {
    let src_entry = filepath.join(src_packages, entry)
    let dest_entry = filepath.join(dest_packages, entry)
    let resolved =
      simplifile.resolve(path: src_entry) |> result.unwrap(src_entry)
    case simplifile.is_directory(resolved) {
      Ok(True) ->
        simplifile.copy_directory(at: resolved, to: dest_entry)
        |> result.map_error(fn(err) {
          "Failed to copy package dir "
          <> entry
          <> ": "
          <> simplifile.describe_error(err)
        })
      Ok(False) ->
        case simplifile.is_file(resolved) {
          Ok(True) ->
            simplifile.copy_file(at: resolved, to: dest_entry)
            |> result.map_error(fn(err) {
              "Failed to copy package file "
              <> entry
              <> ": "
              <> simplifile.describe_error(err)
            })
          _ -> Ok(Nil)
        }
      Error(err) ->
        Error(
          "Failed to stat package entry "
          <> entry
          <> ": "
          <> simplifile.describe_error(err),
        )
    }
  })
}

fn first_existing_path(
  primary_root: String,
  fallback_root: String,
  rel_path: String,
  check: fn(String) -> Result(Bool, simplifile.FileError),
) -> Option(String) {
  let primary = filepath.join(primary_root, rel_path)
  case check(primary) {
    Ok(True) -> Some(primary)
    _ -> {
      let fallback = filepath.join(fallback_root, rel_path)
      case fallback != primary, check(fallback) {
        True, Ok(True) -> Some(fallback)
        _, _ -> None
      }
    }
  }
}

fn stage_sources(
  project_root: String,
  staging_dir: String,
) -> Result(Nil, String) {
  let src_root = filepath.join(project_root, "src")
  let dest_root = filepath.join(staging_dir, "src")
  use rel_files <- result.try(walk_relative_files(src_root, ""))
  list.try_each(rel_files, fn(rel_path) {
    let src_path = filepath.join(src_root, rel_path)
    let dest_path = filepath.join(dest_root, rel_path)
    use _ <- result.try(
      simplifile.create_directory_all(filepath.directory_name(dest_path))
      |> result.map_error(fn(err) {
        "Failed to create dir for "
        <> dest_path
        <> ": "
        <> simplifile.describe_error(err)
      }),
    )
    case filepath.extension(rel_path) {
      Ok("gleam") -> {
        use content <- result.try(
          simplifile.read(src_path)
          |> result.map_error(fn(err) {
            "Failed to read "
            <> src_path
            <> ": "
            <> simplifile.describe_error(err)
          }),
        )
        let promoted = promote_private_to_pub(content)
        simplifile.write(to: dest_path, contents: promoted)
        |> result.map_error(fn(err) {
          "Failed to write "
          <> dest_path
          <> ": "
          <> simplifile.describe_error(err)
        })
      }
      _ ->
        simplifile.copy_file(at: src_path, to: dest_path)
        |> result.map_error(fn(err) {
          "Failed to copy "
          <> src_path
          <> ": "
          <> simplifile.describe_error(err)
        })
    }
  })
}

fn walk_relative_files(
  base_dir: String,
  rel_prefix: String,
) -> Result(List(String), String) {
  let current_dir = case rel_prefix {
    "" -> base_dir
    _ -> filepath.join(base_dir, rel_prefix)
  }
  use entries <- result.try(
    simplifile.read_directory(at: current_dir)
    |> result.map_error(fn(err) {
      "Failed to read directory "
      <> current_dir
      <> ": "
      <> simplifile.describe_error(err)
    }),
  )
  list.try_fold(entries, [], fn(acc, entry) {
    let rel_path = case rel_prefix {
      "" -> entry
      _ -> filepath.join(rel_prefix, entry)
    }
    let full_path = filepath.join(base_dir, rel_path)
    case simplifile.is_directory(full_path) {
      Ok(True) -> {
        use nested <- result.try(walk_relative_files(base_dir, rel_path))
        Ok(list.append(acc, nested))
      }
      Ok(False) -> Ok([rel_path, ..acc])
      Error(err) ->
        Error(
          "Failed to stat "
          <> full_path
          <> ": "
          <> simplifile.describe_error(err),
        )
    }
  })
}

fn collect_pub_edits(
  tokens: List(#(Token, glexer.Position)),
  brace_depth: Int,
  seen_pub: Bool,
  edits: List(TextEdit),
) -> List(TextEdit) {
  case tokens {
    [] -> edits

    [#(token.LeftBrace, _), ..rest] ->
      collect_pub_edits(rest, brace_depth + 1, False, edits)

    [#(token.RightBrace, _), ..rest] ->
      collect_pub_edits(rest, int.max(0, brace_depth - 1), False, edits)

    [#(token.Space(_), _), ..rest]
    | [#(token.CommentNormal(_), _), ..rest]
    | [#(token.CommentDoc(_), _), ..rest]
    | [#(token.CommentModule(_), _), ..rest] ->
      collect_pub_edits(rest, brace_depth, seen_pub, edits)

    [#(token.At, pos), ..after_at] if brace_depth == 0 ->
      case skip_trivia(after_at) {
        [#(token.Name("internal") as tok, name_pos), ..rest] -> {
          let edit =
            TextEdit(
              start: pos.byte_offset,
              end: token_end(tok, name_pos),
              replacement: "",
            )
          collect_pub_edits(rest, brace_depth, False, [edit, ..edits])
        }
        _ -> collect_pub_edits(after_at, brace_depth, False, edits)
      }

    [#(token.Pub, _), ..rest] if brace_depth == 0 ->
      collect_pub_edits(rest, brace_depth, True, edits)

    [#(token.Fn, pos), ..rest] if brace_depth == 0 -> {
      let edits = case seen_pub, skip_trivia(rest) {
        False, [#(token.Name(_), _), ..] -> [
          TextEdit(
            start: pos.byte_offset,
            end: pos.byte_offset,
            replacement: "pub ",
          ),
          ..edits
        ]
        _, _ -> edits
      }
      collect_pub_edits(rest, brace_depth, False, edits)
    }

    [#(token.Type, pos), ..rest] if brace_depth == 0 -> {
      let edits = case seen_pub, skip_trivia(rest) {
        False, [#(token.UpperName(_), _), ..] -> [
          TextEdit(
            start: pos.byte_offset,
            end: pos.byte_offset,
            replacement: "pub ",
          ),
          ..edits
        ]
        _, _ -> edits
      }
      collect_pub_edits(rest, brace_depth, False, edits)
    }

    [#(token.Opaque, pos), ..rest] if brace_depth == 0 ->
      case skip_trivia(rest) {
        [#(token.Type, type_pos), ..after_type] ->
          case skip_trivia(after_type) {
            [#(token.UpperName(_), _), ..] -> {
              let edit = case seen_pub {
                True ->
                  TextEdit(
                    start: pos.byte_offset,
                    end: type_pos.byte_offset,
                    replacement: "",
                  )
                False ->
                  TextEdit(
                    start: pos.byte_offset,
                    end: type_pos.byte_offset + 4,
                    replacement: "pub type",
                  )
              }
              collect_pub_edits(after_type, brace_depth, False, [edit, ..edits])
            }
            _ -> collect_pub_edits(after_type, brace_depth, False, edits)
          }
        other -> collect_pub_edits(other, brace_depth, False, edits)
      }

    [#(token.Const, pos), ..rest] if brace_depth == 0 -> {
      let edits = case seen_pub, skip_trivia(rest) {
        False, [#(token.Name(_), _), ..] -> [
          TextEdit(
            start: pos.byte_offset,
            end: pos.byte_offset,
            replacement: "pub ",
          ),
          ..edits
        ]
        _, _ -> edits
      }
      collect_pub_edits(rest, brace_depth, False, edits)
    }

    [_, ..rest] -> collect_pub_edits(rest, brace_depth, False, edits)
  }
}

fn filter_root_internal_modules(
  lines: List(String),
  in_root: Bool,
  skipping_array: Bool,
  bracket_balance: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case skipping_array {
        True -> {
          let next_balance = bracket_balance + count_brackets(line)
          case next_balance <= 0 {
            True -> filter_root_internal_modules(rest, in_root, False, 0, acc)
            False ->
              filter_root_internal_modules(
                rest,
                in_root,
                True,
                next_balance,
                acc,
              )
          }
        }
        False ->
          case in_root {
            False ->
              filter_root_internal_modules(rest, False, False, 0, [line, ..acc])
            True ->
              case string.starts_with(trimmed, "[") {
                True ->
                  filter_root_internal_modules(rest, False, False, 0, [
                    line,
                    ..acc
                  ])
                False ->
                  case is_internal_modules_assignment(trimmed) {
                    True -> {
                      let balance = count_brackets(line)
                      case balance > 0 {
                        True ->
                          filter_root_internal_modules(
                            rest,
                            True,
                            True,
                            balance,
                            acc,
                          )
                        False ->
                          filter_root_internal_modules(
                            rest,
                            True,
                            False,
                            0,
                            acc,
                          )
                      }
                    }
                    False ->
                      filter_root_internal_modules(rest, True, False, 0, [
                        line,
                        ..acc
                      ])
                  }
              }
          }
      }
    }
  }
}

fn is_internal_modules_assignment(trimmed: String) -> Bool {
  case string.split_once(trimmed, "=") {
    Ok(#(lhs, _)) -> string.trim(lhs) == "internal_modules"
    Error(_) -> False
  }
}

fn count_brackets(line: String) -> Int {
  line
  |> string.to_graphemes
  |> list.fold(0, fn(acc, ch) {
    case ch {
      "[" -> acc + 1
      "]" -> acc - 1
      _ -> acc
    }
  })
}
