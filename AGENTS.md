# AGENTS.md

## Project Overview

`gekko` is a Gleam-to-MoonBit transpiler written in Gleam.

## Verification

Run formatting and tests before committing:

```sh
gleam format --check src test
gleam test
```

For optional full-ecosystem regression verification across `gekko_gleam_stdlib`, `gekko_gleam_json`, and `gekko_examples`:

```sh
./scripts/test_ecosystem.sh
```

Override repository locations via `GEKKO_STDLIB_DIR`, `GEKKO_JSON_DIR`, and `GEKKO_EXAMPLES_DIR` (or refs via `GEKKO_STDLIB_REF`, `GEKKO_JSON_REF`, `GEKKO_EXAMPLES_REF`); unset variables clone over HTTPS into a temporary directory.

## Key Conventions & Invariants

- **Prelude sync**: `runtime/prelude/gprelude.mbt` and `src/emit/prelude_runtime.gleam` must remain byte-identical. This is enforced by `prelude_runtime_matches_disk_files_test`.
- **Fixture `gleam.toml` files**: Never modify `fixtures/golden/*/gleam.toml`; they intentionally use local relative paths for parity/golden testing.
- **Temporary test projects**: Never name a temporary Gleam test project `*_test`.
- **Semantics**: Gleam `Int` lowers to MoonBit `Int64`; `panic`, `todo`, and `let assert` lower to MoonBit `abort`. See `docs/SEMANTICS.md` and `docs/SPEC.md` for details.

## Git

- Use conventional commit messages (e.g. `docs: add AGENTS.md`, `feat: ...`, `fix: ...`).
- Do not push unless explicitly asked.
