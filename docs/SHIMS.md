# Companion Shim & Overlay Packages (`gekko`)

`gekko` lets you compile **unmodified upstream Hex packages** to MoonBit and WebAssembly by pairing them with a **companion shim (overlay) package**—without maintaining a source fork or fragile line-based diffs.

---

## Why Co-Located Module Patches (`[patch]`)?

Most Gleam libraries are 90–99% pure Gleam with a small pocket of `@external(erlang, ...)` / `@external(javascript, ...)` functions and opaque external types.

In MoonBit, every directory is a package, and MoonBit forbids circular package imports (`pkg_a` $\leftrightarrow$ `pkg_b`). Because Gleam modules often define error enums (like `DecodeError`) in the *same* module as their `@external` functions, putting FFI in a separate MoonBit package creates circular dependencies.

**`gekko` solves this by placing each module's MoonBit patch directly inside that module's own transpiled MoonBit package:**

```text
gekko_json/                # companion shim package
├── gleam.toml             # normal Gleam package metadata
├── gekko.toml             # [shim] + [patch."pkg:mod"]
├── src/
│   └── gekko_json.gleam
└── patches/               # co-located .mbt files mirroring upstream modules
    └── gleam/
        └── json.mbt
```

Because Gleam already forbids circular imports between `.gleam` modules, co-located module patches keep MoonBit's package graph **100% acyclic**—with zero `__shim_` prefixes, zero extra packages, and direct access to same-module error enums and private helpers.

In your application's `gleam.toml`, depend on **both** the unmodified upstream library and its companion shim:

```toml
[dependencies]
gleam_json = ">= 3.0.0 and < 4.0.0"
gekko_json = { git = "https://github.com/...", ref = "main" }
```

- `gleam check` and `gleam test` (BEAM/JS) ignore `gekko.toml` and `patches/`, so standard Gleam tooling continues working untouched.
- `gekko` automatically discovers `gekko.toml` and `[tools.gekko.*]` overlays across all resolved dependencies and applies them during transpilation.

---

## Configuration Reference

Every overlay key can be placed in **`gekko.toml`** (recommended for shims) or under **`[tools.gekko.*]` in `gleam.toml`**.

### 1. `[shim]` — Target Package & SemVer Guard

Declares which upstream package the shim targets and the SemVer range it was written against:

```toml
[shim]
target = "gleam_json"
version = ">= 3.0.0 and < 4.0.0"
```

Supported SemVer constraint operators: `>=`, `<=`, `>`, `<`, `==`, `!=`, `~>`, `^`, and compound clauses joined by `and` (or `&&` / `,`). If the resolved version of `target` in `manifest.toml` does not satisfy `version` (or `target` is not a dependency), `gekko` emits a clear warning.

---

### 2. `[patch."pkg:mod"]` — Co-Located Module Patches *(Primary Mechanism)*

Copies one or more `.mbt` files directly into the transpiled module's MoonBit package directory (`build/moonbit/<mod>/`), skips emitting the listed `types` and `functions` in the generated `.mbt`, and emits zero-cost compile-time signature checks (`__gekko_sigcheck_<fn>`) so upstream type changes are caught immediately by `moon check`:

```toml
[patch."gleam_json:gleam/json"]
file = "patches/gleam/json.mbt"
imports = ["moonbitlang/core/json"]
types = ["Json"]
functions = [
  "decode_string",
  "to_string_tree",
  "do_to_string",
  "do_string",
  "do_bool",
  "do_int",
  "do_float",
  "do_null",
  "do_object",
  "do_preprocessed_array",
]
```

And `patches/gleam/json.mbt` defines `Json` and each listed function directly with its real name:

```moonbit
///|
pub(all) struct Json {
  raw : @json.Json
}

///|
fn decode_string(a : String) -> Result[@gprelude.Dynamic, DecodeError] {
  ... // constructs UnexpectedEndOfInput / UnexpectedByte directly
}

///|
pub fn to_string_tree(json : Json) -> @string_tree.StringTree {
  @string_tree.from_string(do_to_string(json))
}
```

- **`file` / `files`:** Path (or array of paths) relative to the shim package root. (`file` and `files` are mutually exclusive.)
- **`imports`:** Optional list of extra MoonBit packages or Gleam modules needed by the patch file (e.g. `"moonbitlang/core/json"` or `"gleam/dict"`). `gprelude` is imported automatically as `@gprelude`, and any package already imported by the upstream Gleam module is deduplicated automatically (use `"pkg as alias"` or `"pkg @alias"` if an alias conflicts).
- **`types`:** List of upstream zero-variant external types defined directly inside the patch file.
- **`functions`:** List of upstream functions implemented directly inside the patch file. Functions marked `pub` in Gleam must be `pub` in the `.mbt` patch file.

---

### 3. `[type_overrides."..."]` & `[overrides."..."]` — Direct Aliases

For one-line mappings that don't need a `.mbt` patch file (such as mapping `gleam/option.Option` to MoonBit's built-in `Option`, `gleam/dynamic.Dynamic` to `@gprelude.Dynamic`, or calling a third-party MoonBit package or raw Wasm import directly):

```toml
# Map an opaque type to a MoonBit builtin or external package type
[type_overrides."gleam_stdlib:gleam/option.Option"]
package = "builtin"
type = "Option"

# Map a function to a MoonBit package function
[overrides."simplifile:simplifile.read_bits"]
package = "simplifile_ffi"
function = "read_bits"

# Map a function to a raw Wasm host import
[overrides."my_pkg:my_pkg/host.log_int"]
wasm_module = "host"
import_name = "log_int"
```

Key lookup order: `"<pkg>:<mod>.<sym>"` (recommended), `"<pkg>.<mod>.<sym>"`, then `"<mod>.<sym>"`.

---

### 4. `[target_branch."..."]` — Selecting `@target(javascript)` vs `@target(erlang)`

By default, `gekko` keeps `@target(erlang)` definitions and drops `@target(javascript)` definitions. When an upstream module has a pure-Gleam (or simpler) `@target(javascript)` branch, switch it per module or package:

```toml
[target_branch."some_pkg:some/module"]
prefer = "javascript"   # "erlang" (default) | "javascript"
```

---

### 5. `[moonbit.deps]` & `moonbit/<pkg>/` Packages

Shims can declare MoonBit registry dependencies in `moonbit/moon.mod` or `[moonbit.deps]` in `gekko.toml`. If a shim also ships standalone `moonbit/<pkg>/` helper packages, `gekko` automatically rewrites `"<shim_pkg>/..."` imports in `moon.pkg` to `"<root_project>/..."`.

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

`gekko shim init` generates `gleam.toml`, `gekko.toml` (with `[shim]` and `[patch."<pkg>:<mod>"]`), and `patches/<mod>.mbt` containing typed `abort("todo")` stubs matching upstream's exact lowered MoonBit signatures.

---

## Upgradability & Maintainability Best Practices

1. **Override at the right boundary:**
   - For libraries with a small, stable `@external` leaf layer, patch the leaf `@external` functions so you inherit all upstream pure-Gleam logic and bugfixes automatically.
   - For libraries wrapping churning Erlang/JS internals behind a stable public API, patch at the **public SemVer API**—`gekko` automatically prunes unreachable private `@external` helpers.
2. **Rely on MoonBit's type checker:** `gekko` emits `__gekko_sigcheck_<fn>` wrappers from upstream's `gleam export package-interface`. If an upstream upgrade changes a parameter, return type, or error variant, `moon check` catches it immediately at compile time.
3. **Heed stale-override and version warnings:** When an upstream upgrade renames or removes an overridden function, type, or module, `gekko` warns about the unmatched key so dead shim code doesn't accumulate silently.
4. **Test against upstream's test suite in CI:** Run `gekko test` against the upstream package's tests in your shim repository's CI so upstream upgrades are a version bump + `gekko test`.
