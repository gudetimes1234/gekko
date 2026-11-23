# Gleam-to-MoonBit Syntax & AST Map (`glance v7.0.0`)

This document maps every public AST node and variant in `glance` (`build/packages/glance/src/glance.gleam`) to its `gekko` lowering and MoonBit emission strategy. Because `gekko` pattern-matches exhaustively on `glance` types in Gleam, any new syntax variant introduced by upstream `glance` upgrades will be flagged at compile time.

---

## 1. Top-Level `Module` & `Definition`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `Module(imports, custom_types, type_aliases, constants, functions)` | Parsed `.gleam` module | Mapped to a dedicated MoonBit package directory (`<out_dir>/<pkg_dir>/`, collision-disambiguated) with `moon.pkg` and `.mbt` files. |
| `Definition(attributes, definition)` | Annotated top-level item | Attributes inspected for `@external(erlang/javascript, ...)` and `@deprecated(...)`. Raw `@external(moonbit, ...)` is extracted by `prepass.gleam` before `glance`. |
| `Attribute(name, arguments)` | Module/item attribute (`@external`, `@deprecated`, `@internal`) | `@external` resolved against `prepass`, `gekko.toml`, or built-in FFI registries; `@deprecated` maps to `#deprecated(...)`. |
| `Publicity` (`Public` / `Private`) | Visibility modifier | `Public` $\rightarrow$ `pub`; `Private` $\rightarrow$ `priv` (or omitted). |

---

## 2. `Import` & `UnqualifiedImport`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `Import(location, module, alias, unqualified_types, unqualified_values)` | `import a/b.{...} as c` | Added to `moon.pkg` `import { "<root>/a/b" as @alias }`. Unqualified names resolved in `symbol_table.gleam` and qualified with `@alias.name` (or aliased in MoonBit). |
| `UnqualifiedImport(name, alias)` | `{foo as bar}` / `{type T as U}` | Tracked in `ModuleSymbols` so bare calls/types resolve to their originating MoonBit package alias. |

---

## 3. `CustomType`, `Variant`, `VariantField`, `TypeAlias`, `Constant`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `CustomType(location, name, publicity, opaque_, parameters, variants)` | `type` / `opaque type` | Always emitted as `pub(all) enum` (or `pub enum` / `priv enum` depending on publicity/opacity) with `#derive(Eq, Debug, Hash)` when `has_function_field == False`. Generics converted to `UpperCamelCase`. |
| `Variant(name, fields, attributes)` | Variant constructor | Emitted as MoonBit enum constructor `Variant(FieldType, ...)` or `Variant(label~ : FieldType, ...)`. |
| `VariantField`: `LabelledVariantField(item, label)` / `UnlabelledVariantField(item)` | Variant payload field | Labeled fields emit `label~ : Type` and generate uniform `pub fn TypeName::label(self : TypeName) -> FieldType` getters when shared across all variants (or single-variant). |
| `TypeAlias(location, name, publicity, parameters, aliased)` | `type Alias(a) = ...` | Emitted as MoonBit `pub type Alias[A] = ...` (or expanded during signature resolution via `package-interface`). |
| `Constant(location, name, publicity, annotation, value)` | `const x = ...` | Emitted as MoonBit `pub let x : Type = ...` (or `priv let` / `const` for primitives). |

---

## 4. `Function`, `FunctionParameter`, `FnParameter`, `AssignmentName`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `Function(location, name, publicity, parameters, return, body)` | Top-level `fn` / `pub fn` | Parameter & return types resolved from Shadow `pub` `package-interface`. Self-tail-recursive functions lowered to functional `for` loops. Bodyless/FFI functions emit MoonBit package wrappers or Wasm imports. |
| `FunctionParameter(label, name, type_)` | Named/labeled function parameter | Labeled params emit `label~ : Type`; unlabelled emit `name : Type`. |
| `FnParameter(name, type_)` | Anonymous `fn(...)` parameter | Emitted as MoonBit closure parameter `(x) => ...` or `fn(x) { ... }`. |
| `AssignmentName`: `Named(String)` / `Discarded(String)` | Variable or `_discard` name | `Named(s)` mangled if keyword; `Discarded(_)` emitted as `_`. |

---

## 5. `Statement`, `AssignmentKind`, `UsePattern`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `Use(location, patterns, function)` | `use a, b <- call(...)` | Folded right-to-left in `desugar.gleam` wrapping trailing statements into `Fn(patterns, None, remaining_stmts)` appended to `function`. |
| `Assignment(location, kind: Let, pattern, annotation, value)` | `let pat = expr` | Simple name/discard $\rightarrow$ `let pat = expr`; destructuring pattern $\rightarrow$ `let pat = expr` (tuple/enum) or `guard expr is pat else { abort(...) }` when irrefutable pattern differs in MoonBit. |
| `Assignment(location, kind: LetAssert(message), pattern, annotation, value)` | `let assert pat = expr` | Lowered to `guard expr is pat else { abort(msg) }` using `message` or file/span location. |
| `Assert(location, expression, message)` | `assert cond` / `assert cond as msg` | Lowered to `if !(cond) { abort(msg) }`. |
| `Expression(Expression)` | Expression statement | Emitted directly (`ignore(...)` if non-final expression produces non-`Unit` value). |
| `UsePattern(pattern, annotation)` | Pattern in `use` header | Converted to `FnParameter` / destructured inside generated closure body. |

---

## 6. `Expression`, `Clause`, `Field`, `RecordUpdateField`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `Int(location, value)` | Integer literal (`42`, `0xFF`, `1_000`) | Emitted as `Int64` literal (`42L`, `0xFFL`, `1_000L`). |
| `Float(location, value)` | Float literal (`3.14`) | Emitted as `Double` literal (`3.14`). |
| `String(location, value)` | String literal (`"hi"`) | Escaped MoonBit `String` literal. |
| `Variable(location, name)` | Identifier or constructor | Resolved against local scope, unqualified imports, module constructors, and keyword mangling. |
| `NegateInt(location, value)` | `-x` | Emitted as `-(x)` on `Int64`. |
| `NegateBool(location, value)` | `!x` | Emitted as `!(x)` on `Bool`. |
| `Block(location, statements)` | `{ ... }` | Emitted as MoonBit block `{ ... }` after `use` desugaring. |
| `Panic(location, message)` | `panic` / `panic as msg` | Emitted as `abort(msg)` (default `"panic"`). |
| `Todo(location, message)` | `todo` / `todo as msg` | Emitted as `abort(msg)` (default `"not yet implemented"`). |
| `Tuple(location, elements)` | `#(a, b, c)` | Emitted as `(a, b, c)`. |
| `List(location, elements, rest)` | `[]`, `[a, b]`, `[a, ..t]` | Emitted as `@prelude.GList`: `Nil`, `Cons(a, Cons(b, tail))`. |
| `Fn(location, arguments, return_annotation, body)` | `fn(a) { ... }` | Emitted as MoonBit anonymous function `fn(a) { ... }`. |
| `RecordUpdate(location, module, constructor, record, fields)` | `User(..u, age: 30)` | Lowered via Symbol Table variant field list into `match u { User(id~, name~, age~) => User(id~, name~, age=30L) ... }`. |
| `FieldAccess(location, container, label)` | `mod.fn` or `rec.field` | If `container` is a module alias in scope, emits `@alias.label`; otherwise emits `container.label()` (Uniform Getter Rule). |
| `Call(location, function, arguments)` | `f(a, b: c)` | Emitted as `f(a, b=c)` (with pipeline/capture lowering and constructor normalization). |
| `TupleIndex(location, tuple, index)` | `t.0` | Emitted directly as `t.0`. |
| `FnCapture(location, label, function, arguments_before, arguments_after)` | `f(a, _, c)` | Desugared to `fn(__capture_1) { f(a, __capture_1, c) }`. |
| `BitString(location, segments)` | `<<...>>` | `@gprelude.BitArray` constructor calls supporting byte-aligned segments and arbitrary bit-offset/bit-width packing. |
| `Case(location, subjects, clauses)` | `case a, b { ... }` | Emitted as `match (a, b) { ... }` (or `match a { ... }` for single subject) with `if` guards (`match x { pat if cond => body }`). |
| `BinaryOperator(location, name, left, right)` | Binary operators | See Section 9 below (`Pipe` desugared in Pass 3). |
| `Echo(location, expression, message)` | `echo expr` / `echo expr as msg` | Lowered to `@prelude.echo(expr, msg)` (inspects/prints and returns `expr`). |
| `Clause(patterns, guard, body)` | `p1, p2 \| q1, q2 if g -> body` | Multi-pattern alternatives expand or emit MoonBit `\|` patterns; multi-subject wraps patterns in `(p1, p2)`. |
| `Field`: `LabelledField` / `ShorthandField` / `UnlabelledField` | `x: val`, `x:`, `val` | `ShorthandField(x)` desugared to `LabelledField(x, Variable(x))` $\rightarrow$ `x=x`. |
| `RecordUpdateField(label, item)` | `field: val` or `field:` | `None` item desugared to `Variable(label)` (shorthand update). |

---

## 7. `Pattern`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `PatternInt(location, value)` | `42` | `42L`. |
| `PatternFloat(location, value)` | `3.14` | `3.14`. |
| `PatternString(location, value)` | `"abc"` | `"abc"`. |
| `PatternDiscard(location, name)` | `_` / `_unused` | `_`. |
| `PatternVariable(location, name)` | `x` | Mangled variable binding `x`. |
| `PatternTuple(location, elements)` | `#(a, b)` | `(a, b)`. |
| `PatternList(location, elements, tail)` | `[]`, `[x]`, `[x, ..rest]` | Lowered to nested `@prelude.GList` patterns: `Nil`, `Cons(x, Nil)`, `Cons(x, rest)`. |
| `PatternAssignment(location, pattern, name)` | `Pat as x` | Emitted as MoonBit `Pat as x`. |
| `PatternConcatenate(location, prefix, prefix_name, rest_name)` | `"pre" <> rest` / `"pre" as p <> rest` | Lowered in `pattern.gleam` to guard/branch using `has_prefix` + substring slice (binding `prefix_name` and `rest_name` when named). |
| `PatternBitString(location, segments)` | `<<...>>` | Lowered in `bit_pattern.gleam` via byte-aligned `Bytes` / `BitArray` matchers and arbitrary bit extractors. |
| `PatternVariant(location, module, constructor, arguments, with_spread)` | `Ok(x)`, `User(name:, ..)` | Emitted as `Ok(x)` / `@mod.User(name~, ..)`; `with_spread == True` appends `, ..` in MoonBit. |

---

## 8. `Type`

| `glance` Type / Variant | Meaning | `gekko` Handling / MoonBit Target |
| --- | --- | --- |
| `NamedType(location, name, module, parameters)` | `Int`, `List(a)`, `mod.T` | Built-ins mapped (`Int` $\rightarrow$ `Int64`, `Float` $\rightarrow$ `Double`, `String` $\rightarrow$ `String`, `Bool` $\rightarrow$ `Bool`, `Nil` $\rightarrow$ `Unit`, `List` $\rightarrow$ `@prelude.GList`, `Result` $\rightarrow$ `Result`, `BitArray` $\rightarrow$ `@prelude.BitArray`, `Dynamic` $\rightarrow$ `@prelude.Dynamic`); others qualified with `@mod.Name[Params]`. |
| `TupleType(location, elements)` | `#(A, B)` | `(A, B)`. |
| `FunctionType(location, parameters, return)` | `fn(A, B) -> C` | `(A, B) -> C`. |
| `VariableType(location, name)` | `a`, `item` | Capitalized `UpperCamelCase` (`A`, `Item`). |
| `HoleType(location, name)` | `_` in type annotation | Replaced by HM-resolved type from `package-interface` (or `_` where MoonBit supports partial inference). |

---

## 9. `BinaryOperator`

| `glance` Variant | Gleam | MoonBit Target |
| --- | --- | --- |
| `And` / `Or` | `&&` / `\|\|` | `&&` / `\|\|` |
| `Eq` / `NotEq` | `==` / `!=` | `==` / `!=` |
| `LtInt` / `LtEqInt` / `GtInt` / `GtEqInt` | `<` / `<=` / `>` / `>=` | `<` / `<=` / `>` / `>=` (on `Int64`) |
| `LtFloat` / `LtEqFloat` / `GtFloat` / `GtEqFloat` | `<.` / `<=.` / `>.` / `>=.` | `<` / `<=` / `>` / `>=` (on `Double`) |
| `Pipe` | `\|>` | Desugared in `desugar.gleam` (arity-aware insertion or closure call) |
| `AddInt` / `SubInt` / `MultInt` | `+` / `-` / `*` | `+` / `-` / `*` (on `Int64`) |
| `DivInt` / `RemainderInt` | `/` / `%` | `@prelude.int_div(a, b)` / `@prelude.int_rem(a, b)` (returns `0L` on `b == 0L`) |
| `AddFloat` / `SubFloat` / `MultFloat` | `+.` / `-.` / `*.` | `+` / `-` / `*` (on `Double`) |
| `DivFloat` | `/.` | `@prelude.float_div(a, b)` (returns `0.0` on `b == 0.0`) |
| `Concatenate` | `<>` | `+` (on `String`) |

---

## 10. `BitStringSegmentOption`, `BitArraySize`, `BitArraySizeOperator`

| `glance` Variant | Meaning | `gekko` Strategy |
| --- | --- | --- |
| `BytesOption`, `BitsOption` | `:bytes`, `:bits` | Tier 1 (`BytesOption` / byte-aligned); Tier 2 (`BitsOption` arbitrary bit length). |
| `IntOption`, `FloatOption` | `:int`, `:float` | Integer/IEEE-754 float segment packing/unpacking. |
| `Utf8Option`, `Utf16Option`, `Utf32Option` | `:utf8`, `:utf16`, `:utf32` | String UTF encoding/decoding (`Utf8Option` in Tier 1; UTF-16/32 in Tier 2). |
| `Utf8CodepointOption`, `Utf16CodepointOption`, `Utf32CodepointOption` | `:utf8_codepoint`, etc. | Codepoint encoding/decoding via `Int64` / `Char`. |
| `SignedOption`, `UnsignedOption` | `:signed`, `:unsigned` | Sign extension on read. |
| `BigOption`, `LittleOption`, `NativeOption` | `:big`, `:little`, `:native` | Endianness control (default `:big` per Gleam spec). |
| `SizeOption(Int)`, `SizeValueOption(t)`, `UnitOption(Int)` | `size(8)`, `size(n)`, `unit(8)` | Bit length computation (`size * unit`); `BitArraySize` expressions (`+`, `-`, `*`, `/`, `%`, literals, variables) lowered to MoonBit `Int64` expressions. |
