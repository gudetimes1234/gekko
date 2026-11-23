import filepath
import gleam/list
import gleam/string
import project/cmd
import simplifile

pub fn assert_no_unqualified_prelude_calls(source: String) {
  let forbidden = [
    " println(",
    " eprintln(",
    " abort(",
    " ignore(",
    "{ println(",
    "{ eprintln(",
    "{ abort(",
    "{ ignore(",
  ]
  string.split(source, "\n")
  |> list.each(fn(line) {
    let trimmed = string.trim(line)
    let is_decl =
      string.starts_with(trimmed, "pub fn ")
      || string.starts_with(trimmed, "pub fn[")
      || string.starts_with(trimmed, "fn ")
      || string.starts_with(trimmed, "fn[")
    let scan_line = case is_decl {
      True ->
        case string.split_once(line, "{") {
          Ok(#(_, body_part)) -> "{" <> body_part
          Error(_) -> ""
        }
      False -> line
    }
    list.each(forbidden, fn(pat) {
      assert !string.contains(scan_line, pat)
      assert !string.starts_with(trimmed, string.trim_start(pat))
    })
  })
}

pub fn assert_all_moonbit_targets_ok(
  out_dir: String,
  expected_summary: String,
) {
  let targets = ["wasm", "wasm-gc", "js", "native"]
  list.each(targets, fn(target) {
    let chk =
      cmd.run(
        command: "moon",
        args: ["check", "--deny-warn", "--target", target],
        cwd: out_dir,
      )
    assert chk.exit_code == 0

    let run =
      cmd.run(command: "moon", args: ["test", "--target", target], cwd: out_dir)
    assert run.exit_code == 0
    assert string.contains(run.output, expected_summary)
  })
}

pub fn assert_golden_snapshots(
  out_dir: String,
  expected_dir: String,
  rel_paths: List(String),
) -> Nil {
  let update = cmd.get_env("GEKKO_UPDATE_GOLDEN") == Ok("1")
  list.each(rel_paths, fn(rel_path) {
    let actual_path = filepath.join(out_dir, rel_path)
    let expected_path = filepath.join(expected_dir, rel_path)
    let assert Ok(actual) = simplifile.read(from: actual_path)
    case update {
      True -> {
        let parent = filepath.directory_name(expected_path)
        assert simplifile.create_directory_all(parent) == Ok(Nil)
        assert simplifile.write(to: expected_path, contents: actual) == Ok(Nil)
      }
      False -> {
        let assert Ok(expected) = simplifile.read(from: expected_path)
        assert actual == expected
      }
    }
  })
}
