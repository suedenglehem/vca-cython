#!/usr/bin/env bash
# Web UI container control: start/stop/restart/status/logs for the Dockerized
# vca serve. Runs the boris271142/vca:latest image with two host mounts the
# Config tab maps folders inside: input (read-only, /mnt/host) and output
# (writable, /mnt/out — computed scores land there as <basename>.<ext>.score).
# Reports (job artifacts) stay under reports/docker-graph. All knobs are
# env-overridable.
#
#   scripts/web.sh [start|stop|restart|status|logs] [--input folder1] [--output folder2]
#   scripts/web.sh start --input ~/vca-media --output ~/vca-scores
#   VCA_PORT=8082 VCA_HOST_DIR=~/media scripts/web.sh start
#
#   VCA_GPU=<n>  expose nvidia-smi GPU <n> to the container, via
#                CUDA_VISIBLE_DEVICES=<uuid of n> on docker run (resolved at
#                start: numeric CVD values are CUDA ordinals, not nvidia-smi
#                indexes). Inside the container it appears as GPU 0, so the CLI
#                inside and the web's GPU operations use device 0; the Config
#                tab shows the detected name ("GPU used: …"). Default: no GPU.
#   scripts/web.sh restart  (VCA_GPU is carried through restart)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME=${VCA_NAME:-vca-web}
PORT=${VCA_PORT:-9081}
IMAGE=${VCA_IMAGE:-boris271142/vca:latest}
HOST_DIR=${VCA_HOST_DIR:-$HOME/vca-media}
OUT_DIR=${VCA_OUT_DIR:-$ROOT/reports/docker-scores}
REPORTS_DIR=${VCA_REPORTS_DIR:-$ROOT/reports/docker-graph}

cmd=start
while [ $# -gt 0 ]; do
  case "$1" in
    --input) [ $# -ge 2 ] || { echo "--input needs a folder" >&2; exit 2; }
             HOST_DIR=$2; shift 2 ;;
    --output) [ $# -ge 2 ] || { echo "--output needs a folder" >&2; exit 2; }
             OUT_DIR=$2; shift 2 ;;
    start|stop|restart|status|logs) cmd=$1; shift ;;
    *) echo "usage: $0 [start|stop|restart|status|logs] [--input folder1] [--output folder2]" >&2
       exit 2 ;;
  esac
done

case "$cmd" in
  start)
    if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      echo "already running: $NAME (port $PORT) — 'scripts/web.sh restart' to reload a rebuilt image"
      exit 0
    fi
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
      echo "image not found: $IMAGE — pull it first: docker pull $IMAGE (or run ./setup.sh)" >&2
      exit 1
    fi
    [ -d "$HOST_DIR" ] || { echo "input dir missing: $HOST_DIR" >&2; exit 1; }
    mkdir -p "$OUT_DIR" "$REPORTS_DIR"
    GPU_ARGS=()
    if [ -n "${VCA_GPU:-}" ]; then
      case "$VCA_GPU" in
        (*[!0-9]*|'') echo "VCA_GPU must be a non-negative integer (nvidia-smi index)" >&2; exit 2 ;;
      esac
      CVD="$VCA_GPU"
      if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -i "$VCA_GPU" --query-gpu=index,name --format=csv,noheader >/dev/null 2>&1 \
          || { echo "nvidia-smi: GPU $VCA_GPU not found" >&2; exit 1; }
        # Pin by UUID, not by number: a numeric CUDA_VISIBLE_DEVICES value is
        # a CUDA ORDINAL, which does not follow nvidia-smi numbering on hosts
        # without CUDA_DEVICE_ORDER (FASTEST_FIRST — on a 3090/3080Ti/3090
        # box, CVD=1 is a 3090, not the 3080 Ti). The UUID keeps VCA_GPU's
        # documented meaning (nvidia-smi index) unambiguous for CUDA, for
        # nvidia-smi -i, and for the web's "GPU used" display.
        CVD=$(nvidia-smi -i "$VCA_GPU" --query-gpu=uuid --format=csv,noheader) \
          || { echo "nvidia-smi: could not resolve the UUID of GPU $VCA_GPU" >&2; exit 1; }
      fi
      # All GPU device nodes are exposed; CUDA_VISIBLE_DEVICES pins the one
      # we want, renumbered to index 0 inside the container.
      GPU_ARGS=(--gpus all -e CUDA_VISIBLE_DEVICES="$CVD")
    fi
    docker run --rm -d --name "$NAME" \
      -p "$PORT:8666" \
      "${GPU_ARGS[@]}" \
      -v "$HOST_DIR:/mnt/host:ro" \
      -v "$OUT_DIR:/mnt/out" \
      -v "$REPORTS_DIR:/reports" \
      -u "$(id -u):$(id -g)" \
      -e VCA_HOST_INPUT_ROOT="$HOST_DIR" \
      -e VCA_HOST_OUTPUT_ROOT="$OUT_DIR" \
      "$IMAGE" --input-dir /mnt/host --output-dir /mnt/out >/dev/null
    echo "started: $NAME  http://localhost:$PORT/  (image $IMAGE)"
    echo "  input root:  $HOST_DIR -> /mnt/host (read-only)"
    echo "  output root: $OUT_DIR -> /mnt/out (scores: <name>.<ext>.score)"
    echo "  reports:     $REPORTS_DIR -> /reports"
    [ -n "${VCA_GPU:-}" ] && echo "  gpu:         nvidia-smi GPU $VCA_GPU ($CVD; index 0 inside the container)"
    ;;
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 \
      && echo "stopped: $NAME" \
      || echo "not running: $NAME"
    ;;
  restart)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    exec env VCA_HOST_DIR="$HOST_DIR" VCA_OUT_DIR="$OUT_DIR" \
      VCA_PORT="$PORT" VCA_IMAGE="$IMAGE" VCA_NAME="$NAME" \
      ${VCA_GPU:+VCA_GPU="$VCA_GPU"} "$0" start
    ;;
  status)
    if docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -q "^$NAME"; then
      docker ps --filter "name=$NAME" --format '{{.Status}}  {{.Ports}}'
      # 127.0.0.1, not localhost: on hosts where localhost resolves to ::1
      # first, the docker-proxy resets the IPv6 connection.
      curl -fsS -o /dev/null "http://127.0.0.1:$PORT/health" \
        && echo "health: ok  http://localhost:$PORT/" \
        || echo "health: container up, endpoint not answering yet"
    else
      echo "not running: $NAME"
      exit 1
    fi
    ;;
  logs)
    docker logs --tail "${VCA_LOGS:-100}" "$NAME"
    ;;
  *)
    echo "usage: $0 [start|stop|restart|status|logs]" >&2
    exit 2
    ;;
esac
