import argv
import emit/pkg_config
import filepath
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import project/cmd
import project/workspace

type CliAction {
  CheckAction(root: String, out: Option(String), target: Option(String))
  BuildAction(root: String, out: Option(String), target: String)
  TestAction(root: String, out: Option(String), target: Option(String))
  RunAction(root: String, out: Option(String), target: Option(String))
  HelpAction
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
    Ok(CheckAction(root:, out:, target:)) ->
      run_moon_workflow(root, out, "check", None, target)
    Ok(BuildAction(root:, out:, target:)) ->
      run_moon_workflow(root, out, "build", None, Some(target))
    Ok(TestAction(root:, out:, target:)) ->
      run_moon_workflow(root, out, "test", None, target)
    Ok(RunAction(root:, out:, target:)) ->
      run_moon_workflow(
        root,
        out,
        "run",
        Some(pkg_config.module_to_pkg_dir),
        target,
      )
  }
}

fn run_moon_workflow(
  root: String,
  out: Option(String),
  moon_subcmd: String,
  pkg_arg_fn: Option(fn(String) -> String),
  target: Option(String),
) -> Nil {
  let out_dir = case out {
    Some(custom_out) -> custom_out
    None -> filepath.join(root, "build/moonbit")
  }
  case workspace.transpile_project(root, out_dir) {
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

fn parse_args(args: List(String)) -> Result(CliAction, String) {
  case args {
    [] | ["--help"] | ["-h"] | ["help"] -> Ok(HelpAction)
    ["check", ..rest] -> {
      use #(root, out, target) <- result.try(parse_flags(rest, ".", None, None))
      Ok(CheckAction(root:, out:, target:))
    }
    ["build", ..rest] -> {
      use #(root, out, target) <- result.try(parse_flags(rest, ".", None, None))
      Ok(BuildAction(root:, out:, target: option.unwrap(target, "wasm-gc")))
    }
    ["test", ..rest] -> {
      use #(root, out, target) <- result.try(parse_flags(rest, ".", None, None))
      Ok(TestAction(root:, out:, target:))
    }
    ["run", ..rest] -> {
      use #(root, out, target) <- result.try(parse_flags(rest, ".", None, None))
      Ok(RunAction(root:, out:, target:))
    }
    [unknown, ..] -> Error("Unknown subcommand: " <> unknown)
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
    "gekko - Gleam-to-MoonBit transpiler",
    "",
    "Usage:",
    "  gekko check [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko build [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko test  [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko run   [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
  ]
  list.each(lines, io.println)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
