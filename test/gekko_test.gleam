import emit/moonbit
import emit/pkg_config
import emit/prelude_runtime
import emit/stdlib_runtime
import emit/wit_bridge
import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit
import index/symbol_table
import lower/desugar
import lower/ir
import lower/mangle
import lower/pattern
import lower/tco
import moonbit/bindgen
import moonbit/mbti
import project/cmd
import project/ffi_config
import project/interface
import project/loader
import project/moonbit_ffi
import project/prepass
import project/staging
import project/workspace
import simplifile
import wit/ast as wit_ast
import wit/gleam_gen
import wit/parser as wit_parser

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

// -----------------------------------------------------------------------------
// 6. Phase 2: Mangling tests
// -----------------------------------------------------------------------------

pub fn mangle_keywords_and_type_params_test() {
  assert mangle.is_reserved_keyword("match") == True
  assert mangle.is_reserved_keyword("loop") == True
  assert mangle.is_reserved_keyword("guard") == True
  assert mangle.is_reserved_keyword("struct") == True
  assert mangle.is_reserved_keyword("count") == False

  assert mangle.mangle_ident("match") == "match_"
  assert mangle.mangle_ident("loop") == "loop_"
  assert mangle.mangle_ident("guard") == "guard_"
  assert mangle.mangle_ident("module") == "module_"
  assert mangle.mangle_ident("extern") == "extern_"
  assert mangle.mangle_ident("declare") == "declare_"
  assert mangle.mangle_ident("dyn") == "dyn_"
  assert mangle.mangle_ident("ignore") == "ignore_"
  assert mangle.mangle_ident("println") == "println_"
  assert mangle.mangle_ident("normal_var") == "normal_var"

  assert mangle.is_reserved_type_name("Error") == True
  assert mangle.is_reserved_type_name("Option") == True
  assert mangle.is_reserved_type_name("User") == False
  assert mangle.mangle_type_name("Error") == "Error_"
  assert mangle.mangle_type_name("Option") == "Option_"
  assert mangle.mangle_type_name("User") == "User"

  assert mangle.mangle_type_param("item") == "Item"
  assert mangle.mangle_type_param("key_value") == "KeyValue"
  assert mangle.mangle_type_param("int") == "T_Int"
  assert mangle.mangle_type_param("string") == "T_String"
  assert mangle.type_var_id_to_name(2) == "T2"
}

// -----------------------------------------------------------------------------
// 7. Phase 2: Pattern lowering tests
// -----------------------------------------------------------------------------

pub fn pattern_lists_strings_and_shorthand_variants_test() {
  let src =
    "pub type User {\n"
    <> "  User(name: String, age: Int)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn inspect_list(xs: List(Int)) -> Int {\n"
    <> "  case xs {\n"
    <> "    [] -> 0\n"
    <> "    [x] -> x\n"
    <> "    [x, y, ..rest] -> x + y\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn parse_cmd(s: String) -> String {\n"
    <> "  case s {\n"
    <> "    \"cmd:\" as p <> rest if rest != \"\" -> p <> rest\n"
    <> "    \"hi:\" <> rest -> rest\n"
    <> "    _ -> \"\"\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn match_user(u: User) -> String {\n"
    <> "  case u {\n"
    <> "    User(name:, ..) -> name\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("pat_mod", src)
  let table =
    symbol_table.index_project(
      "pat_pkg",
      [#("pat_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "pat_mod")

  // List pattern lowering: [], [x], [x, y, ..rest]
  let assert Ok(inspect_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "inspect_list" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: list_clauses, ..))] =
    inspect_fn.body
  let assert [c_empty, c_single, c_cons2] = list_clauses

  assert c_empty.patterns
    == [[ir.IrPatVariant(Some("gprelude"), None, "Nil", [], False)]]
  assert c_single.patterns
    == [
      [
        ir.IrPatVariant(
          Some("gprelude"),
          None,
          "Cons",
          [
            ir.IrPatArg(None, ir.IrPatVar("x")),
            ir.IrPatArg(
              None,
              ir.IrPatVariant(Some("gprelude"), None, "Nil", [], False),
            ),
          ],
          False,
        ),
      ],
    ]
  assert c_cons2.patterns
    == [
      [
        ir.IrPatVariant(
          Some("gprelude"),
          None,
          "Cons",
          [
            ir.IrPatArg(None, ir.IrPatVar("x")),
            ir.IrPatArg(
              None,
              ir.IrPatVariant(
                Some("gprelude"),
                None,
                "Cons",
                [
                  ir.IrPatArg(None, ir.IrPatVar("y")),
                  ir.IrPatArg(None, ir.IrPatVar("rest")),
                ],
                False,
              ),
            ),
          ],
          False,
        ),
      ],
    ]

  // String prefix pattern lowering with `as` prefix alias + user guard
  let assert Ok(parse_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "parse_cmd" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: str_clauses, ..))] =
    parse_fn.body
  let assert [c_cmd, c_hi, c_wild] = str_clauses

  assert c_cmd.patterns == [[ir.IrPatVar("__str_pfx_0")]]
  assert c_cmd.prefix_bindings
    == [
      #("p", ir.IrString("cmd:")),
      #(
        "rest",
        ir.IrCall(
          ir.IrModuleRef(Some("gprelude"), "gprelude", "string_drop_prefix"),
          [
            ir.IrCallArg(None, ir.IrVar("__str_pfx_0")),
            ir.IrCallArg(None, ir.IrString("cmd:")),
          ],
        ),
      ),
    ]
  // Guard has both synthetic has_prefix AND user guard wrapped with prefix bindings
  let assert Some(ir.IrBinOp(ir.IrAnd, has_pfx_call, ir.IrBlock(guard_block))) =
    c_cmd.guard
  assert has_pfx_call
    == ir.IrCall(
      ir.IrModuleRef(Some("gprelude"), "gprelude", "string_has_prefix"),
      [
        ir.IrCallArg(None, ir.IrVar("__str_pfx_0")),
        ir.IrCallArg(None, ir.IrString("cmd:")),
      ],
    )
  assert list.length(guard_block) == 3

  assert c_hi.patterns == [[ir.IrPatVar("__str_pfx_1")]]
  assert c_wild.patterns == [[ir.IrPatDiscard]]

  // Shorthand variant pattern: User(name:, ..)
  let assert Ok(user_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "match_user" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: [c_user], ..))] = user_fn.body
  assert c_user.patterns
    == [
      [
        ir.IrPatVariant(
          None,
          None,
          "User",
          [ir.IrPatArg(Some("name"), ir.IrPatVar("name"))],
          True,
        ),
      ],
    ]
  let _ = pattern.lower_pattern
  Nil
}

// -----------------------------------------------------------------------------
// 8. Phase 2: Desugar, Use, Pipes, Captures, Getters & Record Updates
// -----------------------------------------------------------------------------

pub fn desugar_use_chains_and_let_assert_test() {
  let src =
    "pub fn wrap(x: a, f: fn(a) -> b) -> b {\n"
    <> "  f(x)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn bare(f: fn(Int) -> Int) -> Int {\n"
    <> "  f(10)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn pipeline(res: Result(Int, String)) -> Int {\n"
    <> "  use #(a, b) <- wrap(#(1, 2))\n"
    <> "  use n <- bare\n"
    <> "  let assert Ok(v) = res as \"must be ok\"\n"
    <> "  a + b + n + v\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("use_mod", src)
  let table =
    symbol_table.index_project(
      "use_pkg",
      [#("use_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "use_mod")
  let assert Ok(pipe_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "pipeline" })

  // Outer `use #(a, b) <- wrap(#(1, 2))` becomes single call expr
  let assert [
    ir.IrStmtExpr(ir.IrCall(
      ir.IrVar("wrap"),
      [
        ir.IrCallArg(None, ir.IrTuple([ir.IrInt("1"), ir.IrInt("2")])),
        ir.IrCallArg(None, ir.IrFn(params: [outer_param], body: outer_body, ..)),
      ],
    )),
  ] = pipe_fn.body

  assert outer_param.name == "__use_arg_0"

  // Destructured tuple `let #(a, b) = __use_arg_0`, followed by `use n <- bare`
  let assert [
    ir.IrStmtLet(
      ir.IrPatTuple([ir.IrPatVar("a"), ir.IrPatVar("b")]),
      None,
      ir.IrVar("__use_arg_0"),
    ),
    ir.IrStmtExpr(ir.IrCall(
      ir.IrVar("bare"),
      [ir.IrCallArg(None, ir.IrFn(params: [inner_param], body: inner_body, ..))],
    )),
  ] = outer_body

  assert inner_param.name == "n"

  // Inside inner closure: `let assert Ok(v) = res` -> IrStmtGuard + final addition
  let assert [
    ir.IrStmtGuard(
      value: ir.IrVar("res"),
      pattern: ir.IrPatVariant(
        None,
        None,
        "Ok",
        [ir.IrPatArg(None, ir.IrPatVar("v"))],
        False,
      ),
      guard_condition: None,
      abort_message: Some(ir.IrString("must be ok")),
      post_bindings: [],
    ),
    ir.IrStmtExpr(ir.IrBinOp(ir.IrAddInt, _, ir.IrVar("v"))),
  ] = inner_body
}

pub fn desugar_pipes_captures_getters_and_record_updates_test() {
  let helper_src =
    "pub fn inc(x: Int) -> Int {\n"
    <> "  x + 1\n"
    <> "}\n"
    <> "\n"
    <> "pub type Account {\n"
    <> "  Admin(id: Int, name: String, level: Int)\n"
    <> "  Guest(id: Int, name: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Box(a) {\n"
    <> "  Box(value: a, tag: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Hook {\n"
    <> "  Hook(cb: fn(Int) -> Int)\n"
    <> "}\n"

  let main_src =
    "import app/helper\n"
    <> "import app/helper.{Admin, Box, Guest}\n"
    <> "\n"
    <> "pub fn add(a: Int, b: Int) -> Int { a + b }\n"
    <> "pub fn divide(numerator: Int, by denominator: Int) -> Int { numerator / denominator }\n"
    <> "pub fn greet(prefix p: String, name n: String) -> String { p <> n }\n"
    <> "pub fn make_adder(n: Int) -> fn(Int) -> Int { fn(x) { x + n } }\n"
    <> "\n"
    <> "pub fn test_pipes_and_captures(x: Int) -> Int {\n"
    <> "  let f1 = add(1, _)\n"
    <> "  let f2 = divide(by: _, 20)\n"
    <> "  let r1 = x |> helper.inc\n"
    <> "  let r2 = x |> add(10)\n"
    <> "  let r3 = x |> make_adder(5)\n"
    <> "  let r4 = x |> add(1, _)\n"
    <> "  f1(r1) + f2(2) + r2 + r3 + r4\n"
    <> "}\n"
    <> "\n"
    <> "pub fn test_labeled_pipe() -> String {\n"
    <> "  \"Alice\" |> greet(prefix: \"Hi, \")\n"
    <> "}\n"
    <> "\n"
    <> "pub fn test_getters_and_updates(acc: Account, box: Box(Int)) -> #(Int, Account, Box(Int), Int) {\n"
    <> "  let helper = box\n"
    <> "  let v = helper.value\n"
    <> "  let id = acc.id\n"
    <> "  let name = \"NewName\"\n"
    <> "  let acc2 = Admin(..acc, name:)\n"
    <> "  let box2 = Box(..box, value: 99)\n"
    <> "  #(id, acc2, box2, v)\n"
    <> "}\n"

  let assert Ok(#(helper_ast, helper_pre)) =
    prepass.parse_module("app/helper", helper_src)
  let assert Ok(#(main_ast, main_pre)) =
    prepass.parse_module("app/main", main_src)

  let table =
    symbol_table.index_project(
      "app",
      [
        #("app/helper", helper_ast, helper_pre),
        #("app/main", main_ast, main_pre),
      ],
      None,
      dict.new(),
    )

  let helper_ir = desugar.desugar_module(helper_ast, table, "app/helper")
  let main_ir = desugar.desugar_module(main_ast, table, "app/main")

  // Verify Uniform Enum derive flag & synthesized getters on helper_ir
  let assert Ok(acc_def) =
    list.find(helper_ir.types, fn(t) { t.name == "Account" })
  assert acc_def.derive_eq_debug_hash == True

  let assert Ok(hook_def) =
    list.find(helper_ir.types, fn(t) { t.name == "Hook" })
  assert hook_def.derive_eq_debug_hash == False

  let acc_getters =
    list.filter(helper_ir.getters, fn(g) { g.type_name == "Account" })
  assert list.map(acc_getters, fn(g) { g.field_name }) == ["id", "name"]

  let box_getters =
    list.filter(helper_ir.getters, fn(g) { g.type_name == "Box" })
  assert list.map(box_getters, fn(g) { #(g.field_name, g.type_params) })
    == [#("tag", ["A"]), #("value", ["A"])]

  // Verify captures & pipes
  let assert Ok(pipes_fn) =
    list.find(main_ir.functions, fn(f) { f.name == "test_pipes_and_captures" })
  let assert [
    // f1 = add(1, _)
    ir.IrStmtLet(
      ir.IrPatVar("f1"),
      None,
      ir.IrFn(
        params: [ir.IrFnParam("__capture_0", None)],
        body: [
          ir.IrStmtExpr(ir.IrCall(
            ir.IrVar("add"),
            [
              ir.IrCallArg(None, ir.IrInt("1")),
              ir.IrCallArg(None, ir.IrVar("__capture_0")),
            ],
          )),
        ],
        ..,
      ),
    ),
    // f2 = divide(by: _, 20)
    ir.IrStmtLet(
      ir.IrPatVar("f2"),
      None,
      ir.IrFn(
        params: [ir.IrFnParam("__capture_1", None)],
        body: [
          ir.IrStmtExpr(ir.IrCall(
            ir.IrVar("divide"),
            [
              ir.IrCallArg(Some("by"), ir.IrVar("__capture_1")),
              ir.IrCallArg(None, ir.IrInt("20")),
            ],
          )),
        ],
        ..,
      ),
    ),
    // r1 = x |> helper.inc
    ir.IrStmtLet(
      ir.IrPatVar("r1"),
      None,
      ir.IrCall(
        ir.IrModuleRef(Some("helper"), "app/helper", "inc"),
        [ir.IrCallArg(None, ir.IrVar("x"))],
      ),
    ),
    // r2 = x |> add(10)
    ir.IrStmtLet(
      ir.IrPatVar("r2"),
      None,
      ir.IrCall(
        ir.IrVar("add"),
        [ir.IrCallArg(None, ir.IrVar("x")), ir.IrCallArg(None, ir.IrInt("10"))],
      ),
    ),
    // r3 = x |> make_adder(5)  (saturated -> closure call)
    ir.IrStmtLet(
      ir.IrPatVar("r3"),
      None,
      ir.IrCall(
        ir.IrCall(ir.IrVar("make_adder"), [ir.IrCallArg(None, ir.IrInt("5"))]),
        [ir.IrCallArg(None, ir.IrVar("x"))],
      ),
    ),
    // r4 = x |> add(1, _)
    ir.IrStmtLet(
      ir.IrPatVar("r4"),
      None,
      ir.IrCall(
        ir.IrVar("add"),
        [ir.IrCallArg(None, ir.IrInt("1")), ir.IrCallArg(None, ir.IrVar("x"))],
      ),
    ),
    _,
  ] = pipes_fn.body

  // Verify labeled pipe slot resolution: "Alice" |> greet(prefix: "Hi, ")
  let assert Ok(greet_pipe_fn) =
    list.find(main_ir.functions, fn(f) { f.name == "test_labeled_pipe" })
  assert greet_pipe_fn.body
    == [
      ir.IrStmtExpr(
        ir.IrCall(ir.IrVar("greet"), [
          ir.IrCallArg(Some("name"), ir.IrString("Alice")),
          ir.IrCallArg(Some("prefix"), ir.IrString("Hi, ")),
        ]),
      ),
    ]

  // Verify local variable shadowing module alias (`let helper = box; helper.value` -> getter),
  // uniform getter (`acc.id`), and multi-variant vs single-variant record updates
  let assert Ok(upd_fn) =
    list.find(main_ir.functions, fn(f) { f.name == "test_getters_and_updates" })
  let assert [
    ir.IrStmtLet(ir.IrPatVar("helper"), None, ir.IrVar("box")),
    ir.IrStmtLet(
      ir.IrPatVar("v"),
      None,
      ir.IrGetterCall(ir.IrVar("helper"), "value"),
    ),
    ir.IrStmtLet(
      ir.IrPatVar("id"),
      None,
      ir.IrGetterCall(ir.IrVar("acc"), "id"),
    ),
    ir.IrStmtLet(ir.IrPatVar("name"), None, ir.IrString("NewName")),
    ir.IrStmtLet(
      ir.IrPatVar("acc2"),
      None,
      ir.IrMatch([ir.IrVar("acc")], [acc_match_arm, acc_abort_arm]),
    ),
    ir.IrStmtLet(
      ir.IrPatVar("box2"),
      None,
      ir.IrMatch([ir.IrVar("box")], [box_match_arm]),
    ),
    _,
  ] = upd_fn.body

  // Multi-variant record update has abort fallback and non-shadowing synthetic vars
  assert acc_abort_arm.patterns == [[ir.IrPatDiscard]]
  assert acc_abort_arm.body
    == ir.IrAbort(
      ir.PanicAbort,
      Some(ir.IrString("unreachable record update variant")),
    )
  let assert [
    [
      ir.IrPatVariant(
        Some("helper"),
        Some("app/helper"),
        "Admin",
        [
          ir.IrPatArg(Some("id"), ir.IrPatVar("__upd_2_id")),
          ir.IrPatArg(Some("name"), ir.IrPatDiscard),
          ir.IrPatArg(Some("level"), ir.IrPatVar("__upd_2_level")),
        ],
        False,
      ),
    ],
  ] = acc_match_arm.patterns
  assert acc_match_arm.body
    == ir.IrCall(ir.IrConstructor(Some("helper"), Some("app/helper"), "Admin"), [
      ir.IrCallArg(Some("id"), ir.IrVar("__upd_2_id")),
      ir.IrCallArg(Some("name"), ir.IrVar("name")),
      ir.IrCallArg(Some("level"), ir.IrVar("__upd_2_level")),
    ])

  // Single-variant record update is exhaustive (1 arm, no abort fallback)
  let assert [
    [
      ir.IrPatVariant(
        Some("helper"),
        Some("app/helper"),
        "Box",
        [
          ir.IrPatArg(Some("value"), ir.IrPatDiscard),
          ir.IrPatArg(Some("tag"), ir.IrPatVar("__upd_3_tag")),
        ],
        False,
      ),
    ],
  ] = box_match_arm.patterns
}

// -----------------------------------------------------------------------------
// 9. Phase 2: Functional `for` TCO tests
// -----------------------------------------------------------------------------

pub fn tco_functional_for_loop_lowering_test() {
  let src =
    "pub fn sum_loop(items: List(Int), acc: Int) -> Int {\n"
    <> "  case items {\n"
    <> "    [] -> acc\n"
    <> "    [x, ..rest] -> sum_loop(rest, acc + x)\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn count_labeled(count n: Int, acc total: Int, tag _tag: String) -> Int {\n"
    <> "  case n {\n"
    <> "    0 -> total\n"
    <> "    _ -> {\n"
    <> "      let next = n - 1\n"
    <> "      count_labeled(acc: total + n, count: next, tag: \"loop\")\n"
    <> "    }\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn map_naive(items: List(Int), f: fn(Int) -> Int) -> List(Int) {\n"
    <> "  case items {\n"
    <> "    [] -> []\n"
    <> "    [x, ..rest] -> [f(x), ..map_naive(rest, f)]\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("tco_mod", src)
  let table =
    symbol_table.index_project(
      "tco_pkg",
      [#("tco_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod =
    desugar.desugar_module(ast_mod, table, "tco_mod")
    |> tco.optimize_module

  // 1. Self-tail-recursive sum_loop -> IrForLoop with IrBreak & IrContinue
  let assert Ok(sum_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "sum_loop" })
  let assert [
    ir.IrStmtExpr(ir.IrForLoop(
      bindings: [#("items", ir.IrVar("items")), #("acc", ir.IrVar("acc"))],
      body: [ir.IrStmtExpr(ir.IrMatch(clauses: [arm_nil, arm_cons], ..))],
    )),
  ] = sum_fn.body

  assert arm_nil.body == ir.IrBreak(ir.IrVar("acc"))
  assert arm_cons.body
    == ir.IrContinue([
      ir.IrVar("rest"),
      ir.IrBinOp(ir.IrAddInt, ir.IrVar("acc"), ir.IrVar("x")),
    ])

  // 2. Labeled reordered call args + discarded param normalized to `__tco_unused_2`
  let assert Ok(cnt_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "count_labeled" })
  assert list.map(cnt_fn.params, fn(p) { p.name })
    == ["n", "total", "__tco_unused_2"]
  let assert [
    ir.IrStmtExpr(ir.IrForLoop(
      bindings: [
        #("n", ir.IrVar("n")),
        #("total", ir.IrVar("total")),
        #("__tco_unused_2", ir.IrVar("__tco_unused_2")),
      ],
      body: [ir.IrStmtExpr(ir.IrMatch(clauses: [arm_zero, arm_step], ..))],
    )),
  ] = cnt_fn.body

  assert arm_zero.body == ir.IrBreak(ir.IrVar("total"))
  let assert ir.IrBlock([
    ir.IrStmtLet(ir.IrPatVar("next"), None, _),
    ir.IrStmtExpr(ir.IrContinue([
      ir.IrVar("next"),
      ir.IrBinOp(ir.IrAddInt, ir.IrVar("total"), ir.IrVar("n")),
      ir.IrString("loop"),
    ])),
  ]) = arm_step.body

  // 3. Non-tail-recursive map_naive stays an ordinary function (no IrForLoop)
  let assert Ok(map_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "map_naive" })
  let assert [ir.IrStmtExpr(ir.IrMatch(..))] = map_fn.body
}

// -----------------------------------------------------------------------------
// 10. Phase 3: Prelude runtime sync, pkg_config, MoonBit emitter & Golden E2E
// -----------------------------------------------------------------------------

pub fn prelude_runtime_matches_disk_files_test() {
  let assert Ok(disk_mbt) = simplifile.read("runtime/prelude/gprelude.mbt")
  let assert Ok(disk_pkg) = simplifile.read("runtime/prelude/moon.pkg")
  assert prelude_runtime.gprelude_mbt() == disk_mbt
  assert prelude_runtime.moon_pkg() == disk_pkg
}

pub fn pkg_config_generation_test() {
  assert pkg_config.module_to_pkg_dir("app/auth/token") == "app_auth_token"
  assert pkg_config.module_to_pkg_dir("prelude") == "mod_prelude"
  assert pkg_config.module_to_pkg_dir("gprelude") == "mod_gprelude"

  let mod_str = pkg_config.emit_moon_mod("demo", "0.2.0")
  assert string.contains(mod_str, "name = \"demo\"")
  assert string.contains(mod_str, "version = \"0.2.0\"")

  let pkg_str =
    pkg_config.emit_moon_pkg(
      "demo",
      [
        #("gprelude", "gprelude"),
        #("demo_math", "math"),
        #("demo_math", "math"),
        #("my_org/wit_fs", "my_org_wit_fs"),
      ],
      True,
    )
  assert string.contains(pkg_str, "\"demo/gprelude\" @gprelude,")
  assert string.contains(pkg_str, "\"demo/demo_math\" @math,")
  assert string.contains(pkg_str, "\"my_org/wit_fs\" @my_org_wit_fs,")
  assert string.contains(pkg_str, "\"is-main\": true")
}

pub fn emit_moonbit_ffi_and_constructs_test() {
  let src =
    "/// @external(moonbit, \"my_org/wit_fs\", \"read_file\")\n"
    <> "pub fn read_file(path: String) -> Result(String, Nil) {\n"
    <> "  Error(Nil)\n"
    <> "}\n"
    <> "\n"
    <> "@external(moonbit, \"wasm:env\", \"host_add\")\n"
    <> "pub fn host_add(a: Int, b: Int) -> Int\n"
    <> "\n"
    <> "pub fn greet(prefix p: String, name n: String) -> String {\n"
    <> "  p <> n\n"
    <> "}\n"
    <> "\n"
    <> "pub fn apply(x: a, f: fn(a) -> b) -> b {\n"
    <> "  f(x)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn wrap_ok(x: Int) -> Result(Int, String) {\n"
    <> "  apply(x, Ok)\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("ffi_mod", src)
  let table =
    symbol_table.index_project(
      "ffi_pkg",
      [#("ffi_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod =
    desugar.desugar_module(ast_mod, table, "ffi_mod")
    |> tco.optimize_module
  let #(mbt, imports) = moonbit.emit_module(ir_mod)

  assert list.contains(imports, #("my_org/wit_fs", "my_org_wit_fs"))
  assert string.contains(mbt, "@my_org_wit_fs.read_file(path)")
  assert string.contains(
    mbt,
    "fn __ffi_host_add(Int64, Int64) -> Int64 = \"env\" \"host_add\"",
  )
  assert string.contains(mbt, "__ffi_host_add(a, b)")
  assert string.contains(
    mbt,
    "pub fn greet(p : String, n : String) -> String {",
  )
  assert string.contains(mbt, "apply(x, fn(__c_0) { Ok(__c_0) })")
}

pub fn stdlib_runtime_all_shims_moon_check_test() {
  let out_dir = "build/shim_verify_out"
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  assert simplifile.create_directory_all(filepath.join(out_dir, "gprelude"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(out_dir, "moon.mod"),
      contents: pkg_config.emit_moon_mod("shim_verify", "0.1.0"),
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(out_dir, "gprelude/moon.pkg"),
      contents: prelude_runtime.moon_pkg(),
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(out_dir, "gprelude/gprelude.mbt"),
      contents: prelude_runtime.gprelude_mbt(),
    )
    == Ok(Nil)

  let all_mod_names =
    stdlib_runtime.all_shim_packages()
    |> list.map(fn(pkg) { pkg.module_name })
  assert stdlib_runtime.emit_shim_packages(
      "shim_verify",
      out_dir,
      all_mod_names,
    )
    == Ok(Nil)

  let wasm_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert wasm_res.exit_code == 0

  let wasm_gc_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert wasm_gc_res.exit_code == 0

  let js_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "js"],
      cwd: out_dir,
    )
  assert js_res.exit_code == 0

  let native_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "native"],
      cwd: out_dir,
    )
  assert native_res.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn golden_pure_gleam_e2e_test() {
  let out_dir = "build/test_fixtures/golden_pure_mbt"
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  let assert Ok(summary) =
    workspace.transpile_project("fixtures/golden/pure_gleam", out_dir)

  assert summary.project_name == "pure_gleam"
  assert simplifile.is_file(filepath.join(out_dir, "moon.mod")) == Ok(True)
  assert simplifile.is_file(filepath.join(out_dir, "gprelude/gprelude.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(out_dir, "pure_gleam/pure_gleam.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "pure_gleam_models/pure_gleam_models.mbt",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "pure_gleam_math/pure_gleam_math.mbt",
    ))
    == Ok(True)
  assert simplifile.is_file(filepath.join(
      out_dir,
      "test_pure_gleam_test/test_pure_gleam_test.mbt",
    ))
    == Ok(True)

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 4, failed: 0")

  let test_wasm_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_wasm_gc.exit_code == 0
  assert string.contains(test_wasm_gc.output, "passed: 4, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

fn symlink_root_package(pkg_name: String, dest_packages_dir: String) {
  let assert Ok(src_abs) =
    simplifile.resolve(filepath.join("build/packages", pkg_name))
  let dest = filepath.join(dest_packages_dir, pkg_name)
  let _ = simplifile.delete(file_or_dir_at: dest)
  assert simplifile.create_symlink(to: src_abs, from: dest) == Ok(Nil)
}

pub fn loader_dependency_fallback_and_unmapped_error_test() {
  assert loader.is_intercepted_package("gleam_stdlib")
  assert loader.is_intercepted_package("gleam_json")
  assert loader.is_intercepted_package("gleeunit")
  assert !loader.is_intercepted_package("tiny_slug")

  let root = "build/test_fixtures/loader_case"
  let _ = simplifile.delete(file_or_dir_at: root)
  let packages_dir = filepath.join(root, "build/packages")
  assert simplifile.create_directory_all(packages_dir) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"loader_app\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/loader_app.gleam"),
      contents: "pub fn id(x: Int) -> Int { x }\n",
    )
    == Ok(Nil)

  symlink_root_package("gleam_stdlib", packages_dir)

  // Dependency with Erlang external AND pure-Gleam fallback body
  let good_dir = filepath.join(packages_dir, "good_pkg")
  assert simplifile.create_directory_all(filepath.join(good_dir, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(good_dir, "gleam.toml"),
      contents: "name = \"good_pkg\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(good_dir, "src/good_mod.gleam"),
      contents: "@external(erlang, \"lists\", \"reverse\")\npub fn rev(xs: List(a)) -> List(a) { xs }\n",
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleam_stdlib = \"1.1.0\"\ngood_pkg = \"0.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "manifest.toml"),
      contents: "packages = [\n  { name = \"gleam_stdlib\", version = \"1.1.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"E191E535492DDFE6A6499E96C89A40D9BDF2B7F1DADD4D6BEDABE34027E5B1EA\" },\n  { name = \"good_pkg\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"good_pkg\", source = \"hex\", outer_checksum = \"00\" },\n]\n\n[requirements]\ngleam_stdlib = { version = \">= 1.0.0 and < 2.0.0\" }\n",
    )
    == Ok(Nil)

  let assert Ok(loaded_good) = loader.load_dependencies(root, dict.new())
  assert list.map(loaded_good, fn(d) { d.package_name }) == ["good_pkg"]

  // Dependency with bodyless Erlang external and no gekko.toml override must fail fast
  let bad_dir = filepath.join(packages_dir, "bad_pkg")
  assert simplifile.create_directory_all(filepath.join(bad_dir, "src"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(bad_dir, "gleam.toml"),
      contents: "name = \"bad_pkg\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(bad_dir, "src/bad_mod.gleam"),
      contents: "@external(erlang, \"bad_erl\", \"missing\")\npub fn missing() -> Int\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleam_stdlib = \"1.1.0\"\ngood_pkg = \"0.1.0\"\nbad_pkg = \"0.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)

  assert loader.load_dependencies(root, dict.new())
    == Error(
      "Unmapped external function bad_pkg:bad_mod.missing (add an override in gekko.toml)",
    )

  // Adding a gekko.toml override satisfies validation and loads both deps
  assert simplifile.write(
      to: filepath.join(root, "gekko.toml"),
      contents: "[overrides.\"bad_pkg:bad_mod.missing\"]\nwasm_module = \"env\"\nimport_name = \"missing\"\n",
    )
    == Ok(Nil)
  let assert Ok(overrides) = ffi_config.load_project_overrides(root)
  let assert Ok(loaded_both) = loader.load_dependencies(root, overrides)
  assert list.length(loaded_both) == 2

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn golden_stdlib_and_deps_e2e_test() {
  let fixture_dir = "fixtures/golden/stdlib_and_deps"
  let packages_dir = filepath.join(fixture_dir, "build/packages")
  let out_dir = "build/test_fixtures/golden_stdlib_mbt"

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(packages_dir) == Ok(Nil)
  symlink_root_package("gleam_stdlib", packages_dir)
  symlink_root_package("gleam_json", packages_dir)
  symlink_root_package("gleeunit", packages_dir)

  assert simplifile.copy_directory(
      at: filepath.join(fixture_dir, "vendor/tiny_slug"),
      to: filepath.join(packages_dir, "tiny_slug"),
    )
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleam_stdlib = \"1.1.0\"\ngleam_json = \"3.1.0\"\ngleeunit = \"1.11.0\"\ntiny_slug = \"0.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(fixture_dir, "manifest.toml"),
      contents: "packages = [\n"
        <> "  { name = \"gleam_json\", version = \"3.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"gleam_json\", source = \"hex\", outer_checksum = \"44FDAA8847BE8FC48CA7A1C089706BD54BADCC4C45B237A992EDDF9F2CDB2836\" },\n"
        <> "  { name = \"gleam_stdlib\", version = \"1.1.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"E191E535492DDFE6A6499E96C89A40D9BDF2B7F1DADD4D6BEDABE34027E5B1EA\" },\n"
        <> "  { name = \"gleeunit\", version = \"1.11.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"gleeunit\", source = \"hex\", outer_checksum = \"EC31ABA74256AEA531EDF8169931D775BBB384FED0A8A1BDC4DD9354E3E21826\" },\n"
        <> "  { name = \"tiny_slug\", version = \"0.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"tiny_slug\", source = \"hex\", outer_checksum = \"00\" },\n"
        <> "]\n\n[requirements]\ngleam_json = { version = \">= 3.0.0 and < 4.0.0\" }\ngleam_stdlib = { version = \">= 1.0.0 and < 2.0.0\" }\ngleeunit = { version = \">= 1.0.0 and < 2.0.0\" }\ntiny_slug = { version = \">= 0.1.0 and < 1.0.0\" }\n",
    )
    == Ok(Nil)

  let gleam_test_res =
    cmd.run(command: "gleam", args: ["test"], cwd: fixture_dir)
  assert gleam_test_res.exit_code == 0
  assert string.contains(gleam_test_res.output, "4 passed, no failures")

  let assert Ok(summary) = workspace.transpile_project(fixture_dir, out_dir)
  assert summary.project_name == "stdlib_and_deps"
  assert list.contains(summary.emitted_modules, "tiny_slug")
  assert simplifile.is_file(filepath.join(out_dir, "tiny_slug/tiny_slug.mbt"))
    == Ok(True)
  assert simplifile.is_file(filepath.join(out_dir, "gleam_json/gleam_json.mbt"))
    == Ok(True)

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 4, failed: 0")

  let test_wasm_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_wasm_gc.exit_code == 0
  assert string.contains(test_wasm_gc.output, "passed: 4, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

fn stage_offline_stdlib_json(fixture_dir: String) {
  let packages_dir = filepath.join(fixture_dir, "build/packages")
  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  assert simplifile.create_directory_all(packages_dir) == Ok(Nil)
  symlink_root_package("gleam_stdlib", packages_dir)
  symlink_root_package("gleam_json", packages_dir)
  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleam_stdlib = \"1.1.0\"\ngleam_json = \"3.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(fixture_dir, "manifest.toml"),
      contents: "packages = [\n"
        <> "  { name = \"gleam_json\", version = \"3.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"gleam_json\", source = \"hex\", outer_checksum = \"44FDAA8847BE8FC48CA7A1C089706BD54BADCC4C45B237A992EDDF9F2CDB2836\" },\n"
        <> "  { name = \"gleam_stdlib\", version = \"1.1.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"E191E535492DDFE6A6499E96C89A40D9BDF2B7F1DADD4D6BEDABE34027E5B1EA\" },\n"
        <> "]\n\n[requirements]\ngleam_json = { version = \">= 3.0.0 and < 4.0.0\" }\ngleam_stdlib = { version = \">= 1.0.0 and < 2.0.0\" }\n",
    )
    == Ok(Nil)
}

pub fn example_weather_app_moon_run_test() {
  let fixture_dir = "examples/weather_app"
  let out_dir = "build/test_fixtures/weather_app_mbt"
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  stage_offline_stdlib_json(fixture_dir)

  let expected_nyc =
    "Zip 10001 (New York City, NY): Temp 43.0 °F | Wind 1.8 mp/h | Humidity 67% | Condition: Clear sky"
  let expected_la =
    "Zip 90210 (Beverly Hills, CA): Temp 57.9 °F | Wind 11.9 mp/h | Humidity 32% | Condition: Clear sky"

  let assert Ok(summary) = workspace.transpile_project(fixture_dir, out_dir)
  assert summary.project_name == "weather_app"

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "weather_app", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, expected_nyc)
  assert string.contains(run_wasm.output, expected_la)

  let run_js =
    cmd.run(
      command: "moon",
      args: ["run", "weather_app", "--target", "js"],
      cwd: out_dir,
    )
  assert run_js.exit_code == 0
  assert string.contains(run_js.output, expected_nyc)
  assert string.contains(run_js.output, expected_la)

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

fn assert_no_unqualified_prelude_calls(source: String) {
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

pub fn runtime_no_unqualified_prelude_calls_test() {
  assert_no_unqualified_prelude_calls(prelude_runtime.gprelude_mbt())
  stdlib_runtime.all_shim_packages()
  |> list.each(fn(pkg) { assert_no_unqualified_prelude_calls(pkg.source) })
}

pub fn prelude_shadowing_and_reserved_names_e2e_test() {
  let root = "build/test_fixtures/prelude_hardening"
  let out_dir = "build/test_fixtures/prelude_hardening_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"prelude_hardening\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let lib_src =
    "pub type Error {\n"
    <> "  NotFound\n"
    <> "  Invalid(String)\n"
    <> "}\n\n"
    <> "pub fn abort(msg: String) -> String {\n"
    <> "  \"abort:\" <> msg\n"
    <> "}\n\n"
    <> "pub fn ignore(x: Int) -> Int {\n"
    <> "  x + 1\n"
    <> "}\n\n"
    <> "pub fn println(s: String) -> String {\n"
    <> "  \"println:\" <> s\n"
    <> "}\n\n"
    <> "pub fn module(declare: Int, extern: Int, yield: Int) -> Int {\n"
    <> "  declare + extern + yield\n"
    <> "}\n\n"
    <> "pub fn wrap_err(flag: Bool) -> Result(Int, Error) {\n"
    <> "  case flag {\n"
    <> "    True -> Ok(42)\n"
    <> "    False -> Error(NotFound)\n"
    <> "  }\n"
    <> "}\n"

  let test_src =
    "import prelude_hardening.{Invalid, NotFound}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let _ = prelude_hardening.println(\"ok\")\n"
    <> "  Nil\n"
    <> "}\n\n"
    <> "pub fn shadowing_and_reserved_test() {\n"
    <> "  assert prelude_hardening.abort(\"x\") == \"abort:x\"\n"
    <> "  assert prelude_hardening.ignore(10) == 11\n"
    <> "  assert prelude_hardening.println(\"y\") == \"println:y\"\n"
    <> "  assert prelude_hardening.module(1, 2, 3) == 6\n"
    <> "  let assert Ok(v) = prelude_hardening.wrap_err(True)\n"
    <> "  assert v == 42\n"
    <> "  assert prelude_hardening.wrap_err(False) == Error(NotFound)\n"
    <> "  let e = Invalid(\"bad\")\n"
    <> "  assert e != NotFound\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/prelude_hardening.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/prelude_hardening_test.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.project_name == "prelude_hardening"

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 1, failed: 0")

  let test_wasm_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_wasm_gc.exit_code == 0
  assert string.contains(test_wasm_gc.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn record_update_e2e_test() {
  let root = "build/test_fixtures/record_update"
  let out_dir = "build/test_fixtures/record_update_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"record_update\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)

  let types_src =
    "pub type Person {\n"
    <> "  Person(name: String, age: Int, tags: List(String))\n"
    <> "}\n\n"
    <> "pub type Shape {\n"
    <> "  Circle(radius: Int, label: String)\n"
    <> "  Rect(w: Int, h: Int, label: String)\n"
    <> "}\n\n"
    <> "pub type Pair {\n"
    <> "  Pair(Int, second: String)\n"
    <> "}\n"

  let lib_src =
    "import record_update/types.{type Person, type Shape, Circle, Person, Rect}\n\n"
    <> "pub fn rename(p: Person, name: String) -> Person {\n"
    <> "  Person(..p, name:)\n"
    <> "}\n\n"
    <> "pub fn birthday(p: Person) -> Person {\n"
    <> "  Person(..p, age: p.age + 1)\n"
    <> "}\n\n"
    <> "pub fn make() -> Person {\n"
    <> "  Person(\"ann\", 30, [\"a\"])\n"
    <> "}\n\n"
    <> "pub fn relabel(s: Shape, label: String) -> Shape {\n"
    <> "  case s {\n"
    <> "    Circle(..) -> Circle(..s, label: label)\n"
    <> "    Rect(..) -> Rect(..s, label: label)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn from_call() -> Person {\n"
    <> "  Person(..make(), name: \"bob\", tags: [])\n"
    <> "}\n"

  let test_src =
    "import record_update\n"
    <> "import record_update/types.{Circle, Pair, Person, Rect}\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn record_update_test() {\n"
    <> "  let p = record_update.make()\n"
    <> "  assert record_update.rename(p, \"zed\") == Person(\"zed\", 30, [\"a\"])\n"
    <> "  assert record_update.birthday(p) == Person(\"ann\", 31, [\"a\"])\n"
    <> "  assert p == Person(\"ann\", 30, [\"a\"])\n"
    <> "  assert record_update.from_call() == Person(\"bob\", 30, [])\n"
    <> "  let chained = Person(..Person(..p, age: 1), name: \"c\")\n"
    <> "  assert chained == Person(\"c\", 1, [\"a\"])\n"
    <> "  assert record_update.relabel(Circle(2, \"x\"), \"y\") == Circle(2, \"y\")\n"
    <> "  assert record_update.relabel(Rect(1, 2, \"x\"), \"y\") == Rect(1, 2, \"y\")\n"
    <> "  let pr = Pair(7, \"a\")\n"
    <> "  assert Pair(..pr, second: \"b\") == Pair(7, \"b\")\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/record_update.gleam"),
      contents: lib_src,
    )
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "src/record_update",
    ))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/record_update/types.gleam"),
      contents: types_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/record_update_test.gleam"),
      contents: test_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 1, failed: 0")

  let test_gc =
    cmd.run(
      command: "moon",
      args: ["test", "--target", "wasm-gc"],
      cwd: out_dir,
    )
  assert test_gc.exit_code == 0
  assert string.contains(test_gc.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn example_gleam_tour_moon_run_test() {
  let fixture_dir = "examples/gleam_tour"
  let out_dir = "build/test_fixtures/gleam_tour_mbt"
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  stage_offline_stdlib_json(fixture_dir)

  let assert Ok(summary) = workspace.transpile_project(fixture_dir, out_dir)
  assert summary.project_name == "gleam_tour"

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "gleam_tour", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "Hello, Joe!")
  assert string.contains(run_wasm.output, "=== Basics: Ints ===")
  assert string.contains(
    run_wasm.output,
    "=== Functions: Generics & Pipelines ===",
  )
  assert string.contains(
    run_wasm.output,
    "=== Flow Control: Case Expressions & Variable Patterns ===",
  )
  assert string.contains(
    run_wasm.output,
    "=== Data Types: Records, Accessors & Updates ===",
  )
  assert string.contains(
    run_wasm.output,
    "=== Standard Library: Dict & Option Modules ===",
  )
  assert string.contains(
    run_wasm.output,
    "=== Advanced Features: Use, Assert & Echo ===",
  )
  assert string.contains(run_wasm.output, "src/tour/data_types.gleam:")
  assert string.contains(run_wasm.output, "Person(\"Amy\", 26, True)")
  assert string.contains(run_wasm.output, "<<24, 3>>")
  assert string.contains(run_wasm.output, "dict.from_list([#(\"Lucy\", 13)])")
  assert string.contains(
    run_wasm.output,
    "Reversed via external fallback\n[5, 4, 3, 2, 1]",
  )
  assert string.contains(run_wasm.output, "[Basics]")
  assert string.contains(run_wasm.output, "[Functions]")
  assert string.contains(run_wasm.output, "[Flow Control]")
  assert string.contains(run_wasm.output, "[Data Types]")
  assert string.contains(run_wasm.output, "[Standard Library]")
  assert string.contains(run_wasm.output, "[Advanced Features]")
  assert string.contains(run_wasm.output, "[Gleam Tour Complete]")

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn echo_exact_gleam_behavior_e2e_test() {
  let root = "build/test_fixtures/echo_e2e"
  let out_dir = "build/test_fixtures/echo_e2e_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"echo_e2e\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\ngleam_json = \">= 3.0.0 and < 4.0.0\"\n",
    )
    == Ok(Nil)
  stage_offline_stdlib_json(root)

  let src =
    "import gleam/dict\n"
    <> "import gleam/option.{None, Some}\n"
    <> "import gleam/string\n\n"
    <> "pub type Person {\n"
    <> "  Person(name: String, age: Int, needs_glasses: Bool)\n"
    <> "}\n\n"
    <> "pub type Handler {\n"
    <> "  Handler(label: String, callback: fn(Int) -> Int)\n"
    <> "}\n\n"
    <> "fn generic_echo(x: a) -> a {\n"
    <> "  echo x\n"
    <> "}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let x = echo 41\n"
    <> "  assert x + 1 == 42\n"
    <> "  echo \"bare stmt\"\n"
    <> "  echo 3.0\n"
    <> "  echo True\n"
    <> "  echo False\n"
    <> "  echo Nil\n"
    <> "  echo \"hello \\\"world\\\"\"\n"
    <> "  echo [1, 2, 3]\n"
    <> "  echo #(1, 2.2, \"three\")\n"
    <> "  echo Ok(1)\n"
    <> "  echo Error(Nil)\n"
    <> "  echo Some(\"Nubi\")\n"
    <> "  echo None\n"
    <> "  echo <<3>>\n"
    <> "  echo <<6147:size(16)>>\n"
    <> "  echo Person(\"Amy\", 26, True)\n"
    <> "  echo Handler(\"cb\", fn(n) { n + 1 })\n"
    <> "  echo dict.from_list([#(\"a\", 1)])\n"
    <> "  echo 1 + 2 as \"sum msg\"\n"
    <> "  let _ = [1, 2] |> echo\n"
    <> "  let _ = generic_echo(99)\n"
    <> "  assert string.inspect(Person(\"Amy\", 26, True))\n"
    <> "    == \"Person(\\\"Amy\\\", 26, True)\"\n"
    <> "  Nil\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/echo_e2e.gleam"),
      contents: src,
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  assert summary.project_name == "echo_e2e"

  let assert_echo_output = fn(output: String) {
    assert string.contains(output, "src/echo_e2e.gleam:18\n41\n")
    assert string.contains(output, "src/echo_e2e.gleam:20\n\"bare stmt\"\n")
    assert string.contains(output, "src/echo_e2e.gleam:21\n3.0\n")
    assert string.contains(output, "src/echo_e2e.gleam:22\nTrue\n")
    assert string.contains(output, "src/echo_e2e.gleam:23\nFalse\n")
    assert string.contains(output, "src/echo_e2e.gleam:24\nNil\n")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:25\n\"hello \\\"world\\\"\"\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:26\n[1, 2, 3]\n")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:27\n#(1, 2.2, \"three\")\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:28\nOk(1)\n")
    assert string.contains(output, "src/echo_e2e.gleam:29\nError(Nil)\n")
    assert string.contains(output, "src/echo_e2e.gleam:30\nSome(\"Nubi\")\n")
    assert string.contains(output, "src/echo_e2e.gleam:31\nNone\n")
    assert string.contains(output, "src/echo_e2e.gleam:32\n<<3>>\n")
    assert string.contains(output, "src/echo_e2e.gleam:33\n<<24, 3>>\n")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:34\nPerson(\"Amy\", 26, True)\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:35\nHandler(\"cb\",")
    assert string.contains(
      output,
      "src/echo_e2e.gleam:36\ndict.from_list([#(\"a\", 1)])\n",
    )
    assert string.contains(output, "src/echo_e2e.gleam:37 sum msg\n3\n")
    assert string.contains(output, "src/echo_e2e.gleam:38\n[1, 2]\n")
    assert string.contains(output, "src/echo_e2e.gleam:14\n99\n")
  }

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "echo_e2e", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert_echo_output(run_wasm.output)

  let run_js =
    cmd.run(
      command: "moon",
      args: ["run", "echo_e2e", "--target", "js"],
      cwd: out_dir,
    )
  assert run_js.exit_code == 0
  assert_echo_output(run_js.output)

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

fn stage_offline_stdlib(fixture_dir: String) {
  let packages_dir = filepath.join(fixture_dir, "build/packages")
  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  assert simplifile.create_directory_all(packages_dir) == Ok(Nil)
  symlink_root_package("gleam_stdlib", packages_dir)
  assert simplifile.write(
      to: filepath.join(packages_dir, "packages.toml"),
      contents: "[packages]\ngleam_stdlib = \"1.1.0\"\n\n[git]\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(fixture_dir, "manifest.toml"),
      contents: "packages = [\n"
        <> "  { name = \"gleam_stdlib\", version = \"1.1.0\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"E191E535492DDFE6A6499E96C89A40D9BDF2B7F1DADD4D6BEDABE34027E5B1EA\" },\n"
        <> "]\n\n[requirements]\ngleam_stdlib = { version = \">= 1.0.0 and < 2.0.0\" }\n",
    )
    == Ok(Nil)
}

pub fn wit_parser_and_deps_unit_test() {
  assert wit_ast.kebab_to_snake("my-greeting-error") == "my_greeting_error"
  assert wit_ast.kebab_to_pascal("my-greeting-error") == "MyGreetingError"
  assert wit_ast.kebab_to_screaming("debug-info") == "DEBUG_INFO"
  assert wit_ast.escape_gleam_ident("type") == "type_"
  assert wit_ast.escape_gleam_ident("greet") == "greet"
  assert wit_ast.escape_erlang_reserved_module("logger") == "logger_export"
  assert wit_ast.escape_erlang_reserved_module("api") == "api"

  let wit_dir = "build/test_fixtures/wit_parse_test"
  let deps_dir = filepath.join(wit_dir, "deps/ext-log")
  let _ = simplifile.delete(file_or_dir_at: wit_dir)
  assert simplifile.create_directory_all(deps_dir) == Ok(Nil)

  let dep_src =
    "package ext-ns:ext-pkg@0.2.0;\n\n"
    <> "interface ext-logger {\n"
    <> "  enum log-level { debug-info, fatal-err, }\n"
    <> "  write-line: func(lvl: log-level, msg: string);\n"
    <> "}\n"
  let root_src =
    "// Comment header\n"
    <> "/* block /* nested */ comment */\n"
    <> "package my-ns:my-pkg@0.1.0;\n\n"
    <> "interface my-api {\n"
    <> "  use ext-ns:ext-pkg/ext-logger@0.2.0.{log-level};\n"
    <> "  flags access-flags { read-only, write-all }\n"
    <> "  type id-alias = u64;\n"
    <> "  record my-rec {\n"
    <> "    %type: string,\n"
    <> "    flags: access-flags,\n"
    <> "    pair: tuple<string, u32>,\n"
    <> "    raw: list<u8>,\n"
    <> "    note: option<string>,\n"
    <> "  }\n"
    <> "  variant api-err {\n"
    <> "    empty,\n"
    <> "    bad-id(id-alias),\n"
    <> "  }\n"
    <> "  run-ok: func(r: my-rec, lvl: log-level) -> result<my-rec, api-err>;\n"
    <> "  fail-only: func() -> result<_, string>;\n"
    <> "  void-res: func() -> result;\n"
    <> "}\n\n"
    <> "world my-world {\n"
    <> "  import ext-ns:ext-pkg/ext-logger@0.2.0;\n"
    <> "  import host-clock: func() -> u64;\n"
    <> "  export my-api;\n"
    <> "  export ping: func(x: s32) -> s32;\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(deps_dir, "log.wit"),
      contents: dep_src,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: root_src,
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)
  assert resolved.root_pkg.namespace == "my-ns"
  assert resolved.root_pkg.name == "my-pkg"
  assert resolved.world.name == "my-world"
  assert list.length(resolved.world.items) == 4
  assert dict.has_key(resolved.interfaces, "my-ns:my-pkg/my-api")
  assert dict.has_key(resolved.interfaces, "ext-ns:ext-pkg/ext-logger")

  let _ = simplifile.delete(file_or_dir_at: wit_dir)
  Nil
}

pub fn wit_gleam_gen_idempotent_stubs_test() {
  let root = "build/test_fixtures/wit_gen_test"
  let wit_dir = filepath.join(root, "wit")
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)

  let world_wit =
    "package demo:sample@0.1.0;\n\n"
    <> "interface host-log {\n"
    <> "  record entry { tag: string, count: u32 }\n"
    <> "  emit: func(e: entry);\n"
    <> "}\n\n"
    <> "interface svc {\n"
    <> "  use host-log.{entry};\n"
    <> "  echo-entry: func(e: entry) -> option<string>;\n"
    <> "}\n\n"
    <> "world sample-world {\n"
    <> "  import host-log;\n"
    <> "  import world-tick: func() -> u32;\n"
    <> "  export svc;\n"
    <> "  export ping: func(n: s32) -> s32;\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: world_wit,
    )
    == Ok(Nil)
  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)

  let assert Ok(rep1) = gleam_gen.generate_project_bindings(resolved, root)
  assert list.contains(rep1.written_files, "src/wit/host_log_types.gleam")
  assert list.contains(rep1.written_files, "src/wit/host_log.gleam")
  assert list.contains(rep1.written_files, "src/wit/sample_world_imports.gleam")
  assert list.contains(rep1.created_stubs, "src/svc.gleam")
  assert list.contains(rep1.created_stubs, "src/sample_world.gleam")

  let assert Ok(imp_src) =
    simplifile.read(from: filepath.join(root, "src/wit/host_log.gleam"))
  assert string.contains(
    imp_src,
    "/// @external(moonbit, \"wit_imp_demo_sample_host_log\", \"emit\")",
  )

  // Customize starter stub; second generation must regenerate `src/wit/` and
  // preserve the user's edited `src/svc.gleam` and `src/sample_world.gleam`.
  let custom_stub =
    "// custom user implementation\npub fn ping(n: Int) -> Int { n + 42 }\n"
  assert simplifile.write(
      to: filepath.join(root, "src/sample_world.gleam"),
      contents: custom_stub,
    )
    == Ok(Nil)

  let assert Ok(rep2) = gleam_gen.generate_project_bindings(resolved, root)
  assert list.contains(rep2.written_files, "src/wit/host_log.gleam")
  assert list.contains(rep2.skipped_existing_stubs, "src/svc.gleam")
  assert list.contains(rep2.skipped_existing_stubs, "src/sample_world.gleam")
  let assert Ok(preserved) =
    simplifile.read(from: filepath.join(root, "src/sample_world.gleam"))
  assert preserved == custom_stub

  let _ = simplifile.delete(file_or_dir_at: root)
  Nil
}

pub fn wit_greeter_gleam_check_test() {
  let fixture_dir = "examples/wit_greeter"
  stage_offline_stdlib(fixture_dir)

  let check_res = cmd.run(command: "gleam", args: ["check"], cwd: fixture_dir)
  assert check_res.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  Nil
}

pub fn wit_greeter_e2e_wasm_build_test() {
  let fixture_dir = "examples/wit_greeter"
  let wit_dir = filepath.join(fixture_dir, "wit")
  let out_dir = "build/test_fixtures/wit_greeter_mbt"
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  stage_offline_stdlib(fixture_dir)

  let assert Ok(summary) =
    wit_bridge.bridge_wit_workspace(fixture_dir, out_dir, wit_dir, None)
  assert summary.project_name == "wit_greeter"
  assert summary.world_name == "greeter"

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let assert Ok(imp_adapter) =
    simplifile.read(from: filepath.join(
      out_dir,
      "wit_imp_demo_greeter_logger/wit_imp_demo_greeter_logger.mbt",
    ))
  assert string.contains(imp_adapter, "@wit_raw.log(")

  let assert Ok(api_stub) =
    simplifile.read(from: filepath.join(
      out_dir,
      "gen/interface/demo/greeter/api/stub.mbt",
    ))
  assert string.contains(api_stub, "@gleam_export.greet(")
  assert string.contains(api_stub, "@gleam_export.sum_bytes(")

  let assert Ok(world_stub) =
    simplifile.read(from: filepath.join(out_dir, "gen/world/greeter/stub.mbt"))
  assert string.contains(world_stub, "@gleam_export.ping(")

  let comp_path = filepath.join(out_dir, "dist/greeter.wasm")
  case wit_bridge.bundle_component(summary, None, comp_path) {
    Ok(built) -> {
      assert built == comp_path
      assert simplifile.is_file(comp_path) == Ok(True)
    }
    Error(msg) -> {
      assert string.contains(msg, "wasm-tools")
      assert string.contains(msg, "gen.wasm")
      assert simplifile.is_file(summary.core_wasm_path) == Ok(True)
    }
  }

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn wit_wasmtime_runtime_e2e_test() {
  let root = "build/test_fixtures/wit_runtime_test"
  let out_dir = "build/test_fixtures/wit_runtime_mbt"
  let wit_dir = filepath.join(root, "wit")
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  assert simplifile.create_directory_all(wit_dir) == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"wit_runtime\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(wit_dir, "world.wit"),
      contents: "package demo:runtime@0.1.0;\n\nworld app {\n  export add: func(a: s32, b: s32) -> s32;\n  export echo-str: func(s: string) -> string;\n}\n",
    )
    == Ok(Nil)

  let assert Ok(resolved) = wit_parser.load_wit_dir(wit_dir, None)
  let assert Ok(_) = gleam_gen.generate_project_bindings(resolved, root)
  assert simplifile.write(
      to: filepath.join(root, "src/app.gleam"),
      contents: "pub fn add(a: Int, b: Int) -> Int {\n  a + b\n}\n\npub fn echo_str(s: String) -> String {\n  \"Hello, \" <> s\n}\n",
    )
    == Ok(Nil)

  let assert Ok(summary) =
    wit_bridge.bridge_wit_workspace(root, out_dir, wit_dir, None)
  let comp_path = filepath.join(out_dir, "dist/app.wasm")
  case wit_bridge.bundle_component(summary, None, comp_path) {
    Ok(built) -> {
      let wt_probe = cmd.run(command: "wasmtime", args: ["--version"], cwd: ".")
      case wt_probe.exit_code {
        0 -> {
          let r_add =
            cmd.run(
              command: "wasmtime",
              args: ["run", "--invoke", "add(20, 22)", built],
              cwd: ".",
            )
          assert r_add.exit_code == 0
          assert string.trim(r_add.output) == "42"

          let r_str =
            cmd.run(
              command: "wasmtime",
              args: ["run", "--invoke", "echo-str(\"Gleam! 🌙\")", built],
              cwd: ".",
            )
          assert r_str.exit_code == 0
          assert string.trim(r_str.output) == "\"Hello, Gleam! 🌙\""
        }
        _ -> Nil
      }
    }
    Error(msg) -> {
      assert string.contains(msg, "wasm-tools")
    }
  }

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn moonbit_ffi_collision_and_loose_file_error_test() {
  let root = "build/test_fixtures/mbt_ffi_errors"
  let out_dir = "build/test_fixtures/mbt_ffi_errors_out"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  // 1. Loose .mbt file in moonbit/ root must fail clearly.
  assert simplifile.create_directory_all(filepath.join(root, "moonbit"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/stray.mbt"),
      contents: "pub fn x() -> Int { 1 }\n",
    )
    == Ok(Nil)
  let assert Error(loose_err) =
    moonbit_ffi.copy_local_packages(
      root,
      "demo",
      out_dir,
      set.from_list(["gprelude"]),
    )
  assert string.contains(loose_err, "Loose MoonBit file 'stray.mbt'")

  // 2. Package colliding with gprelude must fail clearly.
  let _ = simplifile.delete_file(at: filepath.join(root, "moonbit/stray.mbt"))
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/gprelude"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/gprelude/bad.mbt"),
      contents: "pub fn x() -> Int { 1 }\n",
    )
    == Ok(Nil)
  let assert Error(prelude_err) =
    moonbit_ffi.copy_local_packages(
      root,
      "demo",
      out_dir,
      set.from_list(["gprelude"]),
    )
  assert string.contains(
    prelude_err,
    "collides with generated package directory 'gprelude'",
  )

  // 3. Package colliding with a Gleam module directory in workspace.transpile_project must fail.
  let _ = simplifile.delete(file_or_dir_at: root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/demo"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"demo\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/demo.gleam"),
      contents: "pub fn main() -> Nil { Nil }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "moonbit/demo/extra.mbt"),
      contents: "pub fn x() -> Int { 1 }\n",
    )
    == Ok(Nil)
  let assert Error(mod_err) = workspace.transpile_project(root, out_dir)
  assert string.contains(
    mod_err,
    "collides with generated package directory 'demo'",
  )

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn example_moonbit_ffi_e2e_test() {
  let fixture_dir = "examples/moonbit_ffi"
  let out_dir = "build/test_fixtures/moonbit_ffi_mbt"
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  stage_offline_stdlib(fixture_dir)

  let assert Ok(summary) = workspace.transpile_project(fixture_dir, out_dir)
  assert summary.project_name == "moonbit_ffi"
  assert summary.local_moonbit_packages == ["byte_ffi", "text_ffi"]

  // Verify auto-generated moon.pkg for text_ffi and verbatim copy for byte_ffi.
  let assert Ok(gen_pkg) =
    simplifile.read(from: filepath.join(out_dir, "text_ffi/moon.pkg"))
  assert string.contains(gen_pkg, "\"moonbit_ffi/gprelude\" @gprelude")
  let assert Ok(copied_pkg) =
    simplifile.read(from: filepath.join(out_dir, "byte_ffi/moon.pkg"))
  assert string.contains(copied_pkg, "\"moonbitlang/core/buffer\" @buffer")

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "moonbit_ffi", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "shout=HELLO MOONBIT!")
  assert string.contains(run_wasm.output, "upper=GLEAM,FFI")
  assert string.contains(run_wasm.output, "sum_squares=29")
  assert string.contains(run_wasm.output, "utf8_bytes=12")
  assert string.contains(run_wasm.output, "pow=1024.0")
  assert string.contains(run_wasm.output, "sin0=0.0,cos0=1.0")
  assert string.contains(run_wasm.output, "counter_total=115")

  let run_js =
    cmd.run(
      command: "moon",
      args: ["run", "moonbit_ffi", "--target", "js"],
      cwd: out_dir,
    )
  assert run_js.exit_code == 0
  assert string.contains(run_js.output, "shout=HELLO MOONBIT!")
  assert string.contains(run_js.output, "pow=1024.0")
  assert string.contains(run_js.output, "counter_total=115")

  let _ = simplifile.delete(file_or_dir_at: filepath.join(fixture_dir, "build"))
  let _ =
    simplifile.delete_file(at: filepath.join(fixture_dir, "manifest.toml"))
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn external_type_opaque_alias_and_record_embedding_e2e_test() {
  let root = "build/test_fixtures/ext_type_test"
  let out_dir = "build/test_fixtures/ext_type_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  stage_offline_stdlib(root)
  assert simplifile.create_directory_all(filepath.join(root, "src/ext_type"))
    == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "test")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(
      root,
      "moonbit/native_box",
    ))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"ext_type\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)

  // Local MoonBit types deliberately do NOT derive Eq/Debug/Show.
  let native_mbt =
    "///|\n"
    <> "pub struct OpaqueHandle {\n  id : Int64\n}\n\n"
    <> "///|\n"
    <> "pub fn make_handle(id : Int64) -> OpaqueHandle {\n  { id: id }\n}\n\n"
    <> "///|\n"
    <> "pub fn handle_id(h : OpaqueHandle) -> Int64 {\n  h.id\n}\n\n"
    <> "///|\n"
    <> "pub struct NativeBox[T] {\n  item : T\n}\n\n"
    <> "///|\n"
    <> "pub fn[T] wrap_box(item : T) -> NativeBox[T] {\n  { item: item }\n}\n\n"
    <> "///|\n"
    <> "pub fn[T] unwrap_box(b : NativeBox[T]) -> T {\n  b.item\n}\n"
  assert simplifile.write(
      to: filepath.join(root, "moonbit/native_box/native_box.mbt"),
      contents: native_mbt,
    )
    == Ok(Nil)

  let types_gleam =
    "/// @external_type(moonbit, \"native_box\", \"OpaqueHandle\")\n"
    <> "pub type Handle\n\n"
    <> "@external_type(moonbit, \"native_box\", \"NativeBox\")\n"
    <> "pub type Box(a)\n\n"
    <> "/// @external(moonbit, \"native_box\", \"make_handle\")\n"
    <> "pub fn make_handle(id: Int) -> Handle {\n"
    <> "  let _ = id\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"native_box\", \"handle_id\")\n"
    <> "pub fn handle_id(h: Handle) -> Int {\n"
    <> "  let _ = h\n"
    <> "  panic as \"mbt\"\n"
    <> "}\n\n"
    <> "@external(moonbit, \"native_box\", \"wrap_box\")\n"
    <> "pub fn wrap_box(x: a) -> Box(a)\n\n"
    <> "@external(moonbit, \"native_box\", \"unwrap_box\")\n"
    <> "pub fn unwrap_box(b: Box(a)) -> a\n"

  let main_gleam =
    "import ext_type/types.{type Box, type Handle}\n"
    <> "import gleam/string\n\n"
    <> "pub type Holder {\n"
    <> "  Holder(tag: String, handle: Handle, history: List(Handle), boxed: Result(Box(String), String))\n"
    <> "}\n\n"
    <> "pub fn verify_opaque_types() -> Bool {\n"
    <> "  let h1 = types.make_handle(10)\n"
    <> "  let h2 = types.make_handle(25)\n"
    <> "  let b = types.wrap_box(\"ok\")\n"
    <> "  let holder = Holder(tag: \"k\", handle: h1, history: [h1, h2], boxed: Ok(b))\n"
    <> "  let inspected = string.inspect(holder)\n"
    <> "  let box_val = case holder.boxed {\n"
    <> "    Ok(bx) -> types.unwrap_box(bx)\n"
    <> "    Error(_) -> \"bad\"\n"
    <> "  }\n"
    <> "  types.handle_id(holder.handle) == 10\n"
    <> "  && box_val == \"ok\"\n"
    <> "  && string.contains(inspected, \"Holder(\\\"k\\\", \\\"//external\\\"\")\n"
    <> "}\n"

  let test_gleam =
    "import ext_type\n\n"
    <> "pub fn main() -> Nil {\n  Nil\n}\n\n"
    <> "pub fn external_type_e2e_test() {\n"
    <> "  assert ext_type.verify_opaque_types()\n"
    <> "}\n"

  assert simplifile.write(
      to: filepath.join(root, "src/ext_type/types.gleam"),
      contents: types_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/ext_type.gleam"),
      contents: main_gleam,
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "test/ext_type_test.gleam"),
      contents: test_gleam,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let assert Ok(types_mbt) =
    simplifile.read(from: filepath.join(
      out_dir,
      "ext_type_types/ext_type_types.mbt",
    ))
  assert string.contains(
    types_mbt,
    "pub type Handle = @native_box.OpaqueHandle",
  )
  assert string.contains(
    types_mbt,
    "pub type Box[A] = @native_box.NativeBox[A]",
  )

  let assert Ok(main_mbt) =
    simplifile.read(from: filepath.join(out_dir, "ext_type/ext_type.mbt"))
  assert !string.contains(main_mbt, "#derive(Eq, Debug, Hash)")

  let check_res =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_res.exit_code == 0

  let test_wasm =
    cmd.run(command: "moon", args: ["test", "--target", "wasm"], cwd: out_dir)
  assert test_wasm.exit_code == 0
  assert string.contains(test_wasm.output, "passed: 1, failed: 0")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn mbti_parser_stdlib_math_and_buffer_test() {
  let moon_home = case cmd.get_env("MOON_HOME") {
    Ok(v) if v != "" -> v
    _ -> {
      let assert Ok(h) = cmd.get_env("HOME")
      filepath.join(h, ".moon")
    }
  }

  let math_path = filepath.join(moon_home, "lib/core/math/pkg.generated.mbti")
  let assert Ok(math_src) = simplifile.read(from: math_path)
  let assert Ok(math_pkg) = mbti.parse_mbti(math_src)
  assert math_pkg.package_name == "moonbitlang/core/math"
  assert list.contains(math_pkg.imports, #("moonbitlang/core/bigint", "bigint"))
  assert list.contains(math_pkg.imports, #("moonbitlang/core/random", "random"))
  assert list.any(math_pkg.constants, fn(c) { c.name == "PI" })
  assert list.any(math_pkg.functions, fn(f) {
    f.name == "sin" && !f.is_deprecated
  })
  assert list.any(math_pkg.functions, fn(f) {
    f.name == "is_probable_prime" && list.length(f.params) == 3
  })
  assert list.any(math_pkg.functions, fn(f) {
    f.name == "maximum" && f.is_deprecated
  })

  let buf_path = filepath.join(moon_home, "lib/core/buffer/pkg.generated.mbti")
  let assert Ok(buf_src) = simplifile.read(from: buf_path)
  let assert Ok(buf_pkg) = mbti.parse_mbti(buf_src)
  assert buf_pkg.package_name == "moonbitlang/core/buffer"
  assert list.any(buf_pkg.functions, fn(f) {
    f.owner_type == Some("Buffer") && f.name == "Buffer"
  })
  assert list.any(buf_pkg.functions, fn(f) {
    f.owner_type == Some("Buffer") && f.name == "write_string_utf8"
  })
  assert list.any(buf_pkg.functions, fn(f) {
    f.name == "new" && f.is_deprecated
  })

  // Inline complex fixture covering pub(all) struct, enum, private-fields struct, tuple, and bounds.
  let inline_mbti =
    "// Generated\n"
    <> "package \"demo/sample\"\n\n"
    <> "pub(all) struct Summary {\n  count : Int32\n  total : Int64\n}\n\n"
    <> "pub struct Hidden {\n  tag : String\n  // private fields\n}\n\n"
    <> "pub(all) enum Mode {\n  Fast\n  Exact(Int32)\n}\n\n"
    <> "pub fn summarize(Array[Int32], scale? : Int32) -> Summary\n"
    <> "pub fn[T : Show] debug_str(T) -> String\n"
  let assert Ok(parsed_inline) = mbti.parse_mbti(inline_mbti)
  assert parsed_inline.package_name == "demo/sample"
  assert list.length(parsed_inline.types) == 3
  assert list.length(parsed_inline.functions) == 2
  Nil
}

pub fn moonbit_bindgen_stdlib_buffer_e2e_test() {
  let root = "build/test_fixtures/bindgen_buffer_e2e"
  let out_dir = "build/test_fixtures/bindgen_buffer_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  stage_offline_stdlib(root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bindgen_buf\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)

  let assert Ok(res) =
    bindgen.bind_package(
      root,
      "moonbitlang/core/buffer",
      Some("ffi/buffer"),
      out_dir,
    )
  assert res.gleam_module_path == "ffi/buffer"
  assert res.adapter_pkg_dir == Some("buffer_adapter")

  let main_src =
    "import ffi/buffer\n"
    <> "import gleam/int\n"
    <> "import gleam/io\n"
    <> "import gleam/option.{None, Some}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let b1 = buffer.new_buffer(None)\n"
    <> "  buffer.write_string_utf16le(b1, \"hello \")\n"
    <> "  buffer.write_string_utf16le(b1, \"moonbit\")\n"
    <> "  let len1 = buffer.length(b1)\n"
    <> "  let s1 = buffer.to_string(b1)\n"
    <> "  assert s1 == \"hello moonbit\"\n"
    <> "  assert len1 == 26\n"
    <> "  let b2 = buffer.new_buffer(Some(32))\n"
    <> "  buffer.write_byte(b2, 65)\n"
    <> "  assert buffer.length(b2) == 1\n"
    <> "  assert buffer.to_bytes(b2) == <<65>>\n"
    <> "  io.println(\"buf=\" <> s1 <> \",len=\" <> int.to_string(len1))\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_buf.gleam"),
      contents: main_src,
    )
    == Ok(Nil)

  let check_gleam = cmd.run(command: "gleam", args: ["check"], cwd: root)
  assert check_gleam.exit_code == 0

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_moon =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_moon.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "bindgen_buf", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "buf=hello moonbit,len=26")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn moonbit_bindgen_local_pkg_e2e_test() {
  let root = "build/test_fixtures/bindgen_local_e2e"
  let out_dir = "build/test_fixtures/bindgen_local_mbt"
  let info_out = "build/test_fixtures/bindgen_local_info_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_out)

  stage_offline_stdlib(root)
  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.create_directory_all(filepath.join(root, "moonbit/stats"))
    == Ok(Nil)

  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"bindgen_local\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_local.gleam"),
      contents: "pub fn main() -> Nil {\n  Nil\n}\n",
    )
    == Ok(Nil)

  let stats_mbt =
    "///|\n"
    <> "pub(all) struct Summary {\n  count : Int\n  total : Int64\n}\n\n"
    <> "///|\n"
    <> "pub(all) enum Mode {\n  Fast\n  Exact(Int)\n}\n\n"
    <> "///|\n"
    <> "pub fn summarize(xs : Array[Int], scale~ : Int = 1) -> Summary {\n"
    <> "  let mut sum = 0L\n"
    <> "  for x in xs {\n"
    <> "    sum = sum + (x * scale).to_int64()\n"
    <> "  }\n"
    <> "  { count: xs.length(), total: sum }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn apply_mode(m : Mode, base : Int) -> Int {\n"
    <> "  match m {\n"
    <> "    Fast => base * 2\n"
    <> "    Exact(k) => base + k\n"
    <> "  }\n"
    <> "}\n\n"
    <> "///|\n"
    <> "pub fn checked_div(a : Int, b : Int) -> Int raise {\n"
    <> "  if b == 0 {\n"
    <> "    raise Failure::Failure(\"div by zero\")\n"
    <> "  }\n"
    <> "  a / b\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "moonbit/stats/stats.mbt"),
      contents: stats_mbt,
    )
    == Ok(Nil)

  let assert Ok(res) =
    bindgen.bind_package(root, "moonbit/stats", Some("ffi/stats"), info_out)
  assert res.gleam_module_path == "ffi/stats"
  assert res.adapter_pkg_dir == Some("stats_adapter")

  let main_src =
    "import ffi/stats\n"
    <> "import gleam/int\n"
    <> "import gleam/io\n"
    <> "import gleam/option.{None, Some}\n\n"
    <> "pub fn main() -> Nil {\n"
    <> "  let s1 = stats.summarize([2, 3, 5], None)\n"
    <> "  assert stats.summary_count(s1) == 3\n"
    <> "  assert stats.summary_total(s1) == 10\n"
    <> "  let s2 = stats.summarize([2, 3], Some(10))\n"
    <> "  assert stats.summary_total(s2) == 50\n"
    <> "  let s3 = stats.make_summary(4, 99)\n"
    <> "  assert stats.summary_count(s3) == 4 && stats.summary_total(s3) == 99\n"
    <> "  assert stats.apply_mode(stats.mode_fast(), 6) == 12\n"
    <> "  assert stats.apply_mode(stats.mode_exact(7), 6) == 13\n"
    <> "  assert stats.checked_div(12, 3) == Ok(4)\n"
    <> "  let div_err = stats.checked_div(12, 0)\n"
    <> "  let assert Error(_) = div_err\n"
    <> "  io.println(\"stats=\" <> int.to_string(stats.summary_total(s2)))\n"
    <> "}\n"
  assert simplifile.write(
      to: filepath.join(root, "src/bindgen_local.gleam"),
      contents: main_src,
    )
    == Ok(Nil)

  let assert Ok(_) = workspace.transpile_project(root, out_dir)

  let check_moon =
    cmd.run(
      command: "moon",
      args: ["check", "--deny-warn", "--target", "wasm"],
      cwd: out_dir,
    )
  assert check_moon.exit_code == 0

  let run_wasm =
    cmd.run(
      command: "moon",
      args: ["run", "bindgen_local", "--target", "wasm"],
      cwd: out_dir,
    )
  assert run_wasm.exit_code == 0
  assert string.contains(run_wasm.output, "stats=50")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  let _ = simplifile.delete(file_or_dir_at: info_out)
  Nil
}
