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

/// Read an OS environment variable as UTF-8, returning `Error(Nil)` if unset.
pub fn get_env(name: String) -> Result(String, Nil) {
  ffi_get_env(name)
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
