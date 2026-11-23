#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOON_PKG="$ROOT/runtime/prelude/moon.pkg"
GPRELUDE_MBT="$ROOT/runtime/prelude/gprelude.mbt"
OUT_GLEAM="$ROOT/src/emit/prelude_runtime.gleam"

python3 - "$MOON_PKG" "$GPRELUDE_MBT" "$OUT_GLEAM" <<'PY'
import sys

moon_pkg_path, gprelude_path, out_path = sys.argv[1:4]

def gleam_escape(line: str) -> str:
    return (
        line.replace("\\", "\\\\")
            .replace('"', '\\"')
    )

def format_string_fn(doc: str, fn_name: str, content: str) -> list[str]:
    lines = content.splitlines(keepends=True)
    out = [f"/// {doc}", f"pub fn {fn_name}() -> String {{"]
    for i, line in enumerate(lines):
        has_nl = line.endswith("\n")
        body = line[:-1] if has_nl else line
        escaped = gleam_escape(body) + ("\\n" if has_nl else "")
        prefix = "  " if i == 0 else "  <> "
        out.append(f'{prefix}"{escaped}"')
    if not lines:
        out.append('  ""')
    out.append("}")
    return out

with open(moon_pkg_path, "r", encoding="utf-8") as f:
    moon_pkg_src = f.read()

with open(gprelude_path, "r", encoding="utf-8") as f:
    gprelude_src = f.read()

out_lines = []
out_lines.extend(format_string_fn(
    "Returns the `moon.pkg` contents for the bundled `gprelude` runtime package.",
    "moon_pkg",
    moon_pkg_src,
))
out_lines.append("")
out_lines.extend(format_string_fn(
    "Returns the `gprelude.mbt` runtime source matching `runtime/prelude/gprelude.mbt`.",
    "gprelude_mbt",
    gprelude_src,
))

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(out_lines) + "\n")
PY

gleam format "$OUT_GLEAM"
