# Companion Shim & Overlay Packages (`gekko`)

`gekko` lets you compile **unmodified upstream Hex packages** to MoonBit and WebAssembly by pairing them with a **companion shim (overlay) package**—without maintaining a source fork or fragile line-based diffs.

---

## Why Companion Shims Instead of Forks?

Most Gleam libraries are 90–99% pure Gleam with a small pocket of `@external(erlang, ...)` / `@external(javascript, ...)` functions and opaque external types. Maintaining a full fork forces you to rebase or cherry-pick on every upstream release.

A companion shim package is a tiny, standalone Gleam package that contains **no forked Gleam code**:

```text
gekko_simplifile/          # companion shim package
├── gleam.toml             # normal Gleam package metadata
├── gekko.toml             # symbol-level overrides, type mappings & injections
├── src/
│   └── gekko_simplifile.gleam
├── overlays/              # optional co-located .mbt files for [module_inject]
│   └── simplifile_patch.mbt
└── moonbit/               # MoonBit FFI packages
    └── simplifile_ffi/
        ├── moon.pkg
        └── simplifile_ffi.mbt
```

In your application's `gleam.toml`, depend on **both** the unmodified upstream library and its companion shim:

```toml
[dependencies]
simplifile = ">= 2.0.0 and < 3.0.0"
gekko_simplifile = { git = "https://github.com/...", ref = "main" }
```

- `gleam check` and `gleam test` (BEAM/JS) ignore `gekko.toml`, `overlays/`, and `moonbit/`, so standard Gleam tooling continues working untouched.
- `gekko` automatically discovers `gekko.toml` and `[tools.gekko.*]` overlays across all resolved dependencies and applies them during transpilation.

---

## Configuration Reference

Every overlay key can be placed in **`gekko.toml`** (recommended for shims) or under **`[tools.gekko.*]` in `gleam.toml`**.

### 1. `[shim]` — Target Package & SemVer Guard

Declares which upstream package the shim targets and the SemVer range it was written against:

```toml
[shim]
target = "simplifile"
version = ">= 2.0.0 and < 3.0.0"
```

Supported SemVer constraint operators: `>=`, `<=`, `>`, `<`, `==`, `!=`, `~>`, `^`, and compound clauses joined by `and` (or `&&` / `,`). If the resolved version of `target` in `manifest.toml` does not satisfy `version` (or `target` is not a dependency), `gekko` emits a clear warning.

---

### 2. `[type_overrides."..."]` — Opaque External Types

Maps an upstream zero-variant external type (`pub type Json`, `pub type Dict(k, v)`) to a MoonBit type, equivalent to `/// @external_type(moonbit, ...)`:

```toml
[type_overrides."gleam_json:gleam/json.Json"]
package = "gleam_json_ffi"
type = "Json"
```

Use `package = "builtin"` for MoonBit built-in types (e.g. `Option`) or `package = "gprelude"` for `gekko` prelude types.

Key lookup order for a type `T` in `pkg`'s `mod`:
1. `"<pkg>:<mod>.<T>"` *(recommended — avoids cross-package collisions)*
2. `"<pkg>.<mod>.<T>"`
3. `"<mod>.<T>"`

---

### 3. `[overrides."..."]` — Function Overrides

Maps an upstream function to one of three targets:

- **Cross-package MoonBit call (`package` + `function`):**
  ```toml
  [overrides."gleam_json:gleam/json.do_to_string"]
  package = "gleam_json_ffi"
  function = "json_to_string"
  ```
- **In-package call (`in_package`):** Calls a function defined in a file injected into the *same* transpiled MoonBit package via `[module_inject]`:
  ```toml
  [overrides."gleam_json:gleam/json.decode_string"]
  in_package = "__shim_decode_string"
  ```
- **Raw Wasm import (`wasm_module` + `import_name`):**
  ```toml
  [overrides."my_pkg:my_pkg/host.log_int"]
  wasm_module = "host"
  import_name = "log_int"
  ```

`package`, `in_package`, and `wasm_module` are mutually exclusive.

---

### 4. `[module_inject."..."]` — Solving Circular Package Dependencies

Upstream Gleam libraries frequently define an error `enum` (like `DecodeError` or `FileError`) in the **same module** as the `@external` functions that return it. Because MoonBit forbids circular package imports (`gleam_json` $\rightarrow$ `gleam_json_ffi` $\rightarrow$ `gleam_json`), an external `moonbit/` FFI package cannot import the transpiled Gleam module to construct `DecodeError`.

`[module_inject]` solves this cleanly by injecting a `.mbt` file **directly into the transpiled module's MoonBit package directory** (`build/moonbit/gleam_json/`):

```toml
[module_inject."gleam_json:gleam/json"]
files = ["overlays/gleam_json_patch.mbt"]
imports = ["gleam_json_ffi", "gleam/string_tree"]

[overrides."gleam_json:gleam/json.decode_string"]
in_package = "__shim_decode_string"

[overrides."gleam_json:gleam/json.to_string_tree"]
in_package = "__shim_to_string_tree"
```

```moonbit
// overlays/gleam_json_patch.mbt (compiled inside `gleam_json/`)
///|
fn __shim_decode_string(a : String) -> Result[@gprelude.Dynamic, DecodeError] {
  match @gleam_json_ffi.decode_string(a) {
    Ok(dyn) => Ok(dyn)
    Err((0L, _)) => Err(UnexpectedEndOfInput)
    Err((1L, s)) => Err(UnexpectedByte(s))
    Err((_, s)) => Err(UnexpectedSequence(s))
  }
}

///|
fn __shim_to_string_tree(json : Json) -> @gleam_string_tree.StringTree {
  @gleam_string_tree.from_string(do_to_string(json))
}
```

- **Place injected files outside `moonbit/`** (e.g. `overlays/`). Even if placed under `moonbit/`, `gekko` excludes injected files from standalone `moonbit/` package copying.
- **Imports:** Entries in `imports` can be MoonBit FFI packages (`"gleam_json_ffi"`), external MoonBit deps, or Gleam modules (`"gleam/string_tree"`, automatically mapped through `gekko`'s collision-safe package directory map). Use `"pkg as alias"` or `"pkg @alias"` if an alias conflicts with an existing module import.
- **Generic FFI trait inference:** `gekko` scans injected `.mbt` files so generic `in_package` functions participate in whole-project `Eq`/`Hash`/`GleamInspect` bound inference automatically.

---

### 5. `[target_branch."..."]` — Selecting `@target(javascript)` vs `@target(erlang)`

By default, `gekko` keeps `@target(erlang)` definitions and drops `@target(javascript)` definitions. When an upstream module has a pure-Gleam (or simpler) `@target(javascript)` branch, switch it per module or package:

```toml
[target_branch."some_pkg:some/module"]
prefer = "javascript"   # "erlang" (default) | "javascript"
```

---

### 6. `[moonbit.deps]` & `moonbit/<pkg>/` Packages

Shims can bundle local MoonBit packages in `moonbit/<pkg>/` and declare MoonBit registry dependencies in `moonbit/moon.mod` or `[moonbit.deps]` in `gekko.toml`. When `gekko` copies `moonbit/<pkg>/moon.pkg` from a dependency shim, it automatically rewrites `"<shim_pkg>/..."` imports to `"<root_project>/..."`.

---

## Precedence & Conflict Resolution

1. **Upstream source pragmas** (`/// @external(moonbit, ...)` / `/// @external_type(moonbit, ...)`) — lowest precedence.
2. **Dependency shims** (`gekko.toml` and `[tools.gekko.*]` in dependencies) — if two dependency shims define *different* overrides for the same key, `gekko` fails with an error naming both shims.
3. **Root project `gleam.toml`** (`[tools.gekko.*]`) — overrides dependency shims (and resolves conflicts between two dependency shims).
4. **Root project `gekko.toml`** — highest precedence.

---

## CLI Workflow (`gekko shim`)

Use `gekko shim inspect` and `gekko shim init` to audit any Hex dependency and scaffold a typed companion shim:

```bash
# 1. Inspect a resolved dependency for unmapped externals and opaque types
gekko shim inspect simplifile

# 2. Scaffold a starter companion shim package (defaults to ./gekko_<pkg>)
gekko shim init simplifile
gekko shim init simplifile --out ../gekko_simplifile
```

`gekko shim init` generates `gleam.toml`, `gekko.toml` (with `[shim]`, `[type_overrides]`, and `[overrides]`), and `moonbit/<pkg>_ffi/<pkg>_ffi.mbt` containing typed `abort("todo")` stubs matching upstream's exact lowered MoonBit signatures.

---

## Upgradability & Maintainability Best Practices

1. **Override at the right boundary:**
   - For libraries with a small, stable `@external` leaf layer, override the leaf `@external` functions so you inherit all upstream pure-Gleam logic and bugfixes automatically.
   - For libraries wrapping churning Erlang/JS internals behind a stable public API, override at the **public SemVer API**—`gekko` automatically prunes unreachable private `@external` helpers.
2. **Rely on MoonBit's type checker:** `gekko` emits typed wrapper functions from upstream's `gleam export package-interface`. If an upstream upgrade changes a parameter, return type, or error variant, `moon check` catches it immediately at compile time.
3. **Heed stale-override and version warnings:** When an upstream upgrade renames or removes an overridden function, type, or module, `gekko` warns about the unmatched key so dead shim code doesn't accumulate silently.
4. **Test against upstream's test suite in CI:** Run `gekko test` against the upstream package's tests in your shim repository's CI so upstream upgrades are a version bump + `gekko test`.
