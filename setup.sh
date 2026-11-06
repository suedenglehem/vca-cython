#!/usr/bin/env bash
# vca setup — first-run installer for the vca web UI from the public image
# boris271142/vca (Docker Hub). Run it from the repo root (install.sh is the
# same entry). No sources needed.
#
#   ./setup.sh                                   # interactive: port, bind, folders, GPU
#   ./setup.sh --yes --port 9081 --bind localhost --input ~/vca-media --output ~/vca-scores --gpu 1
#   ./setup.sh --no-gpu                         # skip GPU
#
# Steps: 1) docker present  2) pull image  3) configure port + bind address +
# input/output/reports folder mappings  4) detect NVIDIA GPU and propose using
# it  5) start the container  6) health-test the startup  7) print the web UI URL.
#
# Container conventions match the image: name vca-web, container port 8666,
# input mounted read-only at /input, reports at /reports, scores at
# /reports/scores (the output folder; scores land as <basename>.<ext>.score).
# Bind: localhost -> loopback only, 0.0.0.0 -> all interfaces, an IP -> that
# interface. GPU pinned by UUID via CUDA_VISIBLE_DEVICES (numeric values are
# CUDA ordinals, not nvidia-smi indexes — the UUID keeps the pin unambiguous).
set -euo pipefail

IMAGE=${VCA_IMAGE:-boris271142/vca:latest}
NAME=${VCA_NAME:-vca-web}
PORT=9081
BIND=localhost          # localhost | 0.0.0.0 | <ip>
INPUT_DIR=$HOME/vca-media
OUTPUT_DIR=$HOME/vca-scores
REPORTS_DIR=${VCA_REPORTS_DIR:-$HOME/vca-reports}
GPU_ANSWER=""          # "" = ask, "yes"/"no" = decided
GPU_INDEX=0            # chosen nvidia-smi index (asked when several GPUs)
GPU_SET=no             # index given explicitly via --gpu N
ASSUME=no

while [ $# -gt 0 ]; do
  case "$1" in
    --port)    [ $# -ge 2 ] || { echo "--port needs a value" >&2; exit 2; }; PORT=$2; shift 2 ;;
    --bind)    [ $# -ge 2 ] || { echo "--bind needs a value (localhost | 0.0.0.0 | <ip>)" >&2; exit 2; }; BIND=$2; shift 2 ;;
    --input)   [ $# -ge 2 ] || { echo "--input needs a folder" >&2; exit 2; }; INPUT_DIR=$2; shift 2 ;;
    --output)  [ $# -ge 2 ] || { echo "--output needs a folder" >&2; exit 2; }; OUTPUT_DIR=$2; shift 2 ;;
    --reports) [ $# -ge 2 ] || { echo "--reports needs a folder" >&2; exit 2; }; REPORTS_DIR=$2; shift 2 ;;
    --gpu)     GPU_ANSWER=yes; case "${2:-}" in (*[!0-9]*|'') ;; (*) GPU_INDEX=$2; GPU_SET=yes; shift ;; esac; shift ;;
    --no-gpu)  GPU_ANSWER=no; shift ;;
    --yes|-y)  ASSUME=yes; shift ;;
    --image)   [ $# -ge 2 ] || { echo "--image needs a value" >&2; exit 2; }; IMAGE=$2; shift 2 ;;
    *) echo "usage: $0 [--port N] [--bind localhost|0.0.0.0|<ip>] [--input DIR] [--output DIR] [--reports DIR] [--gpu [N]|--no-gpu] [--yes] [--image IMG]" >&2
       exit 2 ;;
  esac
done

say()  { printf '\033[1m==> %s\033[0m\n' "$1"; }
fail() { echo "vca setup failed: $1" >&2; exit 1; }

# ask <question> <default> — reads stdin; non-interactive runs take the default.
ask() {
  local q=$1 def=$2 a
  if [ -t 0 ] && [ "$ASSUME" != yes ]; then
    read -r -p "$q [$def]: " a || a=""
    echo "${a:-$def}"
  else
    echo "$def"
  fi
}

# --- 1. docker present -------------------------------------------------------
say "checking Docker"
command -v docker >/dev/null 2>&1 \
  || fail "docker is not installed — install Docker Engine first (https://docs.docker.com/engine/install/) and re-run this installer"
docker info >/dev/null 2>&1 \
  || fail "docker daemon not reachable — start it (systemctl start docker) or add yourself to the docker group, then re-run"
echo "  docker $(docker --version | awk '{print $3}')"

# --- 2. pull the image -------------------------------------------------------
say "pulling $IMAGE"
docker pull "$IMAGE" >/dev/null || fail "could not pull $IMAGE (network / registry / image exists?)"
echo "  pulled"

# --- 3. port + bind + folder mappings -----------------------------------------
say "configuring"
while :; do
  PORT=$(ask "web UI port" "$PORT")
  case "$PORT" in (*[!0-9]*|'') echo "port must be a number"; continue ;; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break
  echo "port out of range (1-65535)"
done
while :; do
  BIND=$(ask "bind address (localhost = this machine only | 0.0.0.0 = all interfaces | <ip>)" "$BIND")
  case "$BIND" in
    localhost|0.0.0.0) break ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
    *) echo "bind must be localhost, 0.0.0.0, or an IPv4 address"; continue ;;
  esac
done
INPUT_DIR=$(ask "input folder (videos to analyze, mounted read-only)" "$INPUT_DIR")
OUTPUT_DIR=$(ask "output folder (score files)" "$OUTPUT_DIR")
REPORTS_DIR=$(ask "reports folder (job artifacts)" "$REPORTS_DIR")
INPUT_DIR=${INPUT_DIR/#~/$HOME}; OUTPUT_DIR=${OUTPUT_DIR/#~/$HOME}; REPORTS_DIR=${REPORTS_DIR/#~/$HOME}
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$REPORTS_DIR" \
  || fail "cannot create the folders (permissions?)"
[ -d "$INPUT_DIR" ] || fail "input folder is not a directory: $INPUT_DIR"
[ -w "$OUTPUT_DIR" ] || fail "output folder is not writable: $OUTPUT_DIR"

# docker publish flags for the chosen bind
case "$BIND" in
  localhost) PUBLISH="-p 127.0.0.1:$PORT:8666"; HEALTH_HOST=127.0.0.1; URL_HOST=localhost ;;
  0.0.0.0)   PUBLISH="-p $PORT:8666";           HEALTH_HOST=127.0.0.1; URL_HOST="<this machine's IP>" ;;
  *)         PUBLISH="-p $BIND:$PORT:8666";     HEALTH_HOST=$BIND;      URL_HOST=$BIND ;;
esac

# --- 4. GPU -------------------------------------------------------------------
say "GPU"
GPU_ARGS=()
GPUS=$(nvidia-smi -L 2>/dev/null || true)
if [ -z "$GPUS" ]; then
  echo "  no NVIDIA GPU detected (nvidia-smi absent) — continuing without GPU"
else
  echo "$GPUS" | sed 's/^/  /'
  if [ -z "$GPU_ANSWER" ]; then
    GPU_ANSWER=$(ask "use a GPU for vca (GPU decode/benchmark)?" "yes")
  fi
  case "$GPU_ANSWER" in
    [Yy]*)
      NGPU=$(printf '%s\n' "$GPUS" | grep -c '^GPU ')
      if [ "$NGPU" -gt 1 ] && [ "$GPU_SET" != yes ]; then
        while :; do
          GPU_INDEX=$(ask "which GPU index? (nvidia-smi index)" "0")
          case "$GPU_INDEX" in (*[!0-9]*|'') echo "index must be a number"; continue ;; esac
          nvidia-smi -i "$GPU_INDEX" --query-gpu=uuid --format=csv,noheader >/dev/null 2>&1 && break
          echo "no such GPU index (0-$((NGPU-1)))"
        done
      fi
      CVD=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=uuid --format=csv,noheader) \
        || fail "nvidia-smi: could not resolve the UUID of GPU $GPU_INDEX"
      # Pin by UUID: a numeric CUDA_VISIBLE_DEVICES value is a CUDA ordinal,
      # which does not follow nvidia-smi numbering on all hosts.
      GPU_ARGS=(--gpus all -e CUDA_VISIBLE_DEVICES="$CVD")
      echo "  GPU $GPU_INDEX pinned ($CVD; index 0 inside the container)" ;;
    *) echo "  GPU declined — continuing without GPU" ;;
  esac
fi

# --- 5. start -----------------------------------------------------------------
say "starting the container"
start_container() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker run --rm -d --name "$NAME" \
    $PUBLISH \
    "${GPU_ARGS[@]}" \
    -v "$INPUT_DIR:/input:ro" \
    -v "$REPORTS_DIR:/reports" \
    -v "$OUTPUT_DIR:/reports/scores" \
    -u "$(id -u):$(id -g)" \
    -e VCA_HOST_INPUT_ROOT="$INPUT_DIR" \
    -e VCA_HOST_OUTPUT_ROOT="$OUTPUT_DIR" \
    "$IMAGE" >/dev/null
}
start_container || fail "docker run failed (is port $PORT free on $BIND? are the folders accessible?)"

# --- 6. startup test ----------------------------------------------------------
# 127.0.0.1, not localhost: where localhost resolves to ::1 first, the
# docker-proxy resets the IPv6 connection.
health_ok() { curl -fsS -o /dev/null --max-time 3 "http://$HEALTH_HOST:$PORT/health"; }
say "testing startup"
for _ in $(seq 1 30); do health_ok && break; sleep 2; done
if ! health_ok; then
  if [ "${#GPU_ARGS[@]}" -gt 0 ] && ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "  GPU startup failed — retrying without GPU"
    GPU_ARGS=()
    start_container || fail "docker run (no-GPU retry) failed"
    for _ in $(seq 1 30); do health_ok && break; sleep 2; done
  fi
  health_ok || { docker logs --tail 30 "$NAME" >&2 2>&1 || true; fail "health endpoint did not answer on port $PORT"; }
fi
echo "  health: ok"

# --- 7. done ------------------------------------------------------------------
say "vca is up"
echo "  URL:     http://$URL_HOST:$PORT/"
echo "  bind:    $BIND"
echo "  input:   $INPUT_DIR -> /input (read-only)"
echo "  output:  $OUTPUT_DIR -> /reports/scores (scores: <name>.<ext>.score)"
echo "  reports: $REPORTS_DIR -> /reports"
[ "${#GPU_ARGS[@]}" -gt 0 ] && echo "  gpu:     pinned for GPU decode/benchmark" || echo "  gpu:     none"
echo "  container: $NAME (docker logs $NAME | docker rm -f $NAME)"
