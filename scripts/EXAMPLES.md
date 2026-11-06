# EXAMPLES.md — CLI analysis examples (scripts/analyze.sh)

Single-file analysis through the vca CLI. Every `vca analyze` option is exposed
as an argument; results are written under `--out` (default
`reports/cli/<timestamp>-<name>/`) and the produced file paths are printed at
the end. Exit code = vca's real exit code (0 ok, 2 input/config, 3 analysis
failure, 5 TS-continuity gate rejection). Binary resolution: `vca` on PATH
(`pip install wheel/vco-*.whl`; `--bin PATH` / `VCA_BIN` override).

The examples below ran on real broadcast captures (verified 2026-11-03);
replace `<your-file.ts>` with your own MPEG-TS/MP4/WebM file.

## The five example runs

### 1. Header mode, default json+txt — exit 0

```
scripts/analyze.sh <your-file.ts> --mode header \
    --out reports/demo/dvb-header --overwrite
```

`data.json` (full per-second metrics) + `report.txt` (summary) +
`probe.json` / `continuity.json` / `run.json`.

### 2. Deep mode (h264 motion vectors), all formats, structural ranking — exit 0

```
scripts/analyze.sh <your-file.ts> --mode deep \
    --format json,txt,csv,html --rank-by structural --window-seconds 5 \
    --out reports/demo/dvb-deep --overwrite
```

Adds `metrics.csv` (per-bin table), `report.html` (plotly per-second
complexity graph), motion scores per bin; top intervals ranked by
structural-v1 over a 5 s window.

### 3. Default continuity gate → honest rejection — exit 5 (by design)

```
scripts/analyze.sh <your-file.ts> --mode header \
    --out reports/demo/hotbird-gated --overwrite
```

This capture has 33 TS continuity errors / 81 missing packets. With the default
`--ts-continuity require` policy nothing is analyzed on a bad gate: exit 5,
only `probe.json`, `continuity.json`, `rejection.txt` written.

### 4. Same file, gate downgraded to warnings → full MPEG-2 analysis — exit 0

```
scripts/analyze.sh <your-file.ts> --mode header \
    --ts-continuity warn --out reports/demo/hotbird-header --overwrite
```

Stream 13 auto-selected (720x576 mpeg2video, dimensioned stream preferred
over 0x0 placeholders); 1536 frames, 85 I / 683 P / 768 B, 62 bins;
QP is honest NA (per-macroblock quantization).

### 5. 2 s bins, compressed ranking, per-frame records — exit 0

```
scripts/analyze.sh <your-file.ts> --mode header \
    --bin-seconds 2 --rank-by compressed --frames --ts-continuity warn \
    --format json,txt,csv --out reports/demo/tnt-header --overwrite
```

This capture is multi-program h264; the default-selected stream has malformed AUs →
frame types stay honest NA and the analysis continues (never guessed).
`frames.csv` requires `csv` in `--format`; `--frames` also embeds frame
records in `data.json`.

## All options

```
--mode fast|header|deep|auto                analysis mode (default: auto)
--stream SPEC                               video stream: index, or "2:v:0"
--program ID                                select stream by program id
--bin-seconds SEC                           bin width (default: 1.0)
--format txt,csv,json,html                  comma list (default: json,txt)
--frames                                    per-frame records
--ts-continuity require|warn|off            MPEG-TS continuity gate
--ts-continuity-timeout SEC                 gate scan timeout
--ts-continuity-max-errors N                gate error budget (require)
--out DIR                                   output dir (default: reports/cli/<stamp>-<name>)
--overwrite | --force | --keep-temp         overwrite / continue-past-failures / debug
--timestamp-policy repair|report|strict
--rank-by auto|compressed|structural|composite|decode
--window-seconds SEC                        top-interval window (default: 5.0)
--recursive                                 INPUT is a directory
--config FILE                               config (scores, weights, ...)
--log-level debug|info|warning|error
--bin PATH                                  vca binary override
-h | --help                                 full usage
```

## Output files

| File | Content |
|---|---|
| `data.json` | full result: analysis info, streams, selected stream, TS continuity, coverage, warnings, per-second bins, top intervals (+ frames with `--frames`) |
| `report.txt` | human summary: run identity, selected stream, top intervals |
| `metrics.csv` | per-bin table (needs `csv` in `--format`) |
| `frames.csv` | per-frame records (needs `--frames` **and** `csv`) |
| `report.html` | plotly per-second decoding-complexity graph (needs `html`) |
| `probe.json` / `continuity.json` / `run.json` | probe, TS continuity evidence, run identity |
| `rejection.txt` | written on gate rejection (exit 5) instead of analysis outputs |
