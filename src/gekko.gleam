import argv
import emit/pkg_config
import emit/wit_bridge
import filepath
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import project/cmd
import project/workspace
import wit/gleam_gen
import wit/parser as wit_parser

type CliAction {
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
  HelpAction
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
    Ok(WitGenAction(root:, wit_dir:, world:)) ->
      run_wit_gen(root, wit_dir, world)
    Ok(WitCheckAction(root:, wit_dir:, world:, out:)) ->
      run_wit_check(root, wit_dir, world, out)
    Ok(WitBuildAction(root:, wit_dir:, world:, out:, output:)) ->
      run_wit_build(root, wit_dir, world, out, output)
  }
}

fn run_moon_workflow(
  root: String,
  out: Option(String),
  moon_subcmd: String,
  pkg_arg_fn: Option(fn(String) -> String),
  target: Option(String),
) -> Nil {
  let out_dir = option.unwrap(out, filepath.join(root, "build/moonbit"))
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
    [unknown, ..] -> Error("Unknown subcommand: " <> unknown)
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
    "gekko - Gleam-to-MoonBit & Wasm Component transpiler",
    "",
    "Usage:",
    "  gekko check     [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko build     [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko test      [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko run       [--target <wasm-gc|wasm|js|native>] [--root <dir>] [--out <dir>]",
    "  gekko wit gen   [--root <dir>] [--wit <dir>] [--world <name>]",
    "  gekko wit check [--root <dir>] [--wit <dir>] [--world <name>] [--out <dir>]",
    "  gekko wit build [--root <dir>] [--wit <dir>] [--world <name>] [--out <dir>] [--output <file.wasm>]",
  ]
  list.each(lines, io.println)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
