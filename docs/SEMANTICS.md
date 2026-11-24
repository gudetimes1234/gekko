# `gekko` Runtime Semantics & Gleam Compatibility

This document summarizes how Gleam language constructs behave when compiled to MoonBit via `gekko`, including guaranteed semantics and known differences compared to Gleam's official Erlang and JavaScript targets.

---

## Summary Compatibility Matrix

| Feature | Gleam (Erlang) | Gleam (JavaScript) | `gekko` (MoonBit: `wasm`, `wasm-gc`, `js`, `native`) |
| --- | --- | --- | --- |
| `Int` representation | Arbitrary-precision integer | IEEE-754 double (`±(2^53 - 1)` safe range) | Signed 64-bit two's-complement `Int64` |
| `Int` overflow (`+`, `-`, `*`, `-x`) | Exact (no overflow) | Loses integer precision past `2^53 - 1` | Wraps modulo `2^64` across all 4 targets |
| `Int` literal range check | Arbitrary precision | Compiler checks / JS precision limits | Compile-time `Int64` range diagnostic (`file:line:col`) |
| `x / 0`, `x % 0` | Returns `0` | Returns `0` | Returns `0` (`@gprelude.int_div` / `@gprelude.int_rem`) |
| `INT64_MIN / -1`, `INT64_MIN % -1` | `2^63`, `0` | Exact (`9223372036854775808` in float), `0` | `-9223372036854775808` (wrapped), `0` (guarded against Wasm trap) |
| `Float` (`x /. 0.0`) | 64-bit IEEE-754 float (`0.0`) | 64-bit IEEE-754 float (`0.0`) | 64-bit `Double` (`0.0` via `@gprelude.float_div`) |
| Custom types & record updates | Immutable algebraic types | Immutable JS objects | Immutable MoonBit `enum`s; updates match + reconstruct with structural sharing |
| `panic`, `todo`, `assert`, `let assert` | Uncatchable runtime exception | Uncatchable JS exception | Uncatchable MoonBit `@prelude.abort(...)` panic |
| Tail-call optimization | Full TCO (including mutual) | Self-recursion only | Self-recursion lowered to `for` loops; mutual TCO not yet lowered |
| `BitArray` capacity | VM heap limits | JS `Uint8Array` limits | Backed by MoonBit `Bytes`; byte indexing narrows to 32-bit `Int` (~2 GiB limit) |

---

## 1. Integers (`Int` → `Int64`)

### Representation & Why `Int64` Is Used

All Gleam `Int` types, values, literals, patterns, and `BitArray` size expressions lower to MoonBit **`Int64`** (`[-9_223_372_036_854_775_808, 9_223_372_036_854_775_807]`), with an `L` suffix on emitted integer literals.

MoonBit's built-in `Int` type is **32-bit** on current backends (`wasm`, `wasm-gc`, `js`, `native`), which is too narrow for Gleam programs and standard library algorithms (e.g., `gleam/int` bitwise and 64-bit arithmetic). `Int64` provides consistent 64-bit signed behavior across every MoonBit backend—narrower than Erlang's arbitrary-precision integers, and wider than JavaScript's 53-bit safe integer range (`±9,007,199,254,740,991`).

### Arithmetic, Division, Remainder & Overflow

- **Wrapping overflow:** Addition (`+`), subtraction (`-`), multiplication (`*`), and unary negation (`-x`) use two's-complement 64-bit wrapping consistently across `wasm`, `wasm-gc`, `js`, and `native` (for example, `9_223_372_036_854_775_807 + 1 == -9_223_372_036_854_775_808` and `-(-9_223_372_036_854_775_808) == -9_223_372_036_854_775_808`).
- **Truncation toward zero:** `a / b` truncates toward zero and `a % b` preserves the dividend's sign, matching Gleam.
- **Division and remainder by zero or `-1`:** All `/` and `%` operations compile to `@gprelude.int_div(a, b)` and `@gprelude.int_rem(a, b)` (`runtime/prelude/gprelude.mbt`):
  - If `b == 0`, both `int_div` and `int_rem` return `0`.
  - If `b == -1`, `int_div` returns `-a` (which wraps `INT64_MIN / -1` to `-9_223_372_036_854_775_808` across all backends instead of trapping with `divide result unrepresentable` on WebAssembly, whereas Erlang would yield `2^63`) and `int_rem` returns `0`.

### Compile-Time Literal Range Diagnostics

Before emitting MoonBit code, `gekko` checks all active `Int` literals in expressions, constants, `case` patterns, and `BitArray` size/segment specifiers (skipping `@target(javascript)` definitions and Gleam fallback bodies overridden by MoonBit FFI):

- Literals outside signed `Int64` (`-9_223_372_036_854_775_808..9_223_372_036_854_775_807`) fail during transpilation with a Gleam `file:line:col` diagnostic rather than failing later inside `moon check` on generated `.mbt` files.
- Negative boundary literals such as `-9223372036854775808`, `-0x8000_0000_0000_0000`, `-0o1000000000000000000000`, and `-0b1000...0` are accepted across all bases.
- Positive `2^63` literals in any base (including `0x8000_0000_0000_0000`) are rejected, because in Gleam `0x8000_0000_0000_0000` denotes positive `+9_223_372_036_854_775_808` (whereas MoonBit would silently wrap an unsigned-looking hex literal into `-9223372036854775808L`).
- Unary negation written with whitespace or parentheses around a literal (`- 9_223_372_036_854_775_808` or `-(9_223_372_036_854_775_808)`) parses in Gleam as unary minus applied to the positive literal `9_223_372_036_854_775_808`, so write `-9_223_372_036_854_775_808` without a space when targeting the `Int64` minimum value.

---

## 2. Floats (`Float` → `Double`)

Gleam `Float` lowers to MoonBit 64-bit IEEE-754 `Double`. Floating-point division (`/.`) lowers to `@gprelude.float_div(a, b)`, returning `0.0` when `b == 0.0` to match Gleam semantics.

---

## 3. Records, Custom Types & `@external_type`

- **Uniform immutable enums:** Every Gleam custom type lowers to a MoonBit `enum` with synthesized `Type::field` getters for single-variant and multi-variant shared labeled fields.
- **Record updates (`Variant(..r, field: val)`):** Updates lower in `src/lower/desugar.gleam` to a `match` on `r` that binds unchanged fields and constructs a fresh enum value. Because MoonBit `enum` values are immutable, unchanged fields share references to existing nested values (persistent structural sharing, observationally identical to Gleam since pure Gleam values have no reference equality). Multi-variant record updates include a `_ => abort("unreachable record update variant")` arm after type-checking guarantees the active constructor.
- **Trait derivation:** Types receive `#derive(Eq, Debug, Hash)` unless they directly or transitively store function fields. `GleamInspect` handles function fields as `<//fn(...)>` stubs via `@gprelude.inspect_fn`.
- **`@external_type` mutability caveat:** Types declared with `@external_type(moonbit, "pkg", "Type")` alias the underlying MoonBit type directly. If that MoonBit type is a mutable `struct` (such as `Counter` in `gekko_examples/moonbit_ffi`), mutations through MoonBit FFI functions are shared across aliases holding that handle—this is an explicit FFI escape hatch rather than standard Gleam value semantics.

---

## 4. Panics, Assertions & Uncatchable Aborts

Gleam `panic`, `todo`, `assert`, and failing `let assert` patterns lower to MoonBit `@prelude.abort(...)`.

- In MoonBit, `abort` is an uncatchable runtime panic, **not** a catchable `raise` exception (`try { abort(...) } catch { ... }` triggers an `unused_try` warning and still aborts execution).
- This matches Gleam's semantics, where panics cannot be caught or turned into `Result` values.
- Likewise, if a MoonBit FFI function internally calls `abort`, the program terminates rather than returning `Error(...)`.

---

## 5. MoonBit FFI & Exception Bridging

- **Generated bindings (`gekko moonbit bind`):**
  - MoonBit functions declared with `raise` or `raise E` in `.mbti` signatures are bound to Gleam functions returning `Result(T, String)`.
  - Generated adapters wrap raw calls in `try { let __res = ...; Ok(...) } catch { __err => Err(Error::to_string(__err)) }`.
  - **Error erasure:** Typed MoonBit error types (`raise MyError`) are erased to `String` via `Error::to_string(__err)`.
  - **Unsupported signatures:** Functions with polymorphic `raise?` effects, `async` modifiers, or bounded type parameters are skipped by `gekko moonbit bind` with a warning.
- **Hand-written `@external(moonbit, ...)` / `/// @external(moonbit, ...)`:**
  - Raw external declarations emit a direct MoonBit call without automatic `try`/`catch` wrapping. Following Gleam's FFI contract, the author is responsible for ensuring the foreign function does not raise uncaught exceptions directly into Gleam (or for writing a small MoonBit adapter returning `Result[T, E]`).

---

## 6. BitArrays & Byte-Index Narrowing

- Gleam `BitArray` lowers to `@gprelude.BitArray` (`{ data : Bytes, bit_length : Int64 }`), supporting both byte-aligned construction/matching and arbitrary bit-offset/bit-width segments.
- When indexing MoonBit `Bytes` in `runtime/prelude/gprelude.mbt`, byte offsets and lengths are narrowed from `Int64` via `.to_int()` to MoonBit's 32-bit `Int`. Practically, `BitArray` values above ~2 GiB (`2^31 - 1` bytes) are outside supported bounds.

---

## 7. Tail-Call Optimization & Testing

- **Self vs. mutual tail recursion:** Self-tail-recursive functions rewrite to MoonBit functional `for` loops (`src/lower/tco.gleam`), guaranteeing $O(1)$ stack usage on all targets. Mutually recursive tail calls remain ordinary calls (`wasm-gc` supports native tail calls via `return_call`, while linear `wasm` / `js` / `native` are not yet loop-rewritten by `gekko`).
- **`gleam test` vs. `gekko test`:** Standard `gleam test` runs on Erlang or Node/JS and cannot invoke `@external(moonbit, ...)` functions unless an Erlang/JS external or pure-Gleam fallback is provided. Use `gekko test` to transpile and run tests via `moon test`.
- **`gleeunit`:** `gekko test` drops the `gleeunit` runner (and `gleeunit.main()`), since `moon test` runs each `*_test` function itself. `gleeunit/should` is pure Gleam and is transpiled when a test module imports it.

---

## 8. WIT Boundary Semantics (`gekko wit`)

When bridging Gleam modules across the WebAssembly Component Model (`wit-bindgen moonbit` + `emit/wit_bridge.gleam`), boundary values convert between `gekko`'s uniform Gleam types and Canonical ABI MoonBit types:

- **Integers (`s8`/`s16`/`s32`/`s64`, `u8`/`u16`/`u32`/`u64`):** Every WIT integer type maps to Gleam `Int` (`Int64` in MoonBit). Narrower signed/unsigned widths (`s8`–`u32`) widen on import/entry and narrow with `.to_int()` / `.to_byte()` on export/call; `u64` uses bitwise reinterpretation (`.reinterpret_as_int64()` / `.reinterpret_as_uint64()`), so unsigned values $\ge 2^{63}$ appear negative in Gleam `Int` while preserving their exact 64-bit bit pattern.
- **Floats (`f32`/`f64`) & `char`:** `f32` widens to `Double` (`to_double()`) and narrows via `Float::from_double`. WIT `char` converts to/from a single-codepoint Gleam `String`.
- **`list<u8>` & `list<T>`:** `list<u8>` maps to Gleam `BitArray` (`@gprelude.BitArray` ↔ `FixedArray[Byte]`). General `list<T>` maps to `List(T)` (`@gprelude.GList[T]` ↔ `Array[T]`).
- **Imported `resource` (`own<T>` / `borrow<T>`):** Imported WIT resources map to Gleam opaque types (`/// @external_type(moonbit, ...)`). Both `own<T>` and `borrow<T>` pass the underlying handle across the adapter boundary; call the generated `drop_<resource>(handle)` binding when explicitly releasing a handle. Exported WIT resources are not yet supported.
