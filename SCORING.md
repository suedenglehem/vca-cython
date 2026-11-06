# SCORING.md — how vca computes the per-second scores

Memo of the scoring pipeline.
Every score is a **percentile rank 0..100 within the file's own bins**
(cohort-normalized). Scores are *relative complexity inside one file* —
never absolute quality, never comparable across codecs or files.

## 1. What data is evaluated

Per access unit (frame), from the container + bitstream headers:

| Raw input | Where it comes from |
|---|---|
| PTS, size_bytes | demux (packet timestamps normalized to 0, packet payload sizes) |
| frame type I/P/B, keyframe | header parser: h264/hevc/vvc slice_type, av1/vp9 frame_type, vp8 frame tag, mpeg2 picture-header coding type; prores is intra-only (always I) |
| slice/tile count per AU | slice-header / tile-group parsing (av1: tile_cols×tile_rows; prores: computed from picture geometry) |
| reference_count | slice-header reference signaling (what the header *requests*, not DPB occupancy); **NA for vvc/vp8/vp9/prores** (not a frame-header quantity) |
| QP | h264/hevc/vvc slice QP (PPS init + delta chain), av1 base_q_idx, vp8/vp9 base quantizer; **NA for mpeg2** (per-MB quantization) **and prores** (fixed per-profile matrices) — QP is reported, **not used in scores** |
| video_mbps per bin | sum of video packet bytes per 1-second bin |
| TS continuity errors | per-bin count of CC discontinuities (reported, not scored) |
| motion vectors (deep mode, h264 only) | PyAV `export_mvs`: per-frame MV magnitudes in pixels |

Frames are binned into 1-second bins (`bin_seconds` config);
each bin carries frame_count, i_frames, video_bytes/mbps,
au_mean/au_p95, slice_count, reference_count_mean, etc. Missing metric =
**NA, never 0** — except in header mode, where frame types are *known*, so a
bin with zero intra frames is a *measured* 0.0 share, not missing data.

## 2. Percentile rank (the primitive)

The percentile rank of a value within its cohort → 0..100:
`rank = #below + (#equal+1)/2` (ties get the average rank), then
`100·(rank−1)/(n−1)`. All-equal cohort → 50.0. Cohort = the file's non-empty bins.

## 3. The scores

**compressed_rate_score** = percentile rank of `video_mbps` over non-empty
bins. Pure data-rate: a second with more bits ranks higher.

**structural_score** (`structural-v1`) = weighted mean of percentile ranks of
three components, default weights (config `scores.structural_weights`):

| Component | Weight | Value per bin |
|---|---|---|
| intra_share | 0.4 | i_frames / frame_count (intra frames cost more to decode) |
| reference_count | 0.4 | mean reference_count over the bin's AUs (more refs → more motion work) |
| slice_count | 0.2 | slice_count / frame_count (more slices → more header/entropy work per frame) |

Missing components **renormalize the weights** over what is available; if
<50% of the total weight is available the bin's score is **NA** (marked
`PARTIAL`/`NA` in `metric_status`), never a guess.

**complexity_estimate** = **composite-v1** =
`0.5·compressed_rate + 0.5·structural` when both exist, else NA.
This is the headline curve in the web-UI graph.

**motion_score** (`motion-v1`, deep mode, h264 only) = percentile rank of the
per-bin **mean motion-vector magnitude in pixels** (over nonzero MVs). A bin
with motion data and only zero MVs = measured 0.0 px (static content), not NA.
NA everywhere else — never faked.

**decode_cost_score** = **NA** in all bins. Whole-file decode throughput is
measured by `benchmark-decode` (P4) but per-second decode cost is not
produced; whole-file averages are never copied into bins.

## 4. Ranking basis + top intervals

`--rank-by auto` picks: composite → structural → compressed (first with
values); an explicitly requested basis with no values falls back the same
way. `top_intervals` slides a window (`scores.window_seconds`, default 5 s)
over the bins, scores each window by the **mean of its bin scores** (windows
need ≥half their bins scored), sorts descending, and greedily picks the top
10 **non-overlapping** windows (tie-break: earlier start). Each interval
records its component means, the 5 largest AUs in it, and warnings inside it.

## 5. Honesty rules

- Scores are cohort-normalized **within one file** — a 90 in file A is not a
  90 in file B, and codec families are never comparable.
- NA is NA: missing data is reported as NA with a reason, never imputed as 0.
- Model names are versioned in the output (`score_model: composite-v1`,
  `structural-v1`, `motion-v1`) so results stay reproducible.
- Scores are estimates of *decoding work*, labeled as such in the report
  ("cohort-normalized estimates, not quality").
