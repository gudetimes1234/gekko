import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import index/symbol_table
import project/ffi_config
import project/interface
import project/prepass
import project/staging
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// -----------------------------------------------------------------------------
// 1. Pre-pass tests
// -----------------------------------------------------------------------------

pub fn prepass_doc_pragma_and_raw_attribute_test() {
  let src =
    "/// Reads a file from MoonBit WASI FS.\n"
    <> "/// @external(moonbit, \"my_org/wit_fs\", \"read_file\")\n"
    <> "pub fn read_file(path: String) -> Result(String, Nil) {\n"
    <> "  Error(Nil)\n"
    <> "}\n"
    <> "\n"
    <> "@external(moonbit, \"my_org/math\", \"fast_sqrt\")\n"
    <> "pub fn fast_sqrt(x: Float) -> Float\n"
    <> "\n"
    <> "@external(moonbit, \"wasm:env\", \"host_add\")\n"
    <> "pub fn host_add(a: Int, b: Int) -> Int\n"

  let assert Ok(#(ast_mod, res)) = prepass.parse_module("app/fs", src)

  // Raw lines preserved 1:1
  assert list.length(string.split(res.cleaned_source, "\n"))
    == list.length(string.split(src, "\n"))

  assert list.length(ast_mod.functions) == 3

  assert res.ffi_entries
    == [
      prepass.FfiEntry(
        module: "app/fs",
        function_name: "read_file",
        kind: prepass.PackageCall("my_org/wit_fs", "read_file"),
        source: prepass.DocPragma,
        line: 2,
      ),
      prepass.FfiEntry(
        module: "app/fs",
        function_name: "fast_sqrt",
        kind: prepass.PackageCall("my_org/math", "fast_sqrt"),
        source: prepass.RawAttribute,
        line: 7,
      ),
      prepass.FfiEntry(
        module: "app/fs",
        function_name: "host_add",
        kind: prepass.WasmImport("env", "host_add"),
        source: prepass.RawAttribute,
        line: 10,
      ),
    ]

  // Bodyless external functions received injected panic bodies while read_file kept its body
  assert string.contains(
    res.cleaned_source,
    "pub fn fast_sqrt(x: Float) -> Float { panic as \"external\" }",
  )
  assert string.contains(
    res.cleaned_source,
    "pub fn host_add(a: Int, b: Int) -> Int { panic as \"external\" }",
  )
  assert !string.contains(res.cleaned_source, "Error(Nil) { panic")
}

pub fn prepass_multiline_attribute_preserves_line_numbers_test() {
  let src =
    "pub fn before() -> Int { 1 }\n"
    <> "\n"
    <> "@external(\n"
    <> "  moonbit,\n"
    <> "  \"pkg/multi\",\n"
    <> "  \"do_work\",\n"
    <> ")\n"
    <> "pub fn do_work(\n"
    <> "  x: Int,\n"
    <> ") -> Result(\n"
    <> "  Int,\n"
    <> "  String,\n"
    <> ")\n"
    <> "\n"
    <> "pub fn after() -> Int { 2 }\n"

  let assert Ok(#(ast_mod, res)) = prepass.parse_module("multi", src)
  assert list.length(ast_mod.functions) == 3

  let src_lines = string.split(src, "\n")
  let clean_lines = string.split(res.cleaned_source, "\n")
  assert list.length(clean_lines) == list.length(src_lines)

  // Line 15 ("pub fn after() -> Int { 2 }") remains at line 15 (index 14)
  assert list.drop(clean_lines, 14) == ["pub fn after() -> Int { 2 }", ""]
  assert res.ffi_entries
    == [
      prepass.FfiEntry(
        module: "multi",
        function_name: "do_work",
        kind: prepass.PackageCall("pkg/multi", "do_work"),
        source: prepass.RawAttribute,
        line: 3,
      ),
    ]
}

// -----------------------------------------------------------------------------
// 2. FFI config parser tests
// -----------------------------------------------------------------------------

pub fn ffi_config_parse_gekko_and_gleam_toml_test() {
  let gekko_toml =
    "[overrides.\"simplifile.read\"]\n"
    <> "package = \"wasi/filesystem\"\n"
    <> "function = \"read_to_string\"\n"
    <> "\n"
    <> "[overrides.\"host.raw_log\"]\n"
    <> "wasm_module = \"wasi:cli/stdout\"\n"
    <> "import_name = \"write_bytes\"\n"

  let assert Ok(parsed_gekko) = ffi_config.parse_gekko_toml(gekko_toml)
  assert dict.get(parsed_gekko, "simplifile.read")
    == Ok(prepass.PackageCall("wasi/filesystem", "read_to_string"))
  assert dict.get(parsed_gekko, "host.raw_log")
    == Ok(prepass.WasmImport("wasi:cli/stdout", "write_bytes"))

  let gleam_toml =
    "name = \"demo\"\n"
    <> "version = \"0.1.0\"\n"
    <> "\n"
    <> "[tools.gekko.overrides.\"gleam/io.println\"]\n"
    <> "package = \"gekko/io\"\n"
    <> "function = \"println\"\n"

  let assert Ok(parsed_gleam) =
    ffi_config.parse_gleam_toml_overrides(gleam_toml)
  assert dict.get(parsed_gleam, "gleam/io.println")
    == Ok(prepass.PackageCall("gekko/io", "println"))
}

pub fn ffi_config_load_project_overrides_precedence_test() {
  let fixture_dir = "build/test_fixtures/ffi_cfg_fixture"
  let _ = simplifile.delete(file_or_dir_at: fixture_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(fixture_dir)

  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_dir, "gleam.toml"),
      contents: "name = \"cfg\"\nversion = \"0.1.0\"\n\n[tools.gekko.overrides.\"a.fn1\"]\npackage = \"old/pkg\"\nfunction = \"old_fn\"\n\n[tools.gekko.overrides.\"a.fn2\"]\npackage = \"keep/pkg\"\nfunction = \"keep_fn\"\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_dir, "gekko.toml"),
      contents: "[overrides.\"a.fn1\"]\npackage = \"new/pkg\"\nfunction = \"new_fn\"\n",
    )

  let assert Ok(merged) = ffi_config.load_project_overrides(fixture_dir)
  assert dict.get(merged, "a.fn1")
    == Ok(prepass.PackageCall("new/pkg", "new_fn"))
  assert dict.get(merged, "a.fn2")
    == Ok(prepass.PackageCall("keep/pkg", "keep_fn"))

  let _ = simplifile.delete(file_or_dir_at: fixture_dir)
  Nil
}

// -----------------------------------------------------------------------------
// 3. Package-interface decoder tests
// -----------------------------------------------------------------------------

pub fn interface_decode_json_test() {
  let json_sample =
    "{\n"
    <> "  \"name\": \"sample\",\n"
    <> "  \"version\": \"0.1.0\",\n"
    <> "  \"modules\": {\n"
    <> "    \"sample/core\": {\n"
    <> "      \"type-aliases\": {\n"
    <> "        \"Pair\": {\n"
    <> "          \"parameters\": 1,\n"
    <> "          \"alias\": {\n"
    <> "            \"kind\": \"tuple\",\n"
    <> "            \"elements\": [\n"
    <> "              { \"kind\": \"variable\", \"id\": 0 },\n"
    <> "              { \"kind\": \"named\", \"name\": \"Int\", \"package\": \"\", \"module\": \"gleam\", \"parameters\": [] }\n"
    <> "            ]\n"
    <> "          }\n"
    <> "        }\n"
    <> "      },\n"
    <> "      \"types\": {\n"
    <> "        \"Box\": {\n"
    <> "          \"parameters\": 1,\n"
    <> "          \"constructors\": [\n"
    <> "            {\n"
    <> "              \"name\": \"Box\",\n"
    <> "              \"parameters\": [\n"
    <> "                { \"label\": \"item\", \"type\": { \"kind\": \"variable\", \"id\": 0 } }\n"
    <> "              ]\n"
    <> "            }\n"
    <> "          ]\n"
    <> "        }\n"
    <> "      },\n"
    <> "      \"constants\": {\n"
    <> "        \"version_num\": {\n"
    <> "          \"implementations\": { \"gleam\": true, \"uses-erlang-externals\": false, \"uses-javascript-externals\": false },\n"
    <> "          \"type\": { \"kind\": \"named\", \"name\": \"Int\", \"package\": \"\", \"module\": \"gleam\", \"parameters\": [] }\n"
    <> "        }\n"
    <> "      },\n"
    <> "      \"functions\": {\n"
    <> "        \"map_pair\": {\n"
    <> "          \"implementations\": { \"gleam\": true, \"uses-erlang-externals\": false, \"uses-javascript-externals\": false },\n"
    <> "          \"parameters\": [\n"
    <> "            { \"label\": \"value\", \"type\": { \"kind\": \"variable\", \"id\": 0 } },\n"
    <> "            { \"label\": null, \"type\": { \"kind\": \"fn\", \"parameters\": [{ \"kind\": \"variable\", \"id\": 0 }], \"return\": { \"kind\": \"variable\", \"id\": 1 } } }\n"
    <> "          ],\n"
    <> "          \"return\": { \"kind\": \"tuple\", \"elements\": [{ \"kind\": \"variable\", \"id\": 1 }] }\n"
    <> "        }\n"
    <> "      }\n"
    <> "    }\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(iface) = interface.decode_package_interface(json_sample)
  assert iface.name == "sample"
  let assert Ok(mod_iface) = dict.get(iface.modules, "sample/core")
  let assert Ok(fn_sig) = dict.get(mod_iface.functions, "map_pair")
  assert fn_sig.return == interface.TupleType([interface.VariableType(1)])
  assert fn_sig.parameters
    == [
      interface.ResolvedParam(Some("value"), interface.VariableType(0)),
      interface.ResolvedParam(
        None,
        interface.FnType([interface.VariableType(0)], interface.VariableType(1)),
      ),
    ]
}

// -----------------------------------------------------------------------------
// 4. Shadow `pub` staging & HM inference tests
// -----------------------------------------------------------------------------

pub fn staging_promote_private_to_pub_test() {
  let src =
    "import gleam/option.{type Option}\n"
    <> "\n"
    <> "type Secret {\n"
    <> "  Secret(code: Int)\n"
    <> "}\n"
    <> "\n"
    <> "pub opaque type Box(a) {\n"
    <> "  Box(inner: a)\n"
    <> "}\n"
    <> "\n"
    <> "opaque type LocalOpaque {\n"
    <> "  LocalOpaque(Int)\n"
    <> "}\n"
    <> "\n"
    <> "const magic = 42\n"
    <> "\n"
    <> "@internal\n"
    <> "pub fn hidden_pub(x) { x }\n"
    <> "\n"
    <> "fn private_helper(x, y) {\n"
    <> "  let f = fn(z) { z + 1 }\n"
    <> "  f(x) + y\n"
    <> "}\n"

  let promoted = staging.promote_private_to_pub(src)
  assert string.contains(promoted, "import gleam/option.{type Option}")
  assert string.contains(promoted, "pub type Secret")
  assert string.contains(promoted, "pub type Box(a)")
  assert string.contains(promoted, "pub type LocalOpaque")
  assert string.contains(promoted, "pub const magic = 42")
  assert !string.contains(promoted, "@internal")
  assert string.contains(promoted, "pub fn hidden_pub(x) { x }")
  assert string.contains(promoted, "pub fn private_helper(x, y)")
  assert string.contains(promoted, "let f = fn(z) { z + 1 }")
}

pub fn staging_end_to_end_shadow_pub_interface_test() {
  let fixture_root = "build/test_fixtures/staging_project"
  let staging_dir = "build/test_fixtures/staging_out"
  let _ = simplifile.delete(file_or_dir_at: fixture_root)
  let _ = simplifile.delete(file_or_dir_at: staging_dir)

  let assert Ok(Nil) =
    simplifile.create_directory_all(filepath.join(
      fixture_root,
      "src/staging_project/internal",
    ))

  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_root, "gleam.toml"),
      contents: "name = \"staging_project\"\nversion = \"0.1.0\"\ninternal_modules = [\"staging_project/internal/*\"]\n",
    )

  let main_src =
    "import staging_project/internal/helper\n"
    <> "\n"
    <> "type Secret {\n"
    <> "  Secret(code: Int)\n"
    <> "}\n"
    <> "\n"
    <> "pub opaque type Box(a) {\n"
    <> "  Box(inner: a)\n"
    <> "}\n"
    <> "\n"
    <> "@external(moonbit, \"mbt/math\", \"native_abs\")\n"
    <> "fn native_abs(x: Int) -> Int\n"
    <> "\n"
    <> "@internal\n"
    <> "pub fn add_and_wrap(a, b) {\n"
    <> "  let s = Secret(code: helper.bump(a + b))\n"
    <> "  #(s, Box(inner: True))\n"
    <> "}\n"

  let helper_src = "fn bump(n) {\n" <> "  n + 1\n" <> "}\n"

  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(fixture_root, "src/staging_project.gleam"),
      contents: main_src,
    )
  let assert Ok(Nil) =
    simplifile.write(
      to: filepath.join(
        fixture_root,
        "src/staging_project/internal/helper.gleam",
      ),
      contents: helper_src,
    )

  let assert Ok(iface) =
    staging.extract_project_interface(fixture_root, staging_dir)

  // Internal module was exposed and private fn `bump` got inferred Int -> Int
  let assert Ok(helper_iface) =
    dict.get(iface.modules, "staging_project/internal/helper")
  let assert Ok(bump_sig) = dict.get(helper_iface.functions, "bump")
  assert bump_sig.parameters
    == [
      interface.ResolvedParam(None, interface.NamedType("Int", "", "gleam", [])),
    ]
  assert bump_sig.return == interface.NamedType("Int", "", "gleam", [])

  // Main module: private `Secret`, opaque `Box`, bodyless `native_abs`, and `@internal` `add_and_wrap` all resolved!
  let assert Ok(main_iface) = dict.get(iface.modules, "staging_project")
  let assert Ok(secret_def) = dict.get(main_iface.types, "Secret")
  assert list.length(secret_def.constructors) == 1
  let assert Ok(box_def) = dict.get(main_iface.types, "Box")
  assert list.length(box_def.constructors) == 1
  let assert Ok(abs_sig) = dict.get(main_iface.functions, "native_abs")
  assert abs_sig.return == interface.NamedType("Int", "", "gleam", [])
  let assert Ok(add_wrap_sig) = dict.get(main_iface.functions, "add_and_wrap")
  assert add_wrap_sig.parameters
    == [
      interface.ResolvedParam(None, interface.NamedType("Int", "", "gleam", [])),
      interface.ResolvedParam(None, interface.NamedType("Int", "", "gleam", [])),
    ]
  assert add_wrap_sig.return
    == interface.TupleType([
      interface.NamedType("Secret", "staging_project", "staging_project", []),
      interface.NamedType("Box", "staging_project", "staging_project", [
        interface.NamedType("Bool", "", "gleam", []),
      ]),
    ])

  // Verify SymbolTable merges real Shadow-pub PackageInterface onto private AST functions
  let assert Ok(#(main_ast, main_pre)) =
    prepass.parse_module("staging_project", main_src)
  let table =
    symbol_table.index_project(
      "staging_project",
      [#("staging_project", main_ast, main_pre)],
      Some(iface),
      dict.new(),
    )
  let assert Ok(main_syms) = dict.get(table.modules, "staging_project")
  let assert Ok(native_abs_fn) = dict.get(main_syms.functions, "native_abs")
  assert native_abs_fn.ffi
    == Some(prepass.PackageCall("mbt/math", "native_abs"))
  assert native_abs_fn.return_type
    == Some(interface.NamedType("Int", "", "gleam", []))

  let _ = simplifile.delete(file_or_dir_at: fixture_root)
  let _ = simplifile.delete(file_or_dir_at: staging_dir)
  Nil
}

// -----------------------------------------------------------------------------
// 5. Global Symbol Table Indexer tests
// -----------------------------------------------------------------------------

pub fn symbol_table_multi_module_indexing_test() {
  let types_src =
    "pub type User {\n"
    <> "  Admin(id: Int, name: String, level: Int)\n"
    <> "  Member(id: Int, name: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Conflict {\n"
    <> "  Left(value: Int)\n"
    <> "  Right(value: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Point {\n"
    <> "  Point(x: Float, y: Float)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Tree {\n"
    <> "  Leaf(Int)\n"
    <> "  Node(left: Tree, right: Tree)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Handler {\n"
    <> "  Handler(cb: fn(Int) -> Bool)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Box(a) {\n"
    <> "  Box(item: a)\n"
    <> "}\n"

  let app_src =
    "import demo/types as t\n"
    <> "import demo/types.{Admin, type Handler}\n"
    <> "\n"
    <> "pub type AppState {\n"
    <> "  AppState(handlers: List(Handler), meta: #(Int, t.Tree))\n"
    <> "}\n"
    <> "\n"
    <> "pub type BadTree {\n"
    <> "  BadLeaf(Int)\n"
    <> "  BadNode(next: BadTree, on_visit: fn(Int) -> Int)\n"
    <> "}\n"
    <> "\n"
    <> "/// @external(moonbit, \"mbt/net\", \"send\")\n"
    <> "pub fn send_packet(to dest: String, body payload: String) -> Bool {\n"
    <> "  False\n"
    <> "}\n"
    <> "\n"
    <> "fn private_compute(a, b) {\n"
    <> "  a + b\n"
    <> "}\n"

  let assert Ok(#(types_ast, types_pre)) =
    prepass.parse_module("demo/types", types_src)
  let assert Ok(#(app_ast, app_pre)) = prepass.parse_module("demo/app", app_src)

  // Simulate package-interface output for `private_compute`
  let fake_iface =
    interface.PackageInterface(
      name: "demo",
      version: "0.1.0",
      modules: dict.from_list([
        #(
          "demo/app",
          interface.ModuleInterface(
            type_aliases: dict.new(),
            types: dict.new(),
            constants: dict.new(),
            functions: dict.from_list([
              #(
                "private_compute",
                interface.ResolvedFunction(
                  parameters: [
                    interface.ResolvedParam(
                      None,
                      interface.NamedType("Int", "", "gleam", []),
                    ),
                    interface.ResolvedParam(
                      None,
                      interface.NamedType("Int", "", "gleam", []),
                    ),
                  ],
                  return: interface.NamedType("Int", "", "gleam", []),
                  implementations: interface.Implementations(True, False, False),
                ),
              ),
            ]),
          ),
        ),
      ]),
    )

  let overrides =
    dict.from_list([
      #("demo/app.send_packet", prepass.PackageCall("override/net", "send_v2")),
    ])

  let table =
    symbol_table.index_project(
      "demo",
      [
        #("demo/types", types_ast, types_pre),
        #("demo/app", app_ast, app_pre),
      ],
      Some(fake_iface),
      overrides,
    )

  // 1. Import aliases & constructor resolution
  let assert Some(admin_ctor) =
    symbol_table.lookup_constructor(table, "demo/app", None, "Admin")
  assert admin_ctor.module == "demo/types"
  assert admin_ctor.type_name == "User"

  let assert Some(member_ctor) =
    symbol_table.lookup_constructor(table, "demo/app", Some("t"), "Member")
  assert member_ctor.variant_name == "Member"

  // 2. Shared fields synthesis metadata
  let assert Some(user_type) =
    symbol_table.lookup_type(table, "demo/types", None, "User")
  assert user_type.is_single_variant == False
  assert dict.keys(user_type.shared_fields) == ["id", "name"]

  let assert Some(conflict_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Conflict")
  assert dict.is_empty(conflict_type.shared_fields)

  let assert Some(point_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Point")
  assert point_type.is_single_variant == True
  assert dict.keys(point_type.shared_fields) == ["x", "y"]

  // 3. Transitive `has_function_field`
  let assert Some(handler_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Handler")
  assert handler_type.has_function_field == True

  let assert Some(tree_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Tree")
  assert tree_type.has_function_field == False

  let assert Some(box_type) =
    symbol_table.lookup_type(table, "demo/types", None, "Box")
  assert box_type.has_function_field == False

  let assert Some(app_state_type) =
    symbol_table.lookup_type(table, "demo/app", None, "AppState")
  assert app_state_type.has_function_field == True

  let assert Some(bad_tree_type) =
    symbol_table.lookup_type(table, "demo/app", None, "BadTree")
  assert bad_tree_type.has_function_field == True

  // 4. Function arity, labels, FFI override precedence, and HM private types
  let assert Ok(app_syms) = dict.get(table.modules, "demo/app")
  let assert Ok(send_fn) = dict.get(app_syms.functions, "send_packet")
  assert send_fn.arity == 2
  assert list.map(send_fn.parameters, fn(p) { p.label })
    == [Some("to"), Some("body")]
  assert send_fn.ffi == Some(prepass.PackageCall("override/net", "send_v2"))

  let assert Ok(priv_fn) = dict.get(app_syms.functions, "private_compute")
  assert priv_fn.publicity == glance.Private
  assert priv_fn.return_type
    == Some(interface.NamedType("Int", "", "gleam", []))
}
