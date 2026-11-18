import argv
import filepath
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import project/cmd
import project/workspace

type CliAction {
  CheckAction(root: String, out: String, target: Option(String))
  BuildAction(root: String, out: String, target: String)
  TestAction(root: String, out: String, target: Option(String))
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
      run_moon_workflow(root, out, "check", target)
    Ok(BuildAction(root:, out:, target:)) ->
      run_moon_workflow(root, out, "build", Some(target))
    Ok(TestAction(root:, out:, target:)) ->
      run_moon_workflow(root, out, "test", target)
  }
}

fn run_moon_workflow(
  root: String,
  out: String,
  moon_subcmd: String,
  target: Option(String),
) -> Nil {
  let out_dir = case filepath.is_absolute(out) {
    True -> out
    False -> filepath.join(root, out)
  }
  case workspace.transpile_project(root, out_dir) {
    Error(err) -> {
      io.println_error("gekko error: " <> err)
      halt(1)
    }
    Ok(summary) -> {
      let moon_args = case target {
        Some(t) -> [moon_subcmd, "--target", t]
        None -> [moon_subcmd]
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
      use #(root, out, target) <- result.try(parse_flags(
        rest,
        ".",
        "build/moonbit",
        None,
      ))
      Ok(CheckAction(root:, out:, target:))
    }
    ["build", ..rest] -> {
      use #(root, out, target) <- result.try(parse_flags(
        rest,
        ".",
        "build/moonbit",
        None,
      ))
      Ok(BuildAction(root:, out:, target: option.unwrap(target, "wasm-gc")))
    }
    ["test", ..rest] -> {
      use #(root, out, target) <- result.try(parse_flags(
        rest,
        ".",
        "build/moonbit",
        None,
      ))
      Ok(TestAction(root:, out:, target:))
    }
    [unknown, ..] -> Error("Unknown subcommand: " <> unknown)
  }
}

fn parse_flags(
  args: List(String),
  root: String,
  out: String,
  target: Option(String),
) -> Result(#(String, String, Option(String)), String) {
  case args {
    [] -> Ok(#(root, out, target))
    ["--root", val, ..rest] -> parse_flags(rest, val, out, target)
    ["--out", val, ..rest] -> parse_flags(rest, root, val, target)
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
  ]
  list.each(lines, io.println)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
