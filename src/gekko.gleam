import argv
import emit/pkg_config
import emit/wit_bridge
import filepath
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import moonbit/bindgen
import project/cmd
import project/workspace
import simplifile
import wit/gleam_gen
import wit/parser as wit_parser

pub const version = "0.1.0"

/// Outcome returned by `build_project` / `build_project_in_dir`.
pub type BuildOutput {
  BuiltArtifact(path: String, warnings: String)
  BuiltLibrary(project_name: String, warnings: String)
}

pub type CliAction {
  CheckAction(root: String, out: Option(String), target: Option(String))
  BuildAction(root: String, out: Option(String), target: String)
  TestAction(root: String, out: Option(String), target: Option(String))
  RunAction(root: String, out: Option(String), target: Option(String))
  WitGenAction(root: String, wit_dir: Option(String), world: Option(String))
  WitCheckAction(
    root: String,
    wit_dir: Option(String),
    world: Option(String),
    out: Option(String),
  )
  WitBuildAction(
    root: String,
    wit_dir: Option(String),
    world: Option(String),
    out: Option(String),
    output: Option(String),
  )
  MoonbitBindAction(
    root: String,
    package: String,
    module: Option(String),
    out: Option(String),
  )
  HelpAction
  VersionAction
}

type BindFlags {
  BindFlags(
    root: String,
    package: Option(String),
    module: Option(String),
    out: Option(String),
  )
}

type WitFlags {
  WitFlags(
    root: String,
    wit_dir: Option(String),
    world: Option(String),
    out: Option(String),
    output: Option(String),
  )
}

pub fn main() -> Nil {
  let args = argv.load().arguments
  case parse_args(args) {
    Error(msg) -> {
      io.println_error("Error: " <> msg)
      print_usage()
      halt(1)
    }
    Ok(HelpAction) -> print_usage()
    Ok(VersionAction) -> io.println("gekko " <> version)
    Ok(CheckAction(root:, out:, target:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "check", None, target, True)
    }
    Ok(BuildAction(root:, out:, target:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_build(root, out, target)
    }
    Ok(TestAction(root:, out:, target:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(root, out, "test", None, target, True)
    }
    Ok(RunAction(root:, out:, target:)) -> {
      require_tools_or_halt(["gleam", "moon"])
      run_moon_workflow(
        root,
        out,
        "run",
        Some(pkg_config.module_to_pkg_dir),
        target,
        False,
      )
    }
    Ok(WitGenAction(root:, wit_dir:, world:)) ->
      run_wit_gen(root, wit_dir, world)
    Ok(WitCheckAction(root:, wit_dir:, world:, out:)) -> {
      require_tools_or_halt(["gleam", "moon", "wit-bindgen"])
      run_wit_check(root, wit_dir, world, out)
    }
    Ok(WitBuildAction(root:, wit_dir:, world:, out:, output:)) -> {
      require_tools_or_halt(["gleam", "moon", "wit-bindgen", "wasm-tools"])
      run_wit_build(root, wit_dir, world, out, output)
    }
    Ok(MoonbitBindAction(root:, package:, module:, out:)) -> {
      require_tools_or_halt(["moon"])
      run_moonbit_bind(root, package, module, out)
    }
  }
}

fn require_tools_or_halt(tools: List(String)) -> Nil {
  case cmd.require_tools(tools) {
    Ok(Nil) -> Nil
    Error(msg) -> {
      io.println_error("gekko error: " <> msg)
      halt(1)
    }
  }
}

fn run_moon_workflow(
  root: String,
  out: Option(String),
  moon_subcmd: String,
  pkg_arg_fn: Option(fn(String) -> String),
  target: Option(String),
  include_tests: Bool,
) -> Nil {
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  case workspace.transpile_project_with_tests(root, out_dir, include_tests) {
    Error(err) -> {
      io.println_error("gekko error: " <> err)
      halt(1)
    }
    Ok(summary) -> {
      let base_args = case pkg_arg_fn {
        Some(to_pkg) -> [moon_subcmd, to_pkg(summary.project_name)]
        None -> [moon_subcmd]
      }
      let moon_args = case target {
        Some(t) -> list.append(base_args, ["--target", t])
        None -> base_args
      }
      let res = cmd.run(command: "moon", args: moon_args, cwd: summary.out_dir)
      case res.output {
        "" -> Nil
        text -> io.print(text)
      }
      case res.exit_code {
        0 -> Nil
        code -> halt(code)
      }
    }
  }
}

fn run_build(root: String, out: Option(String), target: String) -> Nil {
  case build_project(root, out, target) {
    Error(err) -> {
      io.println_error("gekko error: " <> err)
      halt(1)
    }
    Ok(BuiltArtifact(path:, warnings:)) -> {
      case warnings {
        "" -> Nil
        text -> io.println(text)
      }
      io.println("Built " <> target <> ": " <> path)
    }
    Ok(BuiltLibrary(project_name:, warnings:)) -> {
      case warnings {
        "" -> Nil
        text -> io.println(text)
      }
      io.println(
        "Built library "
        <> project_name
        <> " ("
        <> target
        <> ") — no pub fn main() entrypoint; no standalone output file emitted.",
      )
    }
  }
}

/// Transpile and build a Gleam project, copying the built artifact to the
/// current working directory (or the path specified by `out`).
pub fn build_project(
  root: String,
  out: Option(String),
  target: String,
) -> Result(BuildOutput, String) {
  build_project_in_dir(root, out, target, ".")
}

/// Transpile and build a Gleam project, resolving relative `out` paths against
/// `output_base_dir` (defaults to `.` in CLI execution).
pub fn build_project_in_dir(
  root: String,
  out: Option(String),
  target: String,
  output_base_dir: String,
) -> Result(BuildOutput, String) {
  let work_dir = filepath.join(root, "build/moonbit")
  use summary <- result.try(workspace.transpile_project_with_tests(
    root,
    work_dir,
    False,
  ))

  let res =
    cmd.run(
      command: "moon",
      args: ["build", "--target", target],
      cwd: summary.out_dir,
    )
  use _ <- result.try(case res.exit_code {
    0 -> Ok(Nil)
    _ -> Error(res.output)
  })

  let warnings = filter_moon_build_warnings(res.output)
  let root_pkg_dir = pkg_config.module_to_pkg_dir(summary.project_name)
  let expected_pkg = summary.project_name <> "/" <> root_pkg_dir
  let parsed_artifacts = parse_moon_build_artifacts(res.output)

  let src_artifact =
    find_built_artifact(
      summary.out_dir,
      root_pkg_dir,
      expected_pkg,
      target,
      parsed_artifacts,
    )

  let apply_base = fn(rel_or_abs) {
    case output_base_dir != "." && !filepath.is_absolute(rel_or_abs) {
      True -> filepath.join(output_base_dir, rel_or_abs)
      False -> rel_or_abs
    }
  }

  case src_artifact {
    Some(src_path) -> {
      let default_name = filepath.base_name(src_path)
      use dest_display <- result.try(
        resolve_build_output_path(out, default_name, fn(p) {
          simplifile.is_directory(apply_base(p)) == Ok(True)
        }),
      )
      let dest_fs = apply_base(dest_display)
      use _ <- result.try(copy_built_artifact(src_path, dest_fs))
      Ok(BuiltArtifact(path: dest_display, warnings:))
    }
    None ->
      case out {
        None -> Ok(BuiltLibrary(project_name: summary.project_name, warnings:))
        Some(user_out) ->
          Error(
            "Cannot write '--out "
            <> user_out
            <> "': project '"
            <> summary.project_name
            <> "' has no 'pub fn main()' entrypoint in src/"
            <> summary.project_name
            <> ".gleam, so no standalone "
            <> target
            <> " artifact was produced.",
          )
      }
  }
}

fn find_built_artifact(
  work_dir: String,
  root_pkg_dir: String,
  expected_pkg: String,
  target: String,
  parsed_artifacts: List(#(String, String, String)),
) -> Option(String) {
  let resolve_in_work = fn(p) {
    case filepath.is_absolute(p) {
      True -> p
      False -> filepath.join(work_dir, p)
    }
  }
  let from_expected =
    list.find_map(parsed_artifacts, fn(entry) {
      let #(pkg, backend, path) = entry
      case pkg == expected_pkg && backend == target {
        True -> Ok(resolve_in_work(path))
        False -> Error(Nil)
      }
    })
  case from_expected {
    Ok(p) -> Some(p)
    Error(_) -> {
      let candidates = case target {
        "wasm" | "wasm-gc" -> [root_pkg_dir <> ".wasm"]
        "js" -> [root_pkg_dir <> ".js"]
        "native" -> [root_pkg_dir <> ".exe", root_pkg_dir]
        _ -> []
      }
      let base_dir =
        work_dir
        |> filepath.join("_build")
        |> filepath.join(target)
        |> filepath.join("debug")
        |> filepath.join("build")
        |> filepath.join(root_pkg_dir)
      let from_fallback =
        list.find_map(candidates, fn(name) {
          let p = filepath.join(base_dir, name)
          case simplifile.is_file(p) {
            Ok(True) -> Ok(p)
            _ -> Error(Nil)
          }
        })
      case from_fallback {
        Ok(p) -> Some(p)
        Error(_) ->
          case list.filter(parsed_artifacts, fn(entry) { entry.1 == target }) {
            [#(_, _, path)] -> Some(resolve_in_work(path))
            _ -> None
          }
      }
    }
  }
}

fn copy_built_artifact(
  src_path: String,
  dest_path: String,
) -> Result(Nil, String) {
  let parent = filepath.directory_name(dest_path)
  use _ <- result.try(case parent {
    "" | "." -> Ok(Nil)
    _ ->
      simplifile.create_directory_all(parent)
      |> result.map_error(fn(err) {
        "Failed to create output directory '"
        <> parent
        <> "': "
        <> simplifile.describe_error(err)
      })
  })

  let same_target = case
    simplifile.resolve(src_path),
    simplifile.resolve(dest_path)
  {
    Ok(a), Ok(b) -> a == b
    _, _ -> False
  }

  case same_target {
    True -> Ok(Nil)
    False -> {
      case simplifile.is_file(dest_path) {
        Ok(True) -> {
          let _ = simplifile.delete_file(at: dest_path)
          Nil
        }
        _ -> Nil
      }
      use _ <- result.try(
        simplifile.copy_file(at: src_path, to: dest_path)
        |> result.map_error(fn(err) {
          "Failed to copy built artifact to '"
          <> dest_path
          <> "': "
          <> simplifile.describe_error(err)
        }),
      )
      case simplifile.file_info(src_path) {
        Ok(info) ->
          simplifile.set_permissions_octal(
            for_file_at: dest_path,
            to: simplifile.file_info_permissions_octal(info),
          )
          |> result.map_error(fn(err) {
            "Failed to set permissions on '"
            <> dest_path
            <> "': "
            <> simplifile.describe_error(err)
          })
        Error(_) -> Ok(Nil)
      }
    }
  }
}

/// Resolve the destination file path for `gekko build` given `--out` / `-o`,
/// the artifact's default filename, and a directory existence check.
pub fn resolve_build_output_path(
  out: Option(String),
  default_name: String,
  is_dir: fn(String) -> Bool,
) -> Result(String, String) {
  case out {
    None -> Ok(default_name)
    Some("") -> Error("Output path cannot be empty.")
    Some(raw) ->
      case string.ends_with(raw, "/") {
        True -> Ok(filepath.join(raw, default_name))
        False ->
          case is_dir(raw) {
            True ->
              Error(
                "Output path '"
                <> raw
                <> "' is an existing directory. Pass a file path or append '/' to place "
                <> default_name
                <> " inside it.",
              )
            False -> Ok(raw)
          }
      }
  }
}

/// Parse the `Artifacts:` section printed by `moon build` into
/// `#(package, target_backend, artifact_path)` tuples.
pub fn parse_moon_build_artifacts(
  output: String,
) -> List(#(String, String, String)) {
  output
  |> string.split("\n")
  |> parse_artifact_lines(False, [])
}

fn parse_artifact_lines(
  lines: List(String),
  in_artifacts: Bool,
  rev_acc: List(#(String, String, String)),
) -> List(#(String, String, String)) {
  case lines {
    [] -> list.reverse(rev_acc)
    [raw_line, ..rest] -> {
      let line = strip_cr(raw_line)
      case in_artifacts {
        False ->
          case string.trim(line) == "Artifacts:" {
            True -> parse_artifact_lines(rest, True, rev_acc)
            False -> parse_artifact_lines(rest, False, rev_acc)
          }
        True ->
          case
            { string.starts_with(line, " ") || string.starts_with(line, "\t") }
            && string.trim(line) != ""
          {
            True ->
              case parse_single_artifact_line(line) {
                Ok(entry) ->
                  parse_artifact_lines(rest, True, [entry, ..rev_acc])
                Error(_) -> parse_artifact_lines(rest, True, rev_acc)
              }
            False ->
              case string.trim(line) == "Artifacts:" {
                True -> parse_artifact_lines(rest, True, rev_acc)
                False -> parse_artifact_lines(rest, False, rev_acc)
              }
          }
      }
    }
  }
}

fn parse_single_artifact_line(
  line: String,
) -> Result(#(String, String, String), Nil) {
  use #(pkg, rest1) <- result.try(take_token_and_rest(line))
  use #(backend, rest2) <- result.try(take_token_and_rest(rest1))
  let path = string.trim_end(rest2)
  case pkg != "" && backend != "" && path != "" {
    True -> Ok(#(pkg, backend, path))
    False -> Error(Nil)
  }
}

fn take_token_and_rest(input: String) -> Result(#(String, String), Nil) {
  let trimmed = skip_leading_ws(string.to_graphemes(input))
  case trimmed {
    [] -> Error(Nil)
    _ -> {
      let #(tok_chars, after_tok) = take_non_ws(trimmed, [])
      let rest_chars = skip_leading_ws(after_tok)
      Ok(#(string.concat(tok_chars), string.concat(rest_chars)))
    }
  }
}

fn skip_leading_ws(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\t", ..rest] -> skip_leading_ws(rest)
    _ -> chars
  }
}

fn take_non_ws(
  chars: List(String),
  rev_acc: List(String),
) -> #(List(String), List(String)) {
  case chars {
    [] -> #(list.reverse(rev_acc), [])
    [" ", ..] | ["\t", ..] -> #(list.reverse(rev_acc), chars)
    [ch, ..rest] -> take_non_ws(rest, [ch, ..rev_acc])
  }
}

fn filter_moon_build_warnings(output: String) -> String {
  let kept =
    output
    |> string.split("\n")
    |> filter_warning_lines(False, [])
    |> trim_blank_lines
  string.join(kept, "\n")
}

fn filter_warning_lines(
  lines: List(String),
  in_artifacts: Bool,
  rev_acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(rev_acc)
    [raw_line, ..rest] -> {
      let line = strip_cr(raw_line)
      case in_artifacts {
        True ->
          case
            { string.starts_with(line, " ") || string.starts_with(line, "\t") }
            && string.trim(line) != ""
          {
            True -> filter_warning_lines(rest, True, rev_acc)
            False -> filter_warning_lines([raw_line, ..rest], False, rev_acc)
          }
        False -> {
          let trimmed = string.trim(line)
          case trimmed == "Artifacts:" {
            True -> filter_warning_lines(rest, True, rev_acc)
            False ->
              case string.starts_with(trimmed, "Finished. moon:") {
                True -> filter_warning_lines(rest, False, rev_acc)
                False -> filter_warning_lines(rest, False, [line, ..rev_acc])
              }
          }
        }
      }
    }
  }
}

fn trim_blank_lines(lines: List(String)) -> List(String) {
  lines
  |> drop_leading_blanks
  |> list.reverse
  |> drop_leading_blanks
  |> list.reverse
}

fn drop_leading_blanks(lines: List(String)) -> List(String) {
  case lines {
    [first, ..rest] ->
      case string.trim(first) == "" {
        True -> drop_leading_blanks(rest)
        False -> lines
      }
    [] -> []
  }
}

fn strip_cr(line: String) -> String {
  case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}

fn run_wit_gen(
  root: String,
  wit_dir_opt: Option(String),
  world: Option(String),
) -> Nil {
  let wit_dir = option.unwrap(wit_dir_opt, filepath.join(root, "wit"))
  let res = {
    use resolved <- result.try(wit_parser.load_wit_dir(wit_dir, world))
    gleam_gen.generate_project_bindings(resolved, root)
  }
  case res {
    Error(err) -> {
      io.println_error("gekko wit gen error: " <> err)
      halt(1)
    }
    Ok(report) -> {
      list.each(report.written_files, fn(p) { io.println("Generated " <> p) })
      list.each(report.skipped_existing_stubs, fn(p) {
        io.println("Kept existing stub " <> p)
      })
    }
  }
}

fn run_wit_check(
  root: String,
  wit_dir_opt: Option(String),
  world: Option(String),
  out: Option(String),
) -> Nil {
  let wit_dir = option.unwrap(wit_dir_opt, filepath.join(root, "wit"))
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  let res = {
    use summary <- result.try(wit_bridge.bridge_wit_workspace(
      root,
      out_dir,
      wit_dir,
      world,
    ))
    wit_bridge.check_wit_workspace(summary)
  }
  case res {
    Error(err) -> {
      io.println_error("gekko wit check error: " <> err)
      halt(1)
    }
    Ok(output) ->
      case output {
        "" -> Nil
        text -> io.print(text)
      }
  }
}

fn run_wit_build(
  root: String,
  wit_dir_opt: Option(String),
  world: Option(String),
  out: Option(String),
  output_opt: Option(String),
) -> Nil {
  let wit_dir = option.unwrap(wit_dir_opt, filepath.join(root, "wit"))
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  let res = {
    use summary <- result.try(wit_bridge.bridge_wit_workspace(
      root,
      out_dir,
      wit_dir,
      world,
    ))
    let output_wasm =
      option.unwrap(
        output_opt,
        filepath.join(root, "dist/" <> summary.world_name <> ".wasm"),
      )
    wit_bridge.bundle_component(summary, world, output_wasm)
  }
  case res {
    Error(err) -> {
      io.println_error("gekko wit build error: " <> err)
      halt(1)
    }
    Ok(out_wasm) -> io.println("Built Wasm component: " <> out_wasm)
  }
}

fn run_moonbit_bind(
  root: String,
  package: String,
  module: Option(String),
  out: Option(String),
) -> Nil {
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
  case bindgen.bind_package(root, package, module, out_dir) {
    Error(err) -> {
      io.println_error("gekko moonbit bind error: " <> err)
      halt(1)
    }
    Ok(res) -> {
      io.println(
        "Generated Gleam module: src/" <> res.gleam_module_path <> ".gleam",
      )
      case res.adapter_pkg_dir {
        Some(dir) -> io.println("Generated MoonBit adapter: moonbit/" <> dir)
        None -> Nil
      }
      list.each(res.skipped_items, fn(s) {
        io.println_error("Warning (skipped " <> s.0 <> "): " <> s.1)
      })
    }
  }
}

pub fn parse_args(args: List(String)) -> Result(CliAction, String) {
  let args = expand_eq_flags(args)
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(HelpAction)
    False ->
      case args {
        [] | ["help", ..] -> Ok(HelpAction)
        ["--version"] | ["-V"] | ["version"] -> Ok(VersionAction)
        ["check", ..rest] -> {
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(CheckAction(root:, out:, target:))
        }
        ["build", ..rest] -> {
          use #(root, out, target) <- result.try(parse_build_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(BuildAction(root:, out:, target: option.unwrap(target, "wasm-gc")))
        }
        ["test", ..rest] -> {
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(TestAction(root:, out:, target:))
        }
        ["run", ..rest] -> {
          use #(root, out, target) <- result.try(parse_flags(
            rest,
            ".",
            None,
            None,
          ))
          Ok(RunAction(root:, out:, target:))
        }
        ["wit", "gen", ..rest] -> {
          use f <- result.try(parse_wit_flags(rest, default_wit_flags()))
          Ok(WitGenAction(root: f.root, wit_dir: f.wit_dir, world: f.world))
        }
        ["wit", "check", ..rest] -> {
          use f <- result.try(parse_wit_flags(rest, default_wit_flags()))
          Ok(WitCheckAction(
            root: f.root,
            wit_dir: f.wit_dir,
            world: f.world,
            out: f.out,
          ))
        }
        ["wit", "build", ..rest] -> {
          use f <- result.try(parse_wit_flags(rest, default_wit_flags()))
          Ok(WitBuildAction(
            root: f.root,
            wit_dir: f.wit_dir,
            world: f.world,
            out: f.out,
            output: f.output,
          ))
        }
        ["wit", ..] -> Error("Expected `gekko wit <gen|check|build> [flags]`")
        ["moonbit", "bind", ..rest] -> {
          use f <- result.try(parse_bind_flags(
            rest,
            BindFlags(root: ".", package: None, module: None, out: None),
          ))
          case f.package {
            Some(pkg) ->
              Ok(MoonbitBindAction(
                root: f.root,
                package: pkg,
                module: f.module,
                out: f.out,
              ))
            None -> Error("Expected `<pkg>` after `gekko moonbit bind`")
          }
        }
        ["moonbit", ..] -> Error("Expected `gekko moonbit bind <pkg> [flags]`")
        [unknown, ..] -> Error("Unknown subcommand: " <> unknown)
      }
  }
}

fn parse_bind_flags(
  args: List(String),
  acc: BindFlags,
) -> Result(BindFlags, String) {
  case args {
    [] -> Ok(acc)
    ["--root", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, root: val))
    ["--module", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, module: Some(val)))
    ["--out", val, ..rest] ->
      parse_bind_flags(rest, BindFlags(..acc, out: Some(val)))
    [val, ..rest] ->
      case acc.package {
        None -> parse_bind_flags(rest, BindFlags(..acc, package: Some(val)))
        Some(_) -> Error("Unknown or unexpected argument: " <> val)
      }
  }
}

fn default_wit_flags() -> WitFlags {
  WitFlags(root: ".", wit_dir: None, world: None, out: None, output: None)
}

fn parse_wit_flags(
  args: List(String),
  acc: WitFlags,
) -> Result(WitFlags, String) {
  case args {
    [] -> Ok(acc)
    ["--root", val, ..rest] -> parse_wit_flags(rest, WitFlags(..acc, root: val))
    ["--wit", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, wit_dir: Some(val)))
    ["--world", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, world: Some(val)))
    ["--out", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, out: Some(val)))
    ["--output", val, ..rest] | ["-o", val, ..rest] ->
      parse_wit_flags(rest, WitFlags(..acc, output: Some(val)))
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn expand_eq_flags(args: List(String)) -> List(String) {
  list.flat_map(args, fn(arg) {
    case string.split_once(arg, "=") {
      Ok(#(flag, val)) ->
        case flag {
          "--root"
          | "--out"
          | "-o"
          | "--output"
          | "--target"
          | "--wit"
          | "--world"
          | "--module" -> [flag, val]
          _ -> [arg]
        }
      Error(_) -> [arg]
    }
  })
}

fn parse_build_flags(
  args: List(String),
  root: String,
  out: Option(String),
  target: Option(String),
) -> Result(#(String, Option(String), Option(String)), String) {
  case args {
    [] -> Ok(#(root, out, target))
    ["--root", val, ..rest] -> parse_build_flags(rest, val, out, target)
    ["--out", val, ..rest] | ["-o", val, ..rest] ->
      parse_build_flags(rest, root, Some(val), target)
    ["--target", val, ..rest] ->
      case val {
        "wasm" | "wasm-gc" | "js" | "native" ->
          parse_build_flags(rest, root, out, Some(val))
        _ ->
          Error(
            "Invalid --target '"
            <> val
            <> "'. Expected wasm, wasm-gc, js, or native.",
          )
      }
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn parse_flags(
  args: List(String),
  root: String,
  out: Option(String),
  target: Option(String),
) -> Result(#(String, Option(String), Option(String)), String) {
  case args {
    [] -> Ok(#(root, out, target))
    ["--root", val, ..rest] -> parse_flags(rest, val, out, target)
    ["--out", val, ..rest] -> parse_flags(rest, root, Some(val), target)
    ["--target", val, ..rest] ->
      case val {
        "wasm" | "wasm-gc" | "js" | "native" ->
          parse_flags(rest, root, out, Some(val))
        _ ->
          Error(
            "Invalid --target '"
            <> val
            <> "'. Expected wasm, wasm-gc, js, or native.",
          )
      }
    [flag, ..] -> Error("Unknown or incomplete flag: " <> flag)
  }
}

fn print_usage() -> Nil {
  let lines = [
    "gekko " <> version <> " - Gleam-to-MoonBit & Wasm Component transpiler",
    "",
    "Usage:",
    "  gekko check     [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko build     [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <file> | -o <file>]",
    "  gekko test      [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko run       [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko wit gen      [--root <dir>] [--wit <dir>] [--world <name>]",
    "  gekko wit check    [--root <dir>] [--wit <dir>] [--world <name>] [--out <dir>]",
    "  gekko wit build    [--root <dir>] [--wit <dir>] [--world <name>] [--out <dir>] [--output <file.wasm>]",
    "  gekko moonbit bind <pkg> [--root <dir>] [--module <gleam_mod>] [--out <dir>]",
    "  gekko --version | -V",
    "  gekko --help    | -h",
    "",
    "Notes:",
    "  --root defaults to the current working directory (.) for all commands.",
    "  gekko build writes the compiled artifact into the current directory by",
    "  default (or to --out / -o), keeping intermediate files in <root>/build/moonbit.",
  ]
  list.each(lines, io.println)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
