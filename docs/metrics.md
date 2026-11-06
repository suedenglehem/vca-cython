# Metrics — units, aggregation, scores, NA behavior

All timestamps are seconds on the **normalized analysis timeline** (PTS repaired per
`--timestamp-policy`; the original offset is reported as `source_timeline_offset_s`).
Missing values are `NA` in CSV, `null` in JSON — never `0`, never blank.

## Binning

An access unit (AU) is assigned to the bin containing its **start PTS** and contributes
fully to that bin. Bins are `bin_seconds` wide (default 1.0); the final bin is partial
(`actual_duration_s = second_end - second_start`).

## Per-second metrics

| Column | Unit | Aggregation |
|---|---|---|
| `frame_count` | count | AUs assigned by start PTS |
| `effective_fps` | fps | `frame_count / actual_duration_s` |
| `video_bytes` / `video_mbps` | bytes / Mbit/s | sum AU payload bytes; `bytes*8/duration/1e6` |
| `i_frames`, `p_frames`, `b_frames` | count | frame types from header parsing (header mode). `NA` = no frame of that type in the bin (a measured zero, not missing data) |
| `keyframes` | count | packets flagged keyframe by the demuxer — **not** a frame type |
| `access_unit_bytes_mean/p95` | bytes | over AU byte counts with a value |
| `reference_count_mean` | refs/frame | mean over frames with a value (header mode; signaling-based, see codec-support) |
| `slice_count`, `tile_count` | count | **sums per bin** (header mode) |
| `coded_unit_type`, `coded_unit_count` | label / count | `macroblock` (h264) / `ctu` (hevc) / `superblock` (av1); sums per bin |
| `intra_unit_count`, `inter_unit_count` | count | **deep mode, h264 only**: distinct 16×16 MBs with/without decoder-exported MVs, summed per bin; `inter` counts MBs carrying ≥1 MV (zero-MV inter blocks count as inter, not intra); `NA` in fast/header modes |
| `qp_mean`, `qp_p95` | QP | mean/p95 over per-frame QP; scope reported per frame: `slice` (h264/hevc), `base` (av1 `base_q_idx`), `base-decoder` (av1 deep mode, per-frame QP from `aomdec --framestats`). Raw QP is **not comparable across codecs** and is never normalized to one scale |
| `demuxed_payload_bytes/mbps` | bytes / Mbit/s | all demuxed payload by own PTS; **excludes TS transport overhead** |
| `ts_cc_errors`, `ts_cc_missing_packets` | count | TSDuck continuity events mapped to bin; `0` when the gate ran clean, `NA` for non-TS/unmapped. A continuity-rejected TS produces no CSV at all |
| `parser_coverage` | 0–1 | fraction of expected metrics for the selected mode with values in the bin; empty bins `NA`, not 1.0 |
| `warning_count` | count | warnings whose PTS falls in the bin; global warnings appear only in the TXT/JSON warning list |
| `motion_vector_count` | count | **deep mode, h264 only**: MVs emitted by libavcodec `export_mvs` (padded-MB vectors beyond the visible frame excluded), summed per bin; `NA` in fast/header modes |
| `residual_metric` | — | `NA` everywhere: residual statistics are NO-GO for all codecs (docs/deep-parsing-feasibility.md) — never faked |
| `decode_wall_ms`, `decode_fps`, `decode_cpu_ms` | ms / fps / ms | `NA` in analysis reports: `benchmark-decode` (P4) measures **whole-file** throughput into `benchmark.json`; whole-file averages are never copied into per-second bins. Filled only if real per-window measurements are joined |

Means/percentiles are computed over per-frame samples **with a value**; an empty sample
set is `NA`. Percentiles use linear interpolation.

## Scores (versioned, cohort-normalized)

Scores are percentile ranks **within the file's own bins** (0–100). They are **not
comparable across codecs, profiles, resolutions, or files** — a 90 means "top of this
file", not "hard to decode".

- **`compressed_rate_score`** — percentile rank of `video_mbps` over non-empty bins.
  Label `DATA-RATE`. It measures output rate, not complexity.
- **`structural_score` (`structural-v1`)** — weighted percentile ranks of three
  components across bins:
  - `intra_share = i_frames / frame_count` (weight **0.4**)
  - `reference_count_mean` (weight **0.4**)
  - `slice_count_per_frame = slice_count / frame_count` (weight **0.2**)

  Weights are configurable (`scores.structural_weights` in YAML). In header mode a
  component measured as zero (e.g. no intra frames in a bin) scores as 0.0; in fast
  mode it is `NA`. If a component is unavailable, weights renormalize over the
  available ones and the bin's score is marked `PARTIAL` in `metric_status`; if less
  than 50% of the total weight is available, the score is `NA`.
  Label `STRUCTURAL`.
- **`complexity_estimate` (`composite-v1`)** — `0.5 * compressed_rate_score +
  0.5 * structural_score`, only when **both** are available; otherwise `NA`. Appears
  in JSON/HTML only, not CSV. Label `COMPLEXITY-ESTIMATE`. It is an estimate from
  bitstream structure — it does **not** imply perceptual quality.
- **`motion_score` (`motion-v1`)** — deep mode, h264 only: percentile rank of the per-bin
  mean motion-vector magnitude (pixels, over nonzero MVs) across bins with deep motion
  data. A bin with motion data whose MVs are all zero (static content) scores as a
  measured 0.0 px; bins without deep coverage are `NA`. Never faked from frame type or
  bitrate. `NA` in fast/header modes and for hevc/av1.
- **`decode_cost_score`** — `NA` until per-window decode cost is measured and joined;
  `benchmark-decode` (P4) reports whole-file throughput only.

## Deep mode (`--mode deep`)

Deep mode adds decoder-derived metrics on top of header metrics (header metrics are
still computed). Adapters are per-codec and capability-gated:

- **h264 → motion**: PyAV decode with libavcodec
  `export_mvs`; fills `motion_vector_count`, `intra_unit_count`, `inter_unit_count`
  per AU and `motion_score` per bin. Requires decode (≈580 fps measured on a DVB-T
  capture) — the demux-only fast path is unchanged.
- **av1 → qp**: `ffmpeg -c copy` to IVF + `aomdec
  --framestats` CSV → per-frame QP (scope `base-decoder`). Requires an `aomdec`
  binary with `--framestats` on PATH (`tools.aomdec` in YAML); not bundled in
  the Docker image.
- **hevc → none**: NO-GO (no maintained decoder-side exposure). `--mode deep` on
  hevc falls back to header mode with a `DEEP_METRICS_UNAVAILABLE` warning.

Fallbacks are explicit, never silent: an unavailable adapter falls back to header
(fast when header is unsupported) and reports `DEEP_METRICS_UNAVAILABLE`; a decode
that stops early marks deep metrics `PARTIAL` with `DEEP_METRICS_PARTIAL` and the
uncovered AUs stay `NA`. `analysis.deep_adapter` in data.json records
`{codec, kind}` when deep metrics ran; `coverage.motion` reports source `deep`.

### Ranking basis (`--rank-by`)

`auto` (default): `composite` when available, else `structural`, else `compressed`.
An explicitly requested basis with no values falls back (structural→compressed,
composite→structural→compressed) and the TXT/JSON report states the basis actually
used.

### Top intervals

Top N non-overlapping windows (default 10, `scores.window_seconds` = 5) by descending
mean basis score, tie-break earlier start. A window requires ≥50% of its bins to carry
a score. Each interval reports start/end, score, basis, component means
(`intra_share_mean`, `reference_count_mean`, `slice_count_mean`,
`structural_score_mean`, `video_mbps_mean` as applicable), the top-5 largest AUs in the
window, and warning codes inside it.

## Encoding experiments and compare (P5)

- **Experiments** (library API): a profile is
  `{name, encoder, params}`; `expand_matrix` takes the cross product of encoders ×
  param groups. The runner records per encode: wall time, child CPU (`utime`/`stime`
  via `RUSAGE_CHILDREN` diff), max RSS, output probe stats (size, duration, avg
  bitrate) and the **encoder identity** from the capability probe. Results append to
  `manifest.json` (schema `experiments-v1`); resume skips profiles already recorded
  `ok` with an existing output; outputs are never overwritten without `overwrite`.
- **Quality**: PSNR / SSIM / VMAF via FFmpeg filters,
  reference vs distorted, frame-aligned. Resolution or frame-count mismatch is an
  **error**, never a silent rescale. VMAF unsupported → `NA` + explicit warning,
  never an estimate. The exact command and FFmpeg version are recorded with values.
- **Compare** (`vca compare`): per candidate — bitrate/size, encode wall time (from
  the experiments manifest via `--manifest`, `NA` for external candidates), PSNR/SSIM/
  VMAF, decode fps (whole-file benchmark). The report presents the **Pareto set**
  (non-dominated over bitrate↓, quality↑, encode wall↓, decode fps↑) and per-objective
  leaders, each labeled. There is **no unqualified "best"**; `NA` means not measured,
  never 0.
- **Interlaced/MBAFF caveat**: a copy-cut segment of MBAFF content keeps field
  pictures in the container (e.g. 720×576 @ 50 → 454 frames) while a re-encode
  decodes to progressive frames (224) — quality comparison then reports `NA` with a
  frame-count-mismatch reason. Re-encode the reference with
  `segments.force_keyframe_params()` (`-force_key_frames 0`) for frame-aligned
  comparisons; this also removes open-GOP reference artifacts.

## Guided optimization (P6)

`vca optimize` runs: scene-aligned candidate intervals (analysis top/easy windows +
FFmpeg scene cuts, snapped to keyframes; analysis bins are stream-relative, intervals
are absolute stream PTS) → per-interval parameter sweep (P5 runner; interval reference
= crf-18 forced-keyframe master so quality is frame-aligned) → **constrained
selection** (PRD §9.1: minimize encode_time/bitrate/quality subject to
`vmaf>=`/`psnr>=`/`ssim>=`/`bitrate<=`/`encode_time<=`/`decode_fps>=`, or `pareto`).
A single-objective winner requires ≥1 constraint — without constraints the feasible
Pareto set is returned and the report says there is no winner. A candidate whose
constrained metric is NA never satisfies it (reason recorded). Full-file validation
encodes the winner and reports quality vs source, decode fps, per-second bitrate
spikes (peak/mean from the fast analyzer) and boundary status; **no stitching** is
performed, so stitch-boundary artifacts are N/A (recorded, not proven absent).
Interlaced sources carry an explicit caveat: quality vs a progressive encode is
field/frame-misaligned and indicative only.

## Per-second decoding-complexity graph (report.html)

The headline chart in `report.html` is the **decoding-complexity estimate with one
point per second of video**: `complexity_estimate` (composite-v1) and
`structural_score` on a dedicated 0–100 axis, plus `motion_score` (deep-v1) where
deep coverage exists. Bins whose score is NA are **absent** from the trace — never
drawn as zero. Bitrate/AU traces share the chart on the left axis; keyframe markers
sit on their own overlay axis. The plot uses inline Plotly.js (no CDN), so the
report renders offline and inside the Docker web UI. Verified on the 63.6 s DVB-T
capture (deep mode): 63/63 composite + structural points, 45/63 motion (deep
coverage), `decode_cost_score` NA → absent from chart, present as NA column in the
per-second table.
