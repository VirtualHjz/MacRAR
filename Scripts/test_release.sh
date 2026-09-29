#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
RAR_TOOL="${RAR_PATH:-}"
if [[ -z "$RAR_TOOL" ]] && command -v rar >/dev/null 2>&1; then
    RAR_TOOL="$(command -v rar)"
elif [[ -z "$RAR_TOOL" ]] && [[ -x "$ROOT_DIR/ThirdParty/rar/rar" ]]; then
    RAR_TOOL="$ROOT_DIR/ThirdParty/rar/rar"
fi
FIXTURE_DIR=""
LOG_FILE="$(mktemp)"
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

test -x "$ROOT_DIR/Sources/MacRAR/Resources/bin/7za" || { echo "7za tool unavailable" >&2; exit 1; }

if [[ -n "$RAR_TOOL" && -x "$RAR_TOOL" ]]; then
    export RAR_PATH="$RAR_TOOL"
    FIXTURE_DIR="$(mktemp -d)"
    export MACRAR_RAR_FIXTURE_DIR="$FIXTURE_DIR"
    mkdir -p "$FIXTURE_DIR/src/sub"
    printf '普通文件内容 hello rar\n' > "$FIXTURE_DIR/src/a.txt"
    printf '中文文件名内容\n' > "$FIXTURE_DIR/src/中文 文档.txt"
    dd if=/dev/urandom of="$FIXTURE_DIR/src/sub/big.bin" bs=500000 count=1 status=none
    (
        cd "$FIXTURE_DIR"
        "$RAR_TOOL" a -idq -r test_normal.rar src >/dev/null
        "$RAR_TOOL" a -idq -r -p123456 test_pwd.rar src >/dev/null
        "$RAR_TOOL" a -idq -r -hp123456 test_hp.rar src >/dev/null
        "$RAR_TOOL" a -idq -r -s test_solid.rar src >/dev/null
        "$RAR_TOOL" a -idq -r -v100k test_vol.rar src >/dev/null
        "$RAR_TOOL" a -idq -r -rr5% test_rr.rar src >/dev/null
    )
else
    echo "RAR CLI not installed; external RAR creation fixtures will be skipped."
fi

swift build -c release --product EngineTest
ENGINE_TEST="$(swift build -c release --show-bin-path)/EngineTest"
set +e
"$ENGINE_TEST" 2>&1 | tee "$LOG_FILE"
RESULT=${PIPESTATUS[0]}
set -e
if [[ "$RESULT" -ne 0 ]] || grep -q '✗' "$LOG_FILE"; then
    echo "Engine tests failed (exit $RESULT); see the failures above." >&2
    exit 1
fi
echo "All engine test checks passed."
