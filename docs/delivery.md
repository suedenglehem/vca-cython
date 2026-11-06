# Delivery — Docker image and CLI wheel

## Docker image (`boris271142/vca:latest`)

Fully contained image — the analyzer plus the external tools it needs, no
runtime network required:

- **FFmpeg 9.0.2 + ffprobe** built from pinned source (x264, x265, libaom,
  SVT-AV1, dav1d, libvmaf, fdk-aac, NVENC/NVDEC, VAAPI, oneVPL/QSV) →
  `/usr/local/bin`.
- **TSDuck 3.46-4899** (`tsp`, for the MPEG-TS continuity gate) → `/usr/bin/tsp`.
- **vca** installed as a compiled wheel (compiled modules only — no Python
  sources in the image).
- Runtime: Ubuntu 24.04, **non-root user** `vca`, volumes `/input` (read-only)
  + `/reports`, port **8666**, `HEALTHCHECK` against `/health`, entrypoint
  `vca serve --host 0.0.0.0 --port 8666 --input-dir /input --reports-dir /reports`
  (scores default to `/reports/scores`).
- Config: `/etc/vca/config.yaml` via `VCO_CONFIG`; tool paths match the image layout.

### Run it

```bash
docker pull boris271142/vca:latest
mkdir -p input reports
docker run --rm -p 8666:8666 \
  -v "$PWD/input:/input:ro" -v "$PWD/reports:/reports" \
  boris271142/vca:latest
# web UI: http://localhost:8666/
```

`scripts/web.sh` wraps this with named-container start/stop/restart/status/logs,
host folder mounts and GPU pinning; `./setup.sh` does the full first-run setup
(port, bind address, folder mappings, GPU probe) interactively.

CLI inside the image (no web UI):

```bash
docker run --rm --entrypoint vca \
  -v "$PWD/input:/input:ro" -v "$PWD/reports:/reports" \
  boris271142/vca:latest analyze /input/<your-file.ts> --mode header --out /reports/out
```

## CLI wheel (`wheel/vco-0.1.0-cp312-cp312-linux_x86_64.whl`)

Compiled modules only (`.so`), x86_64 Linux, **Python 3.12**:

```bash
python3.12 -m venv ~/.venvs/vca && source ~/.venvs/vca/bin/activate
pip install wheel/vco-0.1.0-cp312-cp312-linux_x86_64.whl
vca --version
vca analyze <your-file.ts> --mode header --out ./reports/out
```

- **NOT bundled (by design):** `ffmpeg`, `ffprobe`, `tsp`. The CLI resolves
  them from config (`tools.*`) or `PATH` and reports them in
  `vca capabilities`. The Docker image is the fully contained artifact.

## Security notes

No authentication — **local/trusted networks only**; inputs are read-only;
path traversal is blocked (inputs must resolve inside the mounted input
folder, artifacts are served only from a job's own directory under
whitelisted names); the client cannot pass arbitrary tool options.

## Licensing

- FFmpeg built with `--enable-nonfree` (libfdk-aac) is **GPLv3**; TSDuck is
  **BSD-2-Clause**. The Docker image is for **local/internal use**; legal
  review is required before any external redistribution.
- The wheel bundles only the vco package and its Python dependencies
  (MIT/BSD-style); it does not embed FFmpeg or TSDuck.
- No LICENSE file has been added to this repository pending the owner's decision.
