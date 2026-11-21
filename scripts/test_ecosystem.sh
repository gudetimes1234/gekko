#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Building gekko shipment ==="
(cd "$ROOT" && gleam export erlang-shipment)

mkdir -p "$TMP_DIR/bin"
GEKKO_BIN="$TMP_DIR/bin/gekko"
cat > "$GEKKO_BIN" <<EOF
#!/usr/bin/env bash
exec "$ROOT/build/erlang-shipment/entrypoint.sh" run "\$@"
EOF
chmod +x "$GEKKO_BIN"

resolve_repo() {
  local env_dir="$1"
  local https_url="$2"
  local ref="$3"
  local dest="$4"
  if [ -n "$env_dir" ]; then
    (cd "$env_dir" && pwd)
  else
    git clone --depth 1 --branch "$ref" "$https_url" "$dest" >/dev/null 2>&1
    echo "$dest"
  fi
}

STDLIB_DIR="$(resolve_repo "${GEKKO_STDLIB_DIR:-}" "https://github.com/spiral-nights/gekko_gleam_stdlib.git" "${GEKKO_STDLIB_REF:-main}" "$TMP_DIR/repos/gekko_gleam_stdlib")"
JSON_DIR="$(resolve_repo "${GEKKO_JSON_DIR:-}" "https://github.com/spiral-nights/gekko_gleam_json.git" "${GEKKO_JSON_REF:-main}" "$TMP_DIR/repos/gekko_gleam_json")"
EXAMPLES_DIR="$(resolve_repo "${GEKKO_EXAMPLES_DIR:-}" "https://github.com/spiral-nights/gekko_examples.git" "${GEKKO_EXAMPLES_REF:-main}" "$TMP_DIR/repos/gekko_examples")"

echo "=== Running gekko_gleam_stdlib tests ==="
GEKKO="$GEKKO_BIN" "$STDLIB_DIR/scripts/test_moonbit.sh"

echo "=== Running gekko_gleam_json tests ==="
GEKKO="$GEKKO_BIN" GEKKO_STDLIB_DIR="$STDLIB_DIR" "$JSON_DIR/scripts/test_moonbit.sh"

echo "=== Running gekko_examples tests ==="
GEKKO="$GEKKO_BIN" "$EXAMPLES_DIR/scripts/test_all.sh"

echo "All gekko ecosystem checks passed."
