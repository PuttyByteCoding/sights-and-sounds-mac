# Media source analysis: requirements

*2026-09-21. Requirements analysis for a job that characterises each video file twice over: what the file is, and what the surviving evidence says about where its picture and sound came from.*

## The one rule

**Do not confuse the properties of the current encode with the properties of the source that was encoded.**

Most of the library has been through HandBrake. After that, the codec, bitrate, resolution, scan type and encoder describe HandBrake's output and nothing earlier. So every property below is filed under one of four headings, and the data model keeps them apart:

| Layer | What it holds | Example | Can be wrong how |
|---|---|---|---|
| **Declared** | What the container and bitstream say | `1920×1080, H.264 High@4.0, progressive, bt709` | Metadata invented or defaulted by the transcoder |
| **Measured** | What decoding the media shows | active picture 1440×1080; detail runs out near 480 lines; 3:2 repeat pattern | Content-dependent; needs many frames |
| **Evidence** | A measurement read as a sign of history | "pillarboxed 4:3 inside 16:9", "detail far below encoded size" | One sign rarely proves anything alone |
| **Inference** | A conclusion, with confidence and the evidence behind it | "SD interlaced video, deinterlaced and upscaled; confidence 0.8" | Always an opinion; never shown as a fact |

An inference is only ever stored with the evidence ids that support it. The evidence is as important as the label.

## What the app has today

- `MediaProbe` (AVFoundation): duration, stream counts, summed data rate, natural size, nominal frame rate, codec four-character codes, audio sample rate, bit depth and channels.
- `QualityScore` scores those, and has a placeholder `QualityAnalysisMetrics` (audio roll-off, peak, RMS, blockiness, blurriness) whose comment says "capture arrives with a later job". **This document specifies that job**, and widens it.
- A caution already recorded there applies throughout: ffmpeg's `blockdetect` scale has no calibrated good/bad reference (clean captures measured 105 to 115 against a placeholder bad-at of 80). Raw filter outputs are evidence to be calibrated on this library, not scores.

## Is there anything useful in the macOS released this month?

Checked against the macOS 27.0 SDK installed on the development machine, by reading availability annotations in the headers and Swift interfaces, not from release notes.

**One addition matters: the on-device language model now takes images.** `FoundationModels` gains `Attachment<ImageAttachmentContent>` (from a `CGImage`, `CIImage`, `CVPixelBuffer` or file URL), new in macOS 27. It runs locally, needs no model of ours, and returns typed output through `@Generable`. It is the obvious candidate for the "difficult to determine deterministically" classifications the brief reserves for Core ML, without training anything.

I tested it rather than assume. One frame per call, about five to six seconds each on this machine, asked for sharpness, "looks upscaled" and visible defects:

| Frame | Truth | Model said |
|---|---|---|
| Synthetic test pattern, pristine 1080p | clean | slightly soft, upscaled, blockiness and banding |
| Same pattern through 352×240, noise, 4:1:0 chroma, upscaled | badly degraded | slightly soft, upscaled, blockiness and banding (**identical**) |
| Natural image, pristine 1080p | clean | sharp, not upscaled, no defects (correct) |
| Same image through 352×240 + noise, upscaled | SD upscale, noisy | slightly soft, upscaled, "pixelation, blockiness" (right verdict, wrong vocabulary: it was noise) |
| Same image as 250 kbit/s MPEG-2 at 720×480, upscaled | low-bitrate SD | sharp, not upscaled, no defects (**wrong**) |

So: it can tell gross from clean on natural pictures, it cannot tell kinds of defect apart, and it missed a case a simple spectrum measurement caught (below). **It is a weak second opinion, not an instrument.** Its sensible uses here are narrow: rejecting unrepresentative sample frames (titles, credits, logos, black), and as one low-weight vote in the final inference, always labelled as a model's opinion. It also costs about six seconds a frame, so it is for a handful of frames per file, not sixteen.

**Already available, older than 27, and more useful than anything new:**

- `VTFrameProcessor` optical flow (macOS 15.4) gives dense motion between two frames. That is what cadence analysis, judder, frame-blending detection and gate weave need, and it is hardware accelerated.
- `VTFrameProcessor` temporal noise filter (macOS 26): the difference between a frame and its temporally denoised version is a direct estimate of the noise and grain field, separable from picture detail in a way a single-frame measurement is not.
- `VTFrameProcessor` super-resolution and frame-rate conversion exist too. They are for making pictures, not measuring them, and should stay out of an analysis tool.

**Not useful here:** the rest of AVFoundation's and Core Media's macOS 27 additions are capture, genlock, Apple Log and immersive video. `AVPlayerItemSampleBufferOutput` is new but HLS-only. Vision's macOS 27 additions are segmentation. Core Image's are decoding options. VideoToolbox gains a constant-quality encode mode, which is about encoding.

## Two experiments that shaped the recommendations

Both used synthetic material only.

**Effective resolution is measurable with Accelerate alone.** Average the luma power spectrum of many rows (vDSP FFT, Hann window), and find the width below which 99.9 % of the AC energy sits:

| Frame (all encoded 1920 wide) | Detail runs out at |
|---|---|
| Test pattern, pristine | about 1443 px |
| Natural image, pristine | about 1005 px |
| Natural image via 352×240 + noise, upscaled | about 487 px |
| Natural image via 720×480 low-bitrate MPEG-2, upscaled | about 360 px |
| Test pattern via 352×240, upscaled | about 296 px |

Two lessons. It separates every case, including the one the language model got wrong. And it is content-dependent: a soft but genuine 1080p image measured 1005, and noise added before the upscale pushed a 352-wide source up to 487. So the measurement is taken over many frames, the high percentile is what counts, and it is reported as "detail consistent with about N lines", never as "the source was N".

**The current file really does hide its history.** A 720×480 top-field-first MPEG-2 clip reads as 60 of 60 frames TFF under ffmpeg's `idet`. Deinterlace it, scale to 1440×1080, pad to 1920×1080 and encode with x264: `idet` now says 60 of 60 progressive and MediaInfo says `Progressive`. The declared and even the measured scan type say nothing about the origin. But `cropdetect` still finds a 1440×1080 active picture, which is 4:3, and the spectrum still says SD. The origin is recoverable only from the second-order evidence.

## Tool roles

| Tool | Role | Why |
|---|---|---|
| **AVFoundation / Core Media** | Primary for declared properties, all decoding, all frame and sample access | Native, hardware decode, exact per-sample timing via `AVAssetReader`, format description extensions carry colour, PAR, clean aperture, field count |
| **Accelerate (vDSP, vImage)** | Primary for every deterministic picture and sound measurement | FFTs, convolutions, histograms and statistics on planar buffers, fast on CPU, no GPU readback |
| **Core Image** | Convenience for per-frame reductions (`CIAreaAverage`, `CIAreaHistogram`, `CIRowAverage`, `CIColumnAverage`) | Border detection and colour statistics in a few lines; Metal only if profiling demands it |
| **VideoToolbox** | Optical flow and temporal noise estimation | Hardware accelerated, no model to ship |
| **MediaInfo** | Supplementary declared properties AVFoundation does not surface | Encoder settings string, bitrate mode, frame-rate mode, profile and level with tier, format-specific flags |
| **ffprobe** | Supplementary: per-frame picture types and flags, GOP structure, HDR side data | `-show_frames` gives `pict_type`, `interlaced_frame`, `top_field_first`, `repeat_pict`, keyframe positions |
| **FFmpeg filters** | **Reference implementation during research**, not a dependency of the shipped analysis | `idet`, `cropdetect`, `signalstats`, `blockdetect`, `blurdetect`, `siti`, `mpdecimate`, `ebur128`, `astats`, `aspectralstats` are the ground truth to calibrate native code against |
| **Vision** | Frame triage only | Text detection to reject title and credit frames; saliency is not needed |
| **Foundation Models (macOS 27)** | Optional, low-weight opinion and frame triage | Tested above: cannot be the instrument |
| **Core ML** | Last resort, only if deterministic features plus rules prove insufficient | Needs a labelled set this library does not yet have; a gradient-boosted classifier over the measured features would come before any image model |

The app already treats ffmpeg as an optional system tool ("direct distribution, system tools allowed"). The same holds here: MediaInfo and ffprobe enrich the declared layer when present and the job degrades honestly when they are absent.

## Sampling

- **Stills:** 16 frames at 5 %, 11 %, … 95 % of duration. Reject a frame that is near-black, near-uniform, a fade (large luma change against both neighbours), or mostly text (Vision text detection), and step forward a few seconds until one passes. Record how many were rejected.
- **Sequences:** four windows of about 10 seconds (at 20 %, 40 %, 60 %, 80 %), decoded frame by frame with `AVAssetReader`. Cadence, combing residue, frame blending, duplicate frames, flicker, line jitter, head-switching noise and gate weave cannot be seen in a still.
- **Whole file, cheap:** sample timing for every frame (no decode), and the whole audio track (decode is fast).
- **Aggregation:** every per-frame measurement is stored per frame and summarised by median and 90th percentile. Detail and noise use the high percentile (the best the file can do); artifact measures use the median (what it usually does).

## Reading the tables

- **Direct or Derived:** *Direct* is read from the file; *Derived* is computed from decoded pixels or samples.
- **Encode or Source:** *Encode* describes only the current file. *Source* survives transcoding and says something about history. *Both* is an encode property that also constrains the source.
- **Reliability:** *High* is trustworthy as stated. *Medium* needs aggregation or corroboration. *Low* is suggestive only.

### 1. Container and encoding

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Container format, brands | File type and compatibility | `ftyp` major and compatible brands | MediaInfo; AVFoundation (`AVURLAsset`, file type) | Direct | Encode | High |
| File size | Storage; input to bitrate | File attributes | Foundation | Direct | Encode | High |
| Duration | Length; consistency between tracks | `asset.load(.duration)`, per-track time ranges | AVFoundation | Direct | Both | High |
| Overall bitrate | Budget spent on the file | size ÷ duration | Computed | Derived | Encode | High |
| Video codec | Current compression | Format description media subtype | Core Media | Direct | Encode | High |
| Codec profile, level, tier | Encoder constraints | Parse `avcC` / `hvcC` from format description extensions | MediaInfo (easier); Core Media | Direct | Encode | High |
| Codec tag | `avc1` / `hvc1` / `hev1` | Media subtype | Core Media | Direct | Encode | High |
| Video bitrate | Budget on picture | `estimatedDataRate`; exact from sample sizes | AVFoundation; `AVAssetReader` | Direct | Encode | High |
| Bitrate mode | CBR, VBR, constant quality | Writing library settings; sample-size variance | MediaInfo; custom | Direct / Derived | Encode | Medium |
| Bits per pixel | Whether the encode starved the picture | bitrate ÷ (w × h × fps) | Computed | Derived | Encode | High |
| Encoder / writing application | HandBrake, Lavf, camera firmware | `©too`, `encoder` tags, SEI user data | MediaInfo; ffprobe | Direct | Encode, and **proof of a transcode** | High |
| Encoding library and settings | x264/x265 version, CRF, preset, deinterlace not included | x264 SEI settings string | MediaInfo | Direct | Encode | High when present |
| Pixel format | Storage layout | Format description, decoded buffer format | Core Video; ffprobe | Direct | Encode | High |
| Bit depth | 8 or 10 bit storage | Format description extensions | Core Media; MediaInfo | Direct | Encode | High |
| Chroma subsampling | 4:2:0 / 4:2:2 / 4:4:4 storage | Pixel format | ffprobe; MediaInfo | Direct | Encode | High |
| Encoded width, height | Stored raster | Format description dimensions | Core Media | Direct | Encode | High |
| Total frame count | Input to cadence and timing | Count samples | `AVAssetReader` without decode | Direct | Encode | High |
| GOP length, keyframe interval | Encoder behaviour; seekability | Sync-sample flags per sample | `AVAssetReader` sample attachments; ffprobe `-show_frames` | Direct | Encode | High |
| B-frame use, reference structure | Encoder behaviour | `pict_type` per frame | ffprobe | Direct | Encode | High |
| Edit lists, multiple sample descriptions | Spliced or edited file | Track segments, format description count | AVFoundation | Direct | Both | Medium |
| Creation and encode dates | When this file was made | Metadata | AVFoundation | Direct | Encode | Medium |

### 2. Video geometry

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Pixel aspect ratio | Anamorphic storage | `kCMFormatDescriptionExtension_PixelAspectRatio` | Core Media | Direct | Both: non-square pixels are a strong SD sign | High |
| Clean aperture | Declared active area | `CleanAperture` extension | Core Media | Direct | Both | High |
| Display dimensions, DAR | Intended shape | `naturalSize` with PAR and transform | AVFoundation | Direct | Encode | High |
| Rotation | Orientation; phone origin | `preferredTransform` | AVFoundation | Direct | Both: rotation implies a phone camera | High |
| Active picture rectangle | The real image inside the raster | Row and column luma means over sampled frames; robust bound, not per-frame | Core Image (`CIRowAverage`, `CIColumnAverage`) or vImage; reference `cropdetect` | Derived | **Source** | High over many frames |
| Letterbox / pillarbox / windowbox | Shape mismatch baked in | Active rectangle against raster | Custom frame analysis | Derived | **Source** | High |
| Active aspect ratio | 1.33, 1.37, 1.66, 1.78, 1.85, 2.35, 2.39 | Active w ÷ h, corrected by PAR | Computed | Derived | **Source**: 1.33 suggests TV or Academy film; 2.35+ suggests cinema | High |
| Border blackness and noise | Borders added digitally or captured with the picture | Mean and variance inside borders | vImage | Derived | **Source**: noisy or non-black borders mean borders predate a generation of encoding or come from analog capture | Medium |
| Border edge sharpness | Whether borders were scaled with the picture | Gradient across the border edge | vImage | Derived | **Source**: a soft edge means the bordered image was later scaled | Medium |
| Overscan junk at edges | Head-switching, VBI lines, blanking | Statistics of the outer 1 to 3 % of rows and columns | Custom frame analysis | Derived | **Source**: analog capture | Medium |
| Raster family | 720×480, 720×576, 704×, 640×480, 352×240, 1280×720, 1440×1080, 1920×1080, 3840×2160 | Match active size and PAR to known rasters | Computed | Derived | Both | Medium |

### 3. Frame rate and cadence

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Nominal frame rate | Declared rate | `nominalFrameRate` | AVFoundation | Direct | Encode | High |
| Average frame rate | Real rate | frames ÷ duration | `AVAssetReader` | Derived | Encode | High |
| Frame-rate mode, CFR/VFR | Timing regularity | Histogram of presentation time deltas | `AVAssetReader`; MediaInfo | Derived | Both: VFR suggests phone, screen capture, web | High |
| Timing jitter | Irregular capture or container damage | Variance of deltas | Custom temporal analysis | Derived | Both | High |
| Rate family | 23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60 | Classify average rate | Computed | Derived | Both: 25/50 PAL region, 29.97/59.94 NTSC region, 23.976/24 film | Medium (HandBrake may have changed it) |
| Duplicate frames | Rate conversion up, or dropped-frame padding | Inter-frame difference near zero; periodicity | vImage difference; reference `mpdecimate` | Derived | **Source** | High |
| Repeat pattern (3:2, 2:2, 2:3:3:2) | Telecined film, or film carried at video rate | Autocorrelation of the difference sequence at period 5, 2, and so on | Custom temporal analysis | Derived | **Source**: film origin | High when motion present |
| Judder, uneven motion | Pulldown left in, or decimation done wrong | Optical-flow magnitude periodicity | VideoToolbox optical flow | Derived | **Source** | Medium |
| Frame blending | Rate conversion by blending, or a blending deinterlacer | Frame well explained as a mix of its neighbours; ghost edges | Custom temporal analysis | Derived | **Source / processing** | Medium |
| Dropped frames | Capture trouble | Flow magnitude spikes without a scene cut | VideoToolbox optical flow | Derived | **Source** | Medium |
| Low native rate (10, 12, 15 fps) | Early web or webcam video | Unique-frame rate after removing duplicates | Custom temporal analysis | Derived | **Source** | High |
| Scene-cut rate | Input to sampling; not evidence | Large inter-frame difference | vImage | Derived | Neither | High |

### 4. Interlacing

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Declared scan type, field order | What the bitstream claims | `FieldCount` and `FieldDetail` extensions; per-frame flags | Core Media; ffprobe `-show_frames`; MediaInfo | Direct | Encode only | High as a statement about the encode; **worthless about the source** |
| Remaining combing | Interlaced frames stored as progressive | Difference between a line and its neighbours against alternate lines, in moving areas only | vImage; reference `idet` | Derived | Both | High |
| Combing only on motion | Distinguishes combing from fine horizontal texture | Mask the comb metric by inter-frame difference | Custom temporal analysis | Derived | Both | High |
| Field cadence | Which field leads; telecine field pattern | Per-field difference sequences | Custom temporal analysis; reference `idet`, `fieldmatch` | Derived | **Source** | Medium |
| Deinterlace residue: halved vertical detail in motion | A field-based deinterlacer was used | Vertical against horizontal spectrum energy, moving against static regions | vDSP | Derived | **Source**: was interlaced | Medium |
| Line-doubling stair-steps on diagonals | Bob or discard-field deinterlace | Edge-orientation regularity at 2-line period | vImage | Derived | **Source** | Medium |
| Field blending ghosts | Blend deinterlace | Double edges on moving objects; frame as mix of neighbours | Custom temporal analysis | Derived | **Source** | Medium |
| 50/60 fps with alternating vertical phase | Bob deinterlace to double rate | Half-line vertical shift alternating frame to frame on static areas | vDSP cross-correlation | Derived | **Source** | Medium |
| Rate and raster consistent with interlaced standards | Prior plausibility | 29.97 or 25 fps with an SD or 1080 raster | Computed | Derived | **Source** | Low alone |

Absence of combing never implies a progressive source. The representable conclusions are: *progressive current file*; *evidence of interlaced origin (strong / some / none found)*; *probably deinterlaced by (field method / blend / unknown)*.

### 5. Color

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Declared primaries, transfer, matrix | What the file claims | Format description colour extensions | Core Media; ffprobe | Direct | Encode; often defaulted by the transcoder | High as a claim |
| Declared range | Video or full | Extension / VUI | Core Media; ffprobe | Direct | Encode | High as a claim |
| HDR format, mastering display, content light level | HDR10, HLG, Dolby Vision | Format description extensions, side data | Core Media; ffprobe; MediaInfo | Direct | Both: real HDR metadata implies a modern master | High |
| Missing colour tags | Untagged file | Absence | Core Media | Direct | Both: common in older and web-derived files | High |
| Measured luma range | Whether range matches the claim | Histogram min and max over frames | vImage | Derived | Both | High |
| Range mismatch | Washed out or crushed | Declared against measured | Computed | Derived | **Processing error** | High |
| Matrix plausibility (601 against 709) | SD-origin colour carried into an HD tag, or the reverse | Skin and primary hue statistics are weak; treat as a hint only | Custom | Derived | **Source** | Low |
| Effective bit depth | 10-bit file holding 8-bit content | Occupancy of the low bits across frames | vImage | Derived | **Source** | High |
| Effective chroma resolution | Chroma bandwidth far below luma | Spectrum of Cb/Cr against Y, horizontally and vertically | vDSP | Derived | **Source**: analog tape (very low horizontal chroma), DV 4:1:1, multiple 4:2:0 generations | High |
| Chroma offset | Chroma shifted relative to luma | Cross-correlation of luma and chroma edges | vDSP | Derived | **Source**: analog, or bad conversion | Medium |
| Saturation and hue stability over time | Colour drift | Per-frame means over sequences | Core Image area average | Derived | **Source**: tape | Medium |
| Colour cast, faded dye look | Aged film print | Channel balance statistics | Core Image | Derived | **Source** | Low |
| Banding | Low bit depth, heavy compression or aggressive denoise | Flat-region gradient step histogram | vImage | Derived | Both | Medium |

### 6. Audio

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Codec, profile | Current compression | Audio format description | Core Media | Direct | Encode | High |
| Sample rate, channels, layout, bit depth | Storage | `AudioStreamBasicDescription`, channel layout | Core Media | Direct | Encode | High |
| Bitrate, mode | Budget | `estimatedDataRate`; MediaInfo | AVFoundation; MediaInfo | Direct | Encode | High |
| Track count, languages | Structure | Tracks | AVFoundation | Direct | Encode | High |
| Integrated loudness, range, true peak | Level; mastering style | EBU R128 | Custom with vDSP; reference `ebur128` | Derived | Both | High |
| Peak, RMS, crest factor | Dynamics | Sample statistics | vDSP; reference `astats` | Derived | Both | High |
| Clipping | Overdriven capture or bad gain | Runs of samples at full scale; flat tops | vDSP | Derived | **Source** | High |
| Effective bandwidth (roll-off) | Real audio bandwidth | Long-term average spectrum; frequency where energy falls 60 dB | vDSP FFT; reference `aspectralstats` | Derived | **Source**: about 10 to 12 kHz suggests VHS linear audio or low-bitrate web; about 15 to 16 kHz suggests FM/broadcast or 128 kbit/s MP3; 20 kHz+ suggests digital | High |
| Lowpass shelf shape | Brick wall against gentle slope | Spectrum slope at the cutoff | vDSP | Derived | **Source**: brick wall implies a lossy codec generation; gentle implies analog | Medium |
| Noise floor | Hiss level | Spectrum of the quietest passages | vDSP | Derived | **Source**: tape | Medium |
| Hum at 50 or 60 Hz and harmonics | Mains pickup; region | Narrowband peaks | vDSP | Derived | **Source**: analog chain; 50 vs 60 hints region | Medium |
| 15.7 kHz whistle | NTSC/PAL line frequency leakage | Narrowband peak at 15.734 or 15.625 kHz | vDSP | Derived | **Source**: analog video chain, and which standard | High when present |
| Wow and flutter | Tape transport instability | Pitch modulation of sustained tones | vDSP | Derived | **Source**: tape | Low to medium |
| Mono as stereo | Duplicate channels | L-R energy against L+R | vDSP; reference `aphasemeter` | Derived | **Source**: mono origin | High |
| Phase correlation | Out-of-phase channels, azimuth error | Correlation over time | vDSP | Derived | **Source** | Medium |
| Codec pre-echo, spectral holes | Earlier lossy generation | Time-frequency analysis | Custom | Derived | **Source** | Low |
| Audio/video sync | Offset or drift | Track start times; onset against scene-cut correlation is weak | AVFoundation; custom | Direct / Derived | Both | Medium for start offset, Low for drift |

### 7. Effective resolution and sharpness

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Horizontal spectral cutoff | Width at which detail runs out | Mean row power spectrum, 99.9 % energy point (tested above) | vDSP | Derived | **Source** | High over many frames |
| Vertical spectral cutoff | Lines at which detail runs out | Same on columns | vDSP | Derived | **Source** | High over many frames |
| Horizontal against vertical detail | Analog tape is far softer horizontally; deinterlacing halves vertical | Ratio of the two cutoffs | Computed | Derived | **Source** | High |
| Estimated source detail class | "about 240 / 480 / 576 / 720 / 1080 / 2160 lines" | 90th percentile of cutoffs mapped to classes | Computed | Derived | **Source** | Medium: content dependent |
| Upscale ratio | Encoded size ÷ effective size | Computed | Computed | Derived | **Source / processing** | Medium |
| Scaling kernel fingerprint | Bilinear, bicubic, Lanczos leave different spectral roll-off and periodic correlation | Spectrum shape near the cutoff; second-derivative periodicity | vDSP | Derived | **Processing** | Low to medium |
| Laplacian variance, edge density | General sharpness | Convolution and statistics | vImage; reference `blurdetect` | Derived | Both | Medium |
| Spatial information (SI) | ITU-T P.910 detail measure | Sobel standard deviation | vImage; reference `siti` | Derived | Both | High as a measure |
| Edge overshoot, halos | Sharpening | Profile across strong edges; overshoot amplitude | vImage | Derived | **Processing**: sharpened, or analog aperture correction | Medium |
| Edge width | Native sharp edges are 1 to 2 px; upscaled ones are wide | 10 to 90 % rise distance on strong edges | vImage | Derived | **Source** | High |
| Texture loss with clean edges | Denoised or AI-upscaled look | High edge sharpness with low mid-frequency energy | vDSP | Derived | **Processing** | Medium |

### 8. Compression artifacts

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Blockiness on the current grid (4, 8, 16 px) | Current encode's blocking | Gradient energy on block boundaries against off-boundary | vImage; reference `blockdetect` | Derived | Encode | Medium: uncalibrated scale |
| **Blockiness on a foreign grid** | A block grid that does not match the current raster, for example 8 px scaled to 21.3 px | Periodicity search in the gradient spectrum at non-native periods | vDSP | Derived | **Source**: an earlier block-based encode, and its original raster | High when found |
| Grid origin offset | Cropping after an earlier encode | Phase of the block periodicity | vDSP | Derived | **Source** | Medium |
| Ringing | DCT ringing near edges | Oscillation energy beside strong edges | vImage | Derived | Both | Medium |
| Mosquito noise | Temporal flicker around edges | Temporal variance in edge neighbourhoods | Custom temporal analysis | Derived | Both | Medium |
| Banding, posterization | Quantised gradients | Step histogram in flat regions | vImage | Derived | Both | Medium |
| Temporal smearing | Heavy inter-frame compression or temporal denoise | Motion trails; flow-compensated residual | VideoToolbox optical flow | Derived | Both | Medium |
| Keyframe pumping | Quality pulsing at GOP period | Periodicity of sharpness or noise at the keyframe interval | Custom temporal analysis | Derived | Encode; a second period implies an earlier encode | Medium |
| Over-smoothing | Low noise with low texture | Noise estimate against detail estimate | Computed | Derived | **Processing** | Medium |
| Quantiser statistics | How hard the current encode squeezed | Average QP per frame | ffprobe (`-debug qp` is research only) | Direct | Encode | High, research only |

### 9. Film characteristics

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Grain level | Amount of random texture | Residual after temporal denoise; variance in flat regions | VideoToolbox temporal noise filter; vImage | Derived | **Source** | Medium |
| Grain spectrum | Film grain is broadband and roughly isotropic; tape noise is horizontally streaked; compression noise sits on the block grid | 2-D power spectrum of the residual | vDSP | Derived | **Source** | Medium |
| Grain against luminance | Film grain peaks in mid-tones; sensor noise rises in shadows | Residual variance binned by luma | vImage | Derived | **Source** | Medium |
| Grain temporal independence | Real grain is new every frame; synthetic overlays can repeat | Residual correlation across frames | vDSP | Derived | **Source / processing** | Medium |
| Grain in chroma | Film has grain in colour; much video noise is luma-heavy | Residual energy per plane | vDSP | Derived | **Source** | Low |
| Dust, dirt, scratches | Single-frame blobs and persistent vertical lines | Temporal outliers present in one frame only; vertical line detector across frames | Custom temporal analysis | Derived | **Source**: film print | High when found |
| Gate weave | Whole-frame sub-pixel wander | Global translation from optical flow, low-frequency | VideoToolbox optical flow | Derived | **Source**: film transport | Medium |
| Flicker | Frame-to-frame global brightness change | Mean luma series, high-pass | Core Image area average | Derived | **Source**: film, or mains-lit video | Low |
| Film cadence | 24 fps, or pulldown residue | Group 3 | Custom temporal analysis | Derived | **Source** | High with motion |
| Reel-change cue marks | Circles in the corner at reel ends | Template in the top-right region | Custom | Derived | **Source**: theatrical print | High when found, rare |
| Grain removed | Waxy flat areas with sharp edges | Group 7 texture loss | Computed | Derived | **Processing**: restoration | Medium |
| Grain re-added | Uniform synthetic grain | Too-even spectrum and luma independence | Computed | Derived | **Processing** | Low |

Grain is never classified as film on its own. It counts towards film only alongside cadence, weave, dirt or aspect ratio.

### 10. Analog and tape characteristics

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Horizontal luma bandwidth far below vertical | Tape's limited luma bandwidth: about 240 lines for VHS, about 400 for S-VHS and Hi8 | Group 7 ratio | vDSP | Derived | **Source**; the ratio separates VHS-like from better analog | High |
| Horizontal chroma bandwidth, very low | Colour-under recording, around 30 to 40 lines | Group 5 chroma spectrum | vDSP | Derived | **Source**: strongly VHS-like | High |
| Chroma bleed and smear to the right | Chroma delay and low bandwidth | Asymmetry of chroma edges relative to luma | vDSP | Derived | **Source** | Medium |
| Chroma noise | Coloured low-frequency blotches | Temporal residual in chroma, low spatial frequency | vDSP | Derived | **Source** | Medium |
| Horizontally streaked luma noise | Tape noise correlates along lines | Anisotropy of the residual spectrum | vDSP | Derived | **Source** | Medium |
| Head-switching noise | Torn, displaced band in the bottom 4 to 12 lines | Row-wise statistics and horizontal displacement at the frame bottom | Custom frame analysis | Derived | **Source**: helical-scan tape, near certain | High when present; often cropped away |
| Dropouts | Short horizontal white or black streaks in one frame | Temporal outliers elongated along rows | Custom temporal analysis | Derived | **Source**: tape | High when found |
| Tracking errors | Horizontal noise bars that move vertically | Row-energy bands drifting across frames | Custom temporal analysis | Derived | **Source**: tape | High when found |
| Line jitter, time-base error | Rows displaced horizontally by different amounts | Per-row cross-correlation against the previous frame in static areas | vDSP | Derived | **Source**: no TBC in the capture chain | Medium |
| Top-of-frame flagging | Skew at the top of the picture | Horizontal displacement profile down the frame | vDSP | Derived | **Source**: tape | Medium |
| Colour instability | Hue and saturation wander | Group 5 stability | Core Image | Derived | **Source** | Medium |
| Dot crawl, cross-colour | Composite decoding | Energy at the colour subcarrier frequency on luma edges; rainbow on fine luma | vDSP | Derived | **Source**: composite, not necessarily tape | Medium |
| Ghosting, ringing echoes | RF or cable reflections | Edge echoes at a fixed horizontal offset | vDSP | Derived | **Source**: off-air or RF | Low |
| Audio signs | Hiss, narrow bandwidth, line whistle, hum | Group 6 | vDSP | Derived | **Source** | Medium to high |

VHS-like specifically means: very low chroma bandwidth, low horizontal luma bandwidth, head-switching or tracking or dropout evidence, and linear-track audio bandwidth. Analog more generally needs only some of the noise, jitter, composite and interlace signs.

### 11. Digital SD and DVD characteristics

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Detail class near 480 or 576 lines | SD origin | Group 7 | vDSP | Derived | **Source** | Medium |
| 480 against 576 | NTSC or PAL region master | Vertical cutoff with rate family (29.97/23.976 against 25) | Computed | Derived | **Source** | Medium |
| Anamorphic storage or PAR history | 16:9 DVD | Group 2 PAR, or 1.78 active picture with SD detail | Core Media; computed | Direct / Derived | **Source** | Medium |
| Foreign 8×8 grid scaled to the current raster | Earlier MPEG-2 or MPEG-4 ASP encode, and its raster width | Group 8 foreign-grid search; period gives the original width | vDSP | Derived | **Source** | High when found |
| MPEG-style ringing and mosquito noise at SD scale | DCT codec at SD, later upscaled | Group 8, measured at the foreign grid's scale | Custom | Derived | **Source** | Medium |
| Clean SD: low noise, no analog signs | Digital SD rather than tape | Absence of group 10 with SD detail | Computed | Derived | **Source** | Medium |
| Telecine or interlace residue | DVD film or video material | Groups 3 and 4 | Custom temporal analysis | Derived | **Source** | Medium |
| 4:2:0 chroma at SD scale | Chroma detail near half of SD in both directions | Group 5 | vDSP | Derived | **Source** | Medium |
| DV signs: 4:1:1 chroma, 720×480, 29.97 | MiniDV camcorder | Horizontal chroma about a quarter of luma with good vertical chroma | vDSP | Derived | **Source** | Medium |
| Audio at 48 kHz with AC-3-like bandwidth | DVD audio chain | Group 6 | vDSP | Derived | **Source** | Low |

### 12. Early web and low-bitrate digital characteristics

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Very low detail class (about 120 to 288 lines) | Tiny original raster | Group 7 | vDSP | Derived | **Source** | High |
| Foreign grid implying 160 to 480 wide | Original raster of a web encode | Group 8 | vDSP | Derived | **Source** | High when found |
| Low unique-frame rate | 10 to 15 fps originals padded to 30 | Group 3 | Custom temporal analysis | Derived | **Source** | High |
| Irregular original timing | Dropped frames preserved as duplicates at odd intervals | Aperiodic duplicate pattern | Custom temporal analysis | Derived | **Source** | Medium |
| Heavy blocking, ringing, smearing at the original scale | Aggressive early codecs | Group 8 at the foreign grid's scale | Custom | Derived | **Source** | Medium |
| Banding and crushed colour | Low bitrate and 8-bit pipelines | Groups 5 and 8 | vImage | Derived | **Source** | Medium |
| Audio bandwidth 5 to 11 kHz, mono, 22.05 kHz heritage | Early web audio | Group 6 roll-off near 11 kHz | vDSP | Derived | **Source** | High |
| Watermark or player chrome in frame | Screen capture of a web player | Static overlay detection across frames; Vision text | Vision; custom | Derived | **Source** | Medium |

Inherited artifacts are told from the current encode's by scale and grid: an artifact that lives on a block grid the current encoder does not use, or whose size only makes sense at a smaller raster, predates the current encode.

### 13. HD and UHD characteristics

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Detail class near 720, 1080 or 2160 | Genuine HD or UHD detail | Group 7 | vDSP | Derived | **Source** | Medium: soft real HD exists |
| Detail matches the encoded raster | Native, not upscaled | Upscale ratio near 1 | Computed | Derived | **Source** | Medium |
| 1440×1080 heritage | HDV or HDCAM anamorphic HD | PAR 4:3 at 1440, or horizontal cutoff near 1440 in a 1920 raster | Core Media; vDSP | Direct / Derived | **Source** | Medium |
| Low, shadow-weighted sensor noise | Digital camera | Group 9 grain-against-luma profile | vImage | Derived | **Source** | Medium |
| Rolling-shutter skew | CMOS camera | Vertical shear correlated with horizontal pan from optical flow | VideoToolbox optical flow | Derived | **Source** | Low |
| True 10-bit content | Modern pipeline | Group 5 effective bit depth | vImage | Derived | **Source** | High |
| HDR metadata with matching measured range | Modern UHD master | Group 5 | Core Media; vImage | Direct / Derived | **Source** | High |
| Wide colour content actually used | BT.2020 or P3 content beyond 709 | Gamut occupancy | Core Image | Derived | **Source** | Medium |
| 50 or 59.94 native unique-frame rate | Modern broadcast or camera | Group 3 | Custom temporal analysis | Derived | **Source** | High |
| Phone signs: VFR, rotation, camera metadata keys | Phone camera | Groups 1 to 3 | AVFoundation | Direct | **Source** | Medium |

### 14. Scaling, restoration and transcoding evidence

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Transcoder named in metadata | A transcode certainly happened | Group 1 encoder tags | MediaInfo | Direct | Processing | High |
| Upscale | Detail below raster | Group 7 upscale ratio | Computed | Derived | Processing | Medium to high |
| Borders scaled with the picture | Bordered image was resized later | Group 2 border edge sharpness | vImage | Derived | Processing | Medium |
| Foreign block grid | Earlier lossy generation | Group 8 | vDSP | Derived | Processing | High when found |
| Two keyframe periodicities | Two encoders | Group 8 keyframe pumping | Custom temporal analysis | Derived | Processing | Medium |
| Deinterlaced | An interlaced stage was flattened before this encode | Group 4 residue measures | Custom temporal analysis | Derived | Processing | Medium |
| Frame-rate converted | Blends, periodic duplicates, judder | Group 3 | Custom temporal analysis | Derived | Processing | Medium to high |
| Inverse telecine done, or not | 23.976 from 29.97, or 3:2 left in | Group 3 | Custom temporal analysis | Derived | Processing | High |
| Denoised | Low noise with texture loss, temporal smearing | Groups 7, 8, 9 | Computed | Derived | Processing | Medium |
| Sharpened | Halos and overshoot | Group 7 | vImage | Derived | Processing | Medium |
| Range or matrix converted wrongly | Washed or crushed, or a hue shift | Group 5 mismatch | Computed | Derived | Processing | High for range, Low for matrix |
| Cropped | Non-standard active size; grid phase offset | Groups 2 and 8 | Computed | Derived | Processing | Medium |
| Audio generations | Brick-wall lowpass below the current codec's own | Group 6 | vDSP | Derived | Processing | Medium |
| Restoration | Film signs present but dirt absent, stabilised weave, grain managed | Combination of group 9 | Computed | Derived | Processing | Low to medium |

### 15. Source-character inference

All rows here are inferences. Each is stored with a confidence and the ids of the evidence rows behind it, and shown with them.

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Film | Originated on film | Weighted evidence: film cadence, grain profile, weave, dirt, cinema aspect ratio | Rule engine over measured features | Inferred | Source | Medium |
| Analog video | Analog electronic origin | Composite signs, line jitter, analog noise, interlace residue, audio signs | Rule engine | Inferred | Source | Medium |
| VHS-like | Consumer tape specifically | Analog video plus very low chroma bandwidth, low horizontal luma, head switching or dropouts or tracking, narrow audio | Rule engine | Inferred | Source | Medium to high with two or more tape-specific signs |
| Digital SD | DVD, DV, SD broadcast | SD detail, clean signal, foreign 8×8 grid, PAR history | Rule engine | Inferred | Source | Medium |
| Early web / low-bitrate digital | Small, low-rate, heavily compressed origin | Very low detail, small foreign grid, low unique-frame rate, narrow audio | Rule engine | Inferred | Source | Medium to high |
| HD digital | Native HD camera or master | Detail matches raster at 720 to 1080, sensor-like noise, no analog or SD signs | Rule engine | Inferred | Source | Medium |
| UHD digital | Native UHD | Detail near 2160, 10-bit content, HDR or wide gamut in use | Rule engine | Inferred | Source | Medium |
| Unknown | Evidence insufficient or contradictory | No category above threshold, or two in conflict | Rule engine | Inferred | Source | n/a |
| Model's opinion | An independent, weak vote | On-device model on three or four triaged frames (macOS 27) | Foundation Models | Inferred | Source | Low; never decisive |

Start with transparent weighted rules, because every weight can be explained and corrected against files whose history is known. Only if the rules plateau should a learned classifier over the *measured features* replace them, and only after that an image model.

### 16. Production, acquisition and processing inference

Several may hold at once. Each carries confidence and evidence.

| Property | What It Tells Us | Extraction Method | Suggested Tool | Direct or Derived | Current Encode or Source Evidence | Reliability |
|---|---|---|---|---|---|---|
| Film acquisition | Shot on film | Group 15 film evidence | Rule engine | Inferred | Source | Medium |
| Film transferred to video / telecined | Film carried through an interlaced video stage | Film signs plus 3:2 or 2:2 residue, interlace residue, SD detail | Rule engine | Inferred | Source | Medium to high |
| Analog video acquisition | Tube or early CCD camera to tape | Analog signs without film signs | Rule engine | Inferred | Source | Medium |
| Tape-derived, VHS-derived copy | Came off tape, consumer tape | Group 10 evidence | Rule engine | Inferred | Source | Medium to high |
| Interlaced SD video acquisition | Video camera at 50 or 60 fields | Interlace residue, SD detail, no film cadence | Rule engine | Inferred | Source | Medium |
| Progressive SD digital acquisition | Early digital or web camera | SD detail, no interlace residue, no film signs | Rule engine | Inferred | Source | Low to medium |
| DVD / digital-SD source | Earlier MPEG-2 SD encode | Group 11 evidence | Rule engine | Inferred | Source | Medium |
| Low-bitrate web source | Came from a small, heavily compressed web file | Group 12 evidence | Rule engine | Inferred | Source | Medium to high |
| Native HD / UHD digital acquisition | Shot on a digital HD or UHD camera | Group 13 evidence | Rule engine | Inferred | Source | Medium |
| SD upscaled to HD, HD upscaled to UHD | The raster is larger than the picture it carries | Group 14 upscale with the group 15 class | Rule engine | Inferred | Processing | Medium to high |
| Deinterlaced | An interlaced source was made progressive | Group 14 evidence | Rule engine | Inferred | Processing | Medium |
| Frame-rate converted | The rate was changed after acquisition | Group 14 evidence | Rule engine | Inferred | Processing | Medium to high |
| Restored film, denoised, sharpened | The picture was cleaned or enhanced | Group 14 evidence | Rule engine | Inferred | Processing | Low to medium |
| Previously compressed; multiple generations | At least one lossy encode preceded this one | Foreign grid, double keyframe period, audio lowpass, transcoder tag | Rule engine | Inferred | Processing | Medium to high |

The only conclusions here that may be stated as fact are those established by reliable metadata: that the file was written by a named transcoder, and what that transcoder's settings were.

## Recommended pipeline

Each stage is a separate, cancellable step of one background job, run through the app's existing job runner, one file at a time. Results are written as they are produced, so a stopped job loses one stage, not a file.

| Stage | What runs | Tool | Cost |
|---|---|---|---|
| **0. Declared** | Container, tracks, format descriptions and their extensions: codec, profile bytes, PAR, clean aperture, field count, colour tags, HDR metadata, transform, audio description | AVFoundation, Core Media | Milliseconds |
| **0b. Declared, supplementary** | Encoder settings string, bitrate mode, frame-rate mode, profile and level named; per-frame picture types and flags; GOP structure | MediaInfo, ffprobe, when installed | Under a second |
| **1. Timing** | Every sample's presentation time and sync flag, no decode: real frame rate, CFR/VFR, jitter, keyframe interval, exact video bitrate | `AVAssetReader` with no output settings | About a second |
| **2. Stills** | 16 triaged frames decoded to bi-planar Y'CbCr, 8 or 10 bit, never RGB: geometry, spectra and detail class, edge width and halos, noise residual and its spectrum, block-grid and foreign-grid search, banding, colour statistics, chroma bandwidth | `AVAssetImageGenerator` for seeking or `AVAssetReader`; vImage, vDSP, Core Image | A few seconds |
| **3. Sequences** | Four 10-second windows decoded frame by frame: duplicate and repeat patterns, blending, combing residue on motion, field signs, jitter and flagging, dropouts, tracking bars, head switching, flicker, weave, mosquito noise, keyframe pumping | `AVAssetReader`; vImage, vDSP; VideoToolbox optical flow and temporal noise filter | Tens of seconds |
| **4. Audio** | Whole track decoded to float PCM: loudness, peaks, clipping, long-term spectrum and roll-off, lowpass shape, noise floor, hum, line whistle, channel correlation | `AVAssetReader`; vDSP | Seconds |
| **5. Evidence** | Measurements turned into evidence rows with thresholds calibrated on this library | Pure Swift in the kit | Negligible |
| **6. Inference** | Weighted rules over evidence; categories from groups 15 and 16, each with confidence and evidence ids | Pure Swift in the kit | Negligible |
| **6b. Opinion, optional** | Three or four triaged frames to the on-device model for a typed opinion; stored as such | Foundation Models, macOS 27 only | About six seconds a frame |

**Decode to Y'CbCr, not RGB.** Chroma bandwidth, chroma offset, range and bit-depth occupancy are all destroyed or blurred by a conversion to RGB. Request `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` or the 10-bit equivalent and work on the planes.

**Where MediaInfo and ffprobe are substantially better.** The x264/x265 settings string, bitrate mode, and named profile and level (MediaInfo); per-frame picture type, interlace and repeat flags, and HDR side data in one call (ffprobe). All of it is declared-layer information about the current encode. None of it is needed for the source analysis, which is why both can be optional.

**Where FFmpeg earns its place.** As the reference during research: run `idet`, `cropdetect`, `signalstats`, `blockdetect`, `blurdetect`, `siti`, `mpdecimate`, `ebur128`, `astats` and `aspectralstats` beside the native implementation on the same files, and treat agreement as the acceptance test. After that it is not required at run time.

**Where Core ML is reserved.** Nothing in the first version. The candidates, once there is a labelled set: a small classifier over measured features to replace hand weights; and, last, an image model for the film-against-video "look" that deterministic features capture only partly.

## Storage

Results live in the library's SQLite file, beside the items they describe, in four tables that mirror the four layers: declared properties, measurements (per frame and per window, with a summary row), evidence, and inferences with a join to the evidence that supports them. Each row carries the analyser version that produced it, so thresholds can be recalibrated and inferences recomputed from stored measurements without decoding anything again. Nothing is written to the media files.

## Build order

1. Stages 0 and 1, the four tables, and the job. Replaces the placeholder in `QualityScore` with real declared data.
2. Stage 2 geometry and effective resolution, with `cropdetect` and the spectrum experiment above as references. This alone answers "is this an upscale" and "is there a 4:3 picture in here".
3. Stage 4 audio. Cheap, and the roll-off, whistle and hum signs are among the most reliable source evidence there is.
4. Stage 3 cadence and interlace residue.
5. Noise, grain and tape-specific signs.
6. Foreign-grid search and the rest of the compression measurements.
7. Stages 5 and 6, calibrated against a set of files whose history is actually known.

Step 7 depends on something no tool can supply: a few dozen files from this library whose real origin is known, to calibrate against and to test the inferences on. Without that set the measurements are sound and the inferences are guesses with numbers on them.
