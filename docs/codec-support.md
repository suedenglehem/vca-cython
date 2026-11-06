# Codec support matrix and parser coverage

Codec family is classified from **ffprobe `codec_name`** (`h264`/`hevc`/`av1`/
`mpeg2video`/`vvc`/`vp8`/`vp9`/`prores`), never from PyAV decoder names (`libdav1d` etc.).

## Support matrix

| Codec | Container | fast | header | deep | benchmark |
|---|---|---|---|---|---|
| h264 | TS, MP4/MOV | ✅ | ✅ full | ✅ motion (export_mvs) | ✅ software + QSV (`benchmark-decode`) |
| hevc | TS, MP4/MOV | ✅ | ✅ full | ❌ NO-GO → header fallback | ✅ software (`benchmark-decode`) |
| av1 | MP4/MOV | ✅ | ✅ full | ✅ per-frame QP (needs `aomdec`) | ✅ software + CUDA (`benchmark-decode`) |
| av1 | MPEG-TS | ❌ — `AV1_TS_UNSUPPORTED`, exit 2 | | | |
| mpeg2video | TS, PS (.mpg), raw | ✅ | ✅ full (QP NA — per-MB) | ❌ NO-GO → header fallback | ✅ software (`benchmark-decode`) |
| vvc | MP4/MOV | ✅ | ✅ full (ref count NA — RPL) | ❌ no deep adapter → header fallback | ✅ software (`benchmark-decode`) |
| vvc | MPEG-TS | ✅ (Annex-B parser path, 2-byte NAL header) | ✅ | ❌ | ✅ |
| vp8 | WebM, MP4 | ✅ | ✅ full (ref/slice NA — per-MB) | ❌ no deep adapter → header fallback | ✅ software (`benchmark-decode`) |
| vp9 | WebM, MP4 | ✅ | ✅ full (ref/slice NA — per-partition) | ❌ no deep adapter → header fallback | ✅ software (`benchmark-decode`) |
| prores | MOV, MKV, MP4 | ✅ | ✅ full (QP NA — fixed matrices; all-I) | ❌ no deep adapter → header fallback | ✅ software (`benchmark-decode`) |
| other | any | ❌ exit 2 | | | |

`--mode auto` selects header only when the adapter declares support; otherwise it runs
fast and emits `HEADER_METRICS_UNAVAILABLE`. `--mode deep` runs the per-codec deep
adapter (h264 motion via PyAV `export_mvs`; av1 per-frame QP via external `aomdec
--framestats`, gated on `tools.aomdec` being probeable) on top of header metrics.
Codecs with no adapter (hevc) fall back to header — fast when header is unsupported —
with `DEEP_METRICS_UNAVAILABLE`. Deep metrics are never faked; a decode that stops
early yields `PARTIAL` + `DEEP_METRICS_PARTIAL`, not estimates. See
`docs/deep-parsing-feasibility.md` for the per-codec research evidence.

## Header-mode parser coverage

| Metric | h264 | hevc | av1 | mpeg2video |
|---|---|---|---|---|
| frame type | slice_type → I/P/B/SP/SI (frame precedence I>P>B) | slice_type → I/P/B (IRAP → I) | frame_type: KEY→I, INTRA_ONLY→I, SWITCH→I, INTER→P (native name in `frame_type_raw`) | picture header coding type → I/P/B (start code 0x00; both the standard `'1111' CT CT '11'` byte and the MPEG-1-style temporal(10)+type(3) header are accepted) |
| keyframe | IDR NAL present | IRAP NAL present | KEY frame | I picture |
| slice/tile count | slices per AU (sums per bin) | slices per AU | `tile_cols * tile_rows` per frame | slices per AU (0x01..0xAF; a 0x00 after the header is slice 0, not a second header) |
| QP | `26 + pic_init_qp_minus26 + slice_qp_delta`, scope `slice` | slice QP, scope `slice` | `base_q_idx`, scope `base` | **NA** — quantization is per-macroblock (`quantizer_scale_code` in slice data), not slice-level; never estimated |
| reference count | ref-list modification signaling per slice (l0+l1 for B), scope partial | slice header ref signaling, partial | reference mask count, partial | max signaled by coding type (I→0, P→1, B→2), partial |
| coded unit | macroblock | CTU | superblock | macroblock |

`reference_count` is **signaling-based** (what the slice header requests), not DPB
occupancy — bins carry `PARSE_PARTIAL` info for it. Slice-group maps (h264
`num_slice_groups_minus1 > 0`) are not parsed: the AU is marked malformed, never a crash.

### VVC / VP8 / VP9 / ProRes header coverage

| Metric | vvc | vp8 | vp9 | prores |
|---|---|---|---|---|
| frame type | slice header `slice_type` (0=B, 1=P, 2=I — verified against `trace_headers`) | frame tag: keyframe partition layout → I, inter → P | frame header `frame_type` (0 KEY→I, 1 INTER→P, 2 INTRA_ONLY→I, 3 SWITCH→I; native name in `frame_type_raw`) | **I always** — intra-only codec |
| keyframe | IRAP NAL present (types 7–11: IDR_W_RADL/IDR_N_LP/CRA/RSV_IRAP) | key frame tag (14-bit size 0 header partition) | KEY frame | always true |
| slice/tile count | VCL NALs per AU | **NA** — no slice structure | **NA** — partitions ≠ slices | slices per picture, **computed from geometry** (QT ignores the written value — proresdec.c) |
| QP | `6·sps_bitdepth_minus8 + 26 + pps_init_qp_minus26 + ph_qp_delta + sh_qp_delta`, scope `slice` | quantizer at coefficient-partition start (7-bit code; ≥64 extends 11 bits), scope `base` | rolling base QP + `delta_q` from frame header, scope `base` | **NA** — per-profile fixed quantization matrices (proresdata.c), never signaled |
| reference count | **NA** — reference picture lists are PPS/APS-derived, not a frame-header count | **NA** — per-macroblock ref selection | **NA** — per-partition/per-block ref selection | **NA** — no references exist in the codec |
| coded unit | CTU | macroblock | block (8×8/16×16) | macroblock |
| unit source | length-prefixed NALs (2-byte header, vvcC `lengthSizeMinusOne`) | raw packet | raw packet (webm packets start with the 2-bit frame marker `0b10`) | raw packet (`icpf` picture box) |

VP8/VP9/ProRes packets **are** access units (packet=AU, raw payload — no NAL/OBU
framing); VVC uses the length-prefixed NAL path like HEVC. Adapters dispatch on
`unit_source` ("nals" | "obus" | "raw").

## Validation (T2.9)

Frame type/keyframe counts compared against `ffprobe -show_frames` — exact matches:

| Fixture | ffprobe | vca header mode |
|---|---|---|
| tiny_h264.ts | 3 I / 32 P / 90 B | 3 / 32 / 90 |
| tiny_hevc.ts / .mp4 | 1 / 34 / 90 | 1 / 34 / 90 |
| tiny_av1.mp4 | 1 KEY / 74 INTER | 1 / 74 |
| tiny_mpeg2.ts / .mpg | 6 I / 37 P / 82 B | 6 / 37 / 82 |
| tiny_vvc.mp4 | 5 I / 120 B | 5 / 120 |
| tiny_vp8.webm | 5 I / 120 P | 5 / 120 |
| tiny_vp9.webm | 5 I / 120 P | 5 / 120 |
| tiny_prores.mov | 125 I (intra-only) | 125 |

MPEG-2 frame types validated against `ffprobe -show_frames` **and** PyAV decoder
`pict_type` on the fixture, and against ffprobe on a real broadcast capture
(`hotbird130E-ts6000-2018-05-11.ts`, 720x576 DVB: 85 I / 683 P / 768 B over 1536
frames, GOP 18 pattern I-B-P-B-P… matched).

H.264 QP spot-check against `ffmpeg -bsf:v trace_headers` (cbs_h264 slice_header):
**125/125 frames match** (`tests/fixtures/oracle_h264_qp.txt`, locked in
`tests/test_codecs.py`). The slice-header field order follows ffmpeg's cbs layout —
`frame_num` is read unconditionally (even for IDR) and the spec's
`constrained_intra_pred`/`cb_qp_offset`/`chroma_qp_offset`/`direct_spatial_temporal_*`
fields are not present in ffmpeg's parse; ffmpeg is the oracle because it is the
decoder ecosystem the tool targets.

Real broadcast sample: `DVB-T_586000_H_0-61.ts` — 2033/2034 AUs parsed (1 malformed,
reported as `PARSE_MALFORMED`, analysis continues).

VVC slice-header field positions (slice_type mapping, QP chain, PPS defaults) were
landed against `ffmpeg -bsf:v trace_headers` (cbs_vvc) on the fixture — same
"ffmpeg is the oracle" rule as the H.264 QP oracle. Fixture QP range 34–47.

## Known limitations

- AV1 in MPEG-TS: no standardized packetization we validate against → unsupported.
- MPEG-2: header metrics full, QP NA (per-macroblock quantization). Deep mode falls
  back to header with `DEEP_METRICS_UNAVAILABLE`. MPEG-2 is Annex B in every
  container (TS/PS/raw), so the parser path (not packet=AU) applies to MPEG-PS too.
  Multi-program TS default selection prefers a video stream with reported dimensions
  over 0x0 placeholder streams.
- Field-based h264 (interlaced): field_pic/bottom_field are parsed; per-field metrics
  are aggregated per AU.
- HEVC: only NAL types 33/34 (SPS/PPS) are seeded from `hvcC`; VPS/SPS extensions
  beyond P2 scope are skipped.
- Deep metrics: h264 motion vectors + intra/inter MB split (deep mode); av1 per-frame QP
  (deep mode, requires a user-supplied `aomdec` with `--framestats` — not bundled).
  HEVC deep is NO-GO (no maintained decoder-side exposure); per-block QP and residual
  statistics are NO-GO for all codecs.
- Decode-cost measurement: `benchmark-decode` (P4) measures whole-file throughput
  (software, CUDA `av1_cuvid`, QSV `av1_qsv`/`h264_qsv`/`hevc_qsv`, VAAPI where built)
  with full run identity; per-second `decode_*` columns stay `NA` — whole-file averages
  are never copied into bins.
- Quality comparison (P5, `vca compare`): PSNR/SSIM/VMAF require frame-aligned
  geometry — resolution/frame-count mismatch is an error, never a silent rescale.
  MBAFF/interlaced copy-cuts keep field pictures (container 50 fps) while re-encodes
  produce progressive frames, so comparisons against them report `NA` with the
  mismatch reason; re-encode the reference with forced keyframes for aligned
  comparisons. VMAF requires libvmaf in the FFmpeg build (else `NA` + warning).
