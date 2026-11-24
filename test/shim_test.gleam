import filepath
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/cmd
import project/ffi_config
import project/loader
import project/prepass.{
  ExternalType, PackageCall, Patched, PreferErlang, PreferJavascript, WasmImport,
}
import project/shim_cli
import project/workspace
import simplifile

pub fn parse_overlay_sections_gekko_and_gleam_toml_test() {
  let gekko_toml =
    "
[shim]
target = \"simplifile\"
version = \">= 2.0.0 and < 3.0.0\"

[type_overrides.\"simplifile:simplifile.FileInfo\"]
package = \"simplifile_ffi\"
type = \"FileInfo\"

[overrides.\"simplifile:simplifile.read_bits\"]
package = \"simplifile_ffi\"
function = \"read_bits\"

[overrides.\"simplifile:simplifile.raw_op\"]
wasm_module = \"wasi\"
import_name = \"op\"

[patch.\"simplifile:simplifile\"]
file = \"patches/simplifile.mbt\"
imports = [\"gleam/string_tree as st\"]
types = [\"FileInfo\"]
functions = [\"parse_info\"]

[target_branch.\"simplifile:simplifile\"]
prefer = \"javascript\"
"

  let assert Ok(Some(shim)) = ffi_config.parse_shim_gekko_toml(gekko_toml)
  assert shim.target == "simplifile"
  assert shim.version == Some(">= 2.0.0 and < 3.0.0")

  let assert Ok(tys) = ffi_config.parse_type_overrides_gekko_toml(gekko_toml)
  assert dict.get(tys, "simplifile:simplifile.FileInfo")
    == Ok(ExternalType(package: "simplifile_ffi", type_name: "FileInfo"))

  let assert Ok(ovrs) = ffi_config.parse_gekko_toml(gekko_toml)
  assert dict.get(ovrs, "simplifile:simplifile.read_bits")
    == Ok(PackageCall(package: "simplifile_ffi", function: "read_bits"))
  assert dict.get(ovrs, "simplifile:simplifile.raw_op")
    == Ok(WasmImport(wasm_module: "wasi", import_name: "op"))

  let assert Ok(patches) = ffi_config.parse_module_patch_gekko_toml(gekko_toml)
  let assert Ok(patch) = dict.get(patches, "simplifile:simplifile")
  assert patch.files
    == [
      ffi_config.ModulePatchFile(
        source_path: "patches/simplifile.mbt",
        dest_filename: "simplifile.mbt",
        source_pkg: "",
      ),
    ]
  assert patch.imports
    == [
      ffi_config.ModulePatchImport(
        package: "gleam/string_tree",
        alias: Some("st"),
      ),
    ]
  assert patch.types == ["FileInfo"]
  assert patch.functions == ["parse_info"]

  let assert Ok(branches) =
    ffi_config.parse_target_branch_gekko_toml(gekko_toml)
  assert dict.get(branches, "simplifile:simplifile") == Ok(PreferJavascript)

  // Equivalent [tools.gekko.*] sections in gleam.toml
  let gleam_toml =
    "
name = \"my_shim\"
version = \"0.1.0\"

[tools.gekko.shim]
target = \"simplifile\"
version = \"~> 2.1\"

[tools.gekko.type_overrides.\"simplifile:simplifile.FileInfo\"]
package = \"simplifile_ffi\"
type = \"FileInfo\"

[tools.gekko.overrides.\"simplifile:simplifile.read_bits\"]
package = \"simplifile_ffi\"
function = \"read_bits\"

[tools.gekko.patch.\"simplifile:simplifile\"]
files = [\"patches/a.mbt\"]
imports = [\"simplifile_ffi @sffi\"]
functions = [\"parse_info\"]

[tools.gekko.target_branch.\"simplifile:simplifile\"]
prefer = \"erlang\"
"
  let assert Ok(Some(g_shim)) = ffi_config.parse_shim_gleam_toml(gleam_toml)
  assert g_shim.target == "simplifile"
  assert g_shim.version == Some("~> 2.1")
  let assert Ok(g_tys) = ffi_config.parse_type_overrides_gleam_toml(gleam_toml)
  assert dict.get(g_tys, "simplifile:simplifile.FileInfo")
    == Ok(ExternalType(package: "simplifile_ffi", type_name: "FileInfo"))
  let assert Ok(g_ovrs) = ffi_config.parse_gleam_toml_overrides(gleam_toml)
  assert dict.get(g_ovrs, "simplifile:simplifile.read_bits")
    == Ok(PackageCall(package: "simplifile_ffi", function: "read_bits"))
  let assert Ok(g_patches) =
    ffi_config.parse_module_patch_gleam_toml(gleam_toml)
  let assert Ok(g_patch) = dict.get(g_patches, "simplifile:simplifile")
  assert g_patch.imports
    == [
      ffi_config.ModulePatchImport(
        package: "simplifile_ffi",
        alias: Some("sffi"),
      ),
    ]
  assert g_patch.functions == ["parse_info"]
  let assert Ok(g_br) = ffi_config.parse_target_branch_gleam_toml(gleam_toml)
  assert dict.get(g_br, "simplifile:simplifile") == Ok(PreferErlang)

  // Invalid patch (both file & files) & branch checks
  let bad_patch = "[patch.\"m\"]\nfile = \"a.mbt\"\nfiles = [\"b.mbt\"]\n"
  let assert Error(_) = ffi_config.parse_module_patch_gekko_toml(bad_patch)

  let bad_branch = "[target_branch.\"m\"]\nprefer = \"python\"\n"
  let assert Error(_) = ffi_config.parse_target_branch_gekko_toml(bad_branch)
}

pub fn semver_constraint_matching_test() {
  assert ffi_config.version_matches_constraint("2.1.3", ">= 2.0.0 and < 3.0.0")
    == Ok(True)
  assert ffi_config.version_matches_constraint("3.0.0", ">= 2.0.0 and < 3.0.0")
    == Ok(False)
  assert ffi_config.version_matches_constraint("1.4.2", "~> 1.2") == Ok(True)
  assert ffi_config.version_matches_constraint("2.0.0", "~> 1.2") == Ok(False)
  assert ffi_config.version_matches_constraint("1.2.5", "~> 1.2.3") == Ok(True)
  assert ffi_config.version_matches_constraint("1.3.0", "~> 1.2.3") == Ok(False)
  assert ffi_config.version_matches_constraint("0.2.3", "^0.2.1") == Ok(True)
  assert ffi_config.version_matches_constraint("0.3.0", "^0.2.1") == Ok(False)
  assert ffi_config.version_matches_constraint("1.0.0-alpha.1", ">= 1.0.0")
    == Ok(False)
  assert ffi_config.version_matches_constraint("1.0.0", ">= 1.0.0-alpha.1")
    == Ok(True)
  assert ffi_config.version_matches_constraint("1.2.0", "== 1.2.0") == Ok(True)
  assert ffi_config.version_matches_constraint("1.2.1", "!= 1.2.0") == Ok(True)
  let assert Error(_) = ffi_config.version_matches_constraint("1.0.0", "bogus")
}

pub fn overlay_merging_conflict_and_root_resolution_test() {
  let empty_ov = fn(pkg) {
    ffi_config.PackageOverlay(
      source_pkg: pkg,
      shim: None,
      overrides: dict.new(),
      type_overrides: dict.new(),
      module_patches: dict.new(),
      target_branches: dict.new(),
    )
  }

  let shim_a =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_a"),
      overrides: dict.from_list([
        #("lib:lib.foo", PackageCall("ffi_a", "foo")),
      ]),
    )
  let shim_b =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_b"),
      overrides: dict.from_list([
        #("lib:lib.foo", PackageCall("ffi_b", "foo")),
      ]),
    )
  let shim_c =
    ffi_config.PackageOverlay(
      ..empty_ov("shim_c"),
      overrides: dict.from_list([
        #("lib:lib.bar", PackageCall("ffi_c", "bar")),
      ]),
    )

  // Non-conflicting shims merge cleanly
  let assert Ok(ok_merged) =
    ffi_config.merge_overlays([shim_a, shim_c], empty_ov("app"))
  assert dict.get(ok_merged.overrides, "lib:lib.foo")
    == Ok(PackageCall("ffi_a", "foo"))
  assert dict.get(ok_merged.overrides, "lib:lib.bar")
    == Ok(PackageCall("ffi_c", "bar"))

  // Conflicting shims fail naming both packages
  let assert Error(conflict_err) =
    ffi_config.merge_overlays([shim_a, shim_b], empty_ov("app"))
  assert string.contains(conflict_err, "shim_a")
  assert string.contains(conflict_err, "shim_b")
  assert string.contains(conflict_err, "lib:lib.foo")

  // Root override resolves the conflict
  let root_resolves =
    ffi_config.PackageOverlay(
      ..empty_ov("app"),
      overrides: dict.from_list([#("lib:lib.foo", Patched)]),
    )
  let assert Ok(resolved) =
    ffi_config.merge_overlays([shim_a, shim_b], root_resolves)
  assert dict.get(resolved.overrides, "lib:lib.foo") == Ok(Patched)
}

pub fn multi_error_unmapped_externals_and_shim_cli_test() {
  let root = "/tmp/gekko_shim_cli_proj"
  let dep_dir = filepath.join(root, "deps/raw_lib")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(dep_dir, "src"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(dep_dir, "gleam.toml"),
      contents: "name = \"raw_lib\"\nversion = \"1.2.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(dep_dir, "src/raw_lib.gleam"),
      contents: "pub type OpaqueHandle\n\n@external(erlang, \"raw\", \"one\")\npub fn first(x: Int) -> OpaqueHandle\n\n@external(erlang, \"raw\", \"two\")\npub fn second(h: OpaqueHandle) -> String\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nraw_lib = { path = \"deps/raw_lib\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "import raw_lib\npub fn main() { raw_lib.second(raw_lib.first(1)) }\n",
    )
    == Ok(Nil)

  // Loader must report BOTH unmapped functions in one error
  let assert Error(err) = loader.load_dependencies(root, dict.new())
  assert string.contains(err, "raw_lib:raw_lib.first")
  assert string.contains(err, "raw_lib:raw_lib.second")

  // `gekko shim inspect raw_lib` must list both functions and the opaque type
  let assert Ok(report) = shim_cli.inspect_package(root, "raw_lib")
  assert string.contains(report, "raw_lib.OpaqueHandle")
  assert string.contains(report, "raw_lib.first")
  assert string.contains(report, "raw_lib.second")
  assert string.contains(report, "[patch.\"raw_lib:raw_lib\"]")

  // `gekko shim init raw_lib` scaffolds a valid co-located [patch] companion shim
  let shim_out = filepath.join(root, "gekko_raw_lib")
  let assert Ok(_) = shim_cli.init_shim(root, "raw_lib", Some(shim_out))
  let assert Ok(shim_toml) =
    simplifile.read(filepath.join(shim_out, "gekko.toml"))
  assert string.contains(shim_toml, "target = \"raw_lib\"")
  assert string.contains(shim_toml, ">= 1.0.0 and < 2.0.0")
  assert string.contains(shim_toml, "[patch.\"raw_lib:raw_lib\"]")
  assert string.contains(shim_toml, "file = \"patches/raw_lib.mbt\"")
  let assert Ok(stub_mbt) =
    simplifile.read(filepath.join(shim_out, "patches/raw_lib.mbt"))
  assert string.contains(stub_mbt, "pub type OpaqueHandle")
  assert string.contains(stub_mbt, "pub fn first(")
  assert string.contains(stub_mbt, "pub fn second(")

  let _ = simplifile.delete(file_or_dir_at: root)
}

pub fn companion_shim_end_to_end_moon_test() {
  let root = "/tmp/gekko_shim_e2e_proj"
  let upstream_dir = filepath.join(root, "deps/upstream_lib")
  let shim_dir = filepath.join(root, "deps/gekko_upstream_lib")
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(upstream_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(shim_dir, "src"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(shim_dir, "patches"))
    == Ok(Nil)

  // 1. Completely unmodified upstream library (zero @external(moonbit) pragmas)
  assert simplifile.write(
      to: filepath.join(upstream_dir, "gleam.toml"),
      contents: "name = \"upstream_lib\"\nversion = \"1.2.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(upstream_dir, "src/upstream_helper.gleam"),
      contents: "pub fn helper_tag() -> String { \"ok\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(upstream_dir, "src/upstream_lib.gleam"),
      contents: "import upstream_helper\n\npub type Handle\n\npub type LibError {\n  Empty\n  BadCode(Int)\n}\n\n@external(erlang, \"erl_mod\", \"make_handle\")\npub fn make_handle(n: Int) -> Result(Handle, LibError)\n\n@external(erlang, \"erl_mod\", \"read_handle\")\npub fn read_handle(h: Handle) -> Int\n\n@target(erlang)\n@external(erlang, \"erl_mod\", \"platform_double\")\npub fn platform_double(x: Int) -> Int\n\n@target(javascript)\npub fn platform_double(x: Int) -> Int {\n  let _ = upstream_helper.helper_tag()\n  x * 2\n}\n",
    )
    == Ok(Nil)

  // 2. Companion shim package using unified co-located [patch] (no separate FFI pkg!)
  assert simplifile.write(
      to: filepath.join(shim_dir, "gleam.toml"),
      contents: "name = \"gekko_upstream_lib\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "gekko.toml"),
      contents: "
[shim]
target = \"upstream_lib\"
version = \">= 1.0.0 and < 2.0.0\"

[patch.\"upstream_lib:upstream_lib\"]
file = \"patches/upstream_lib.mbt\"
imports = [\"upstream_helper\"]
types = [\"Handle\"]
functions = [\"make_handle\", \"read_handle\"]

[target_branch.\"upstream_lib:upstream_lib\"]
prefer = \"javascript\"
",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(shim_dir, "patches/upstream_lib.mbt"),
      contents: "///|\npub struct Handle {\n  value : Int64\n}\n\n///|\npub fn make_handle(n : Int64) -> Result[Handle, LibError] {\n  if n == 0L {\n    Err(Empty)\n  } else if n < 0L {\n    Err(BadCode(n))\n  } else {\n    let _ = @upstream_helper.helper_tag()\n    Ok({ value: n })\n  }\n}\n\n///|\npub fn read_handle(h : Handle) -> Int64 {\n  h.value\n}\n",
    )
    == Ok(Nil)

  // 3. Root app depending on BOTH unmodified upstream_lib and gekko_upstream_lib
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nupstream_lib = { path = \"deps/upstream_lib\" }\ngekko_upstream_lib = { path = \"deps/gekko_upstream_lib\" }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "import upstream_lib\npub fn compute(x: Int) -> Result(Int, upstream_lib.LibError) {\n  case upstream_lib.make_handle(x) {\n    Ok(h) -> Ok(upstream_lib.read_handle(h) + upstream_lib.platform_double(x))\n    Error(e) -> Error(e)\n  }\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/app_suite.gleam"),
      contents: "import app\nimport upstream_lib\n\npub fn shim_e2e_test() {\n  assert app.compute(21) == Ok(63)\n  assert app.compute(0) == Error(upstream_lib.Empty)\n  assert app.compute(-5) == Error(upstream_lib.BadCode(-5))\n}\n",
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.warnings == []

  let chk =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert chk.exit_code == 0

  let test_run =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_run.exit_code == 0

  // 4. Verify stale patch file cleanup + version mismatch & stale override warnings
  assert simplifile.write(
      to: filepath.join(shim_dir, "gekko.toml"),
      contents: "
[shim]
target = \"upstream_lib\"
version = \">= 2.0.0\"

[patch.\"upstream_lib:upstream_lib\"]
file = \"patches/upstream_lib.mbt\"
types = [\"Handle\"]
functions = [\"make_handle\", \"read_handle\"]

[overrides.\"upstream_lib:upstream_lib.nonexistent_fn\"]
package = \"upstream_ffi\"
function = \"nope\"

[target_branch.\"upstream_lib:upstream_lib\"]
prefer = \"javascript\"
",
    )
    == Ok(Nil)
  let assert Ok(summary2) = workspace.transpile_project(root, out_dir)
  assert list.any(summary2.warnings, fn(w) {
    string.contains(w, "expects 'upstream_lib' (>= 2.0.0)")
  })
  assert list.any(summary2.warnings, fn(w) {
    string.contains(w, "upstream_lib:upstream_lib.nonexistent_fn")
  })

  // Remove [patch] and verify stale __gekko_patch_*.mbt is deleted
  assert simplifile.write(
      to: filepath.join(shim_dir, "gekko.toml"),
      contents: "
[shim]
target = \"upstream_lib\"
version = \">= 2.0.0\"

[type_overrides.\"upstream_lib:upstream_lib.Handle\"]
package = \"gprelude\"
type = \"Dynamic\"

[overrides.\"upstream_lib:upstream_lib.make_handle\"]
package = \"gprelude\"
function = \"ignore\"

[overrides.\"upstream_lib:upstream_lib.read_handle\"]
package = \"gprelude\"
function = \"ignore\"

[target_branch.\"upstream_lib:upstream_lib\"]
prefer = \"javascript\"
",
    )
    == Ok(Nil)
  let _ = workspace.transpile_project(root, out_dir)
  let stale_patch =
    filepath.join(out_dir, "upstream_lib/__gekko_patch_1_upstream_lib.mbt")
  assert simplifile.is_file(stale_patch) != Ok(True)

  let _ = simplifile.delete(file_or_dir_at: root)
}

pub fn local_closure_trait_bound_propagation_test() {
  let root = "/tmp/gekko_local_closure_bounds_proj"
  let out_dir = filepath.join(root, "build/moonbit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"closure_bounds\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/closure_bounds.gleam"),
      contents: "fn apply_all(items: List(k), init: acc, f: fn(acc, k) -> acc) -> acc {\n  case items {\n    [] -> init\n    [x, ..xs] -> apply_all(xs, f(init, x), f)\n  }\n}\n\npub fn count_equal(items: List(k), target: k) -> Int {\n  let step = fn(acc, item) {\n    case item == target {\n      True -> acc + 1\n      False -> acc\n    }\n  }\n  apply_all(items, 0, step)\n}\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/closure_bounds_suite.gleam"),
      contents: "import closure_bounds\npub fn count_equal_test() {\n  assert closure_bounds.count_equal([1, 2, 1, 3, 1], 1) == 3\n}\n",
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)
  let chk =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert chk.exit_code == 0
  let tst =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert tst.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: root)
}
