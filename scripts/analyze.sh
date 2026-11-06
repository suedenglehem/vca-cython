#!/usr/bin/env bash
# Single-file analysis via the vca CLI: every `vca analyze` option is exposed
# as an argument; results (JSON + TXT by default) are written under --out and
# the produced file paths are printed at the end. Exit code is vca's exit code.
#
#   scripts/analyze.sh INPUT [options]
#   scripts/analyze.sh /path/to/broadcast.ts --mode header --rank-by structural
#   scripts/analyze.sh /path/to/capture.ts --mode header --ts-continuity warn --out /tmp/out
#
#   Env: VCA_GPU=<n>   choose the GPU (nvidia-smi index) for GPU operations —
#                      e.g. `vca benchmark-decode --decoder av1_cuvid` picks
#                      this GPU (equivalent to --device <n>; the CUDA ordinal
#                      is resolved automatically). Inherited by the vca process.
#                      VCA_BIN=<path>  choose the vca binary (see --bin).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage: scripts/analyze.sh INPUT [options]

  --mode fast|header|deep|auto   analysis mode (default: auto)
  --stream SPEC                  video stream: index, or program ordinal "2:v:0"
  --program ID                   select video stream by program id
  --bin-seconds SEC              bin width in seconds (default: 1.0)
  --format LIST                  comma list of txt,csv,json,html (default: json,txt)
  --frames                       also write per-frame records (frames.csv)
  --ts-continuity require|warn|off   MPEG-TS continuity gate (default: require)
  --ts-continuity-timeout SEC    gate scan timeout
  --ts-continuity-max-errors N   gate error budget (require policy)
  --out DIR                      output directory (default: reports/cli/<stamp>-<name>)
  --overwrite                    replace existing output dir contents
  --force                        implies --overwrite; continue past failures
  --keep-temp                    keep temp files (debugging)
  --timestamp-policy repair|report|strict
  --rank-by auto|compressed|structural|composite|decode   interval ranking basis
  --window-seconds SEC           top-interval window (default: 5.0)
  --recursive                    INPUT is a directory: descend into it
  --config FILE                  config file (scores, weights, ...)
  --log-level LEVEL              debug|info|warning|error
  --bin PATH                     vca binary (default: vca on PATH — install the
                                 wheel: pip install wheel/vco-*.whl; VCA_BIN env also works)
  (env) VCA_GPU=<n>              GPU (nvidia-smi index) for GPU operations;
                                 inherited by vca, e.g. for benchmark-decode
  -h, --help                     this help

Results land in <out>/data.json (full metrics), <out>/report.txt (summary),
plus report.csv / report.html when requested. Exit code = vca's exit code
(0 ok, 2 input/config error, 3 analysis failure).
EOF
}

BIN=${VCA_BIN:-}
pick_bin() {
  [ -n "$BIN" ] && return 0
  if command -v vca >/dev/null; then BIN=vca
  else echo "no vca binary found — install the wheel (pip install wheel/vco-*.whl, see README) or pass --bin PATH" >&2; exit 2
  fi
}

INPUT=""
MODE=auto
FORMAT="json,txt"
OUT=""
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --bin) BIN=$2; shift 2 ;;
    --mode|--stream|--program|--bin-seconds|--format|--ts-continuity|\
    --ts-continuity-timeout|--ts-continuity-max-errors|--out|--timestamp-policy|\
    --rank-by|--window-seconds|--config|--log-level)
      [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      case "$1" in --out) OUT=$2 ;; --format) FORMAT=$2 ;; --mode) MODE=$2 ;; esac
      EXTRA+=("$1" "$2"); shift 2 ;;
    --frames|--overwrite|--force|--keep-temp|--recursive)
      EXTRA+=("$1"); shift ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *)
      [ -n "$INPUT" ] && { echo "one INPUT file per run (got: $INPUT and $1)" >&2; exit 2; }
      INPUT=$1; shift ;;
  esac
done

[ -n "$INPUT" ] || { usage; exit 2; }
[ -e "$INPUT" ] || { echo "input not found: $INPUT" >&2; exit 2; }
pick_bin

if [ -z "$OUT" ]; then
  OUT="reports/cli/$(date +%Y%m%d-%H%M%S)-$(basename "${INPUT%.*}")"
  EXTRA+=(--out "$OUT")
else
  EXTRA+=(--out "$OUT")
fi
EXTRA+=(--format "$FORMAT" --mode "$MODE")

echo "== $BIN analyze $INPUT  [mode=$MODE format=$FORMAT out=$OUT]"
set +e
"$BIN" analyze "$INPUT" "${EXTRA[@]}"
RC=$?
set -e

echo "== exit $RC"
if [ -d "$OUT" ]; then
  echo "== results:"
  find "$OUT" -maxdepth 2 -type f \( -name '*.json' -o -name '*.txt' -o -name '*.csv' \
    -o -name '*.html' \) | sort | sed 's/^/   /'
fi
exit $RC
