import gleam/list
import gleam/string

/// Result of executing an external OS command.
pub type CommandResult {
  CommandResult(exit_code: Int, output: String)
}

@external(erlang, "gekko_ffi", "run_command")
fn ffi_run_command(
  command: String,
  args: List(String),
  cwd: String,
) -> #(Int, String)

@external(erlang, "gekko_ffi", "get_env")
fn ffi_get_env(name: String) -> Result(String, Nil)

@external(erlang, "gekko_ffi", "find_executable")
fn ffi_find_executable(command: String) -> Result(String, Nil)

/// Read an OS environment variable as UTF-8, returning `Error(Nil)` if unset.
pub fn get_env(name: String) -> Result(String, Nil) {
  ffi_get_env(name)
}

/// Locate an executable on `PATH` (or at an explicit path), returning its resolved path.
pub fn find_executable(name: String) -> Result(String, Nil) {
  ffi_find_executable(name)
}

/// Verify that all required external tools are available on `PATH`.
pub fn require_tools(tools: List(String)) -> Result(Nil, String) {
  require_tools_with(tools, find_executable)
}

/// Testable version of `require_tools` accepting a custom executable lookup function.
pub fn require_tools_with(
  tools: List(String),
  finder: fn(String) -> Result(String, Nil),
) -> Result(Nil, String) {
  let missing =
    list.filter(tools, fn(tool) {
      case finder(tool) {
        Ok(_) -> False
        Error(_) -> True
      }
    })
  case missing {
    [] -> Ok(Nil)
    _ ->
      Error(
        "Missing required tool(s) on PATH: "
        <> string.join(missing, ", ")
        <> ". Please install them and ensure they are on your PATH.",
      )
  }
}

/// Run an external executable with arguments in `cwd` (or current directory if `""`).
pub fn run(
  command command: String,
  args args: List(String),
  cwd cwd: String,
) -> CommandResult {
  let #(exit_code, output) = ffi_run_command(command, args, cwd)
  CommandResult(exit_code:, output:)
}
