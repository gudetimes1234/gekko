# `gleam_tour` Example

A complete, runnable translation of the official Gleam Language Tour compiled through `gekko` to MoonBit.

## What It Demonstrates

- **Basics (`src/tour/basics.gleam`):** 64-bit integers (`Int64`), floats (`Double`), booleans, strings, assignments, and blocks.
- **Functions (`src/tour/functions.gleam`):** Higher-order functions, generics, anonymous closures, captures, and pipelines (`|>`).
- **Flow Control (`src/tour/flow_control.gleam`):** `case` pattern matching, guards, list/tuple destructuring, and tail-recursive loops (lowered by `gekko` to MoonBit functional `for` loops).
- **Data Types (`src/tour/data_types.gleam`):** Custom types, multi-variant enums, uniform field accessors, immutable record updates (`Type(..val, field: new)`), and opaque types (`Positive`).
- **Standard Library & Advanced Features (`src/tour/stdlib_and_advanced.gleam`):** `gleam/list`, `gleam/dict`, `gleam/option`, `gleam/result`, `use` expressions, `let assert`, `assert`, `echo` (with `<file>:<line>` stderr formatting), and `string.inspect`.

## Project Layout

```text
examples/gleam_tour/
├── gleam.toml                       # Declares gleam_stdlib and gleam_json dependencies
└── src/
    ├── gleam_tour.gleam             # Entrypoint (`main`) and opaque type checks
    └── tour/
        ├── basics.gleam
        ├── data_types.gleam
        ├── flow_control.gleam
        ├── functions.gleam
        └── stdlib_and_advanced.gleam
```

## How It Was Created

No FFI, adapters, or code generation steps were required. This is a pure Gleam project written with standard `gleam` conventions and `gleam.toml` Hex dependencies; `gekko` transpiles both the modules under `src/` and the resolved dependencies under `build/packages/` directly into a MoonBit workspace.

## How to Run

First ensure Hex dependencies (`gleam_stdlib`, `gleam_json`) are present (run inside `examples/gleam_tour` once if needed):

```bash
cd examples/gleam_tour
gleam deps download
cd ../..
```

Then type-check and run via `gekko`:

```bash
# Type-check the transpiled MoonBit workspace
gleam run -m gekko -- check --root examples/gleam_tour

# Run targeting linear-memory WebAssembly or JavaScript
gleam run -m gekko -- run --root examples/gleam_tour --target wasm
gleam run -m gekko -- run --root examples/gleam_tour --target js
```
