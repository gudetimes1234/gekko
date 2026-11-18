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

/// Run an external executable with arguments in `cwd` (or current directory if `""`).
pub fn run(
  command command: String,
  args args: List(String),
  cwd cwd: String,
) -> CommandResult {
  let #(exit_code, output) = ffi_run_command(command, args, cwd)
  CommandResult(exit_code:, output:)
}
