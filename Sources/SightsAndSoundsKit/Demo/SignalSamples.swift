import Foundation

/// Media Signal samples: short synthetic files built to show one property
/// each, with the truth they were built with written beside them.
///
/// The analysis reads what a file is and guesses where it came from, and
/// its thresholds were set without files of known origin. These are
/// files whose every property is known because they were made to order:
/// a raster, a scan type, a frame timing, a picture area, a detail limit,
/// a soundtrack, a cadence, a range, a depth, a chroma bandwidth, a
/// noise level. `SignalSampleCorpusTests` runs the stages over them and
/// holds each reading to its truth; the app can write them into a
/// library of their own to look at.
///
/// Built with ffmpeg's own test sources, so nothing here is anyone's
/// footage. Pictures are H.264 at a high quality unless the property
/// needs otherwise (10-bit HEVC for depth); soundtracks are Apple
/// Lossless, so the encode cannot move the truth.
public struct SignalSample: Sendable, Identifiable {
    public enum Topic: String, Sendable, CaseIterable {
        case resolution = "Resolution"
        case scan = "Interlaced and Progressive"
        case timing = "Frame Timing"
        case pictureArea = "Active Picture Area"
        case detail = "Effective Resolution"
        case sound = "Soundtrack"
        case cadence = "Cadence and Residue"
        case tone = "Range, Depth, Chroma and Noise"
    }

    /// What the file was built to be, as a reading.
    public enum Truth: Sendable {
        /// A declared value, exactly.
        case declared(String, String)
        /// A measured value inside a range.
        case measured(String, ClosedRange<Double>)
        /// A reading that must be withheld: absent from the findings.
        case withheld(String)
        /// Evidence the rules draw from the findings, at a strength in the
        /// range (0...0 for "must not be drawn") — for what only shows when
        /// two readings are set side by side.
        case evidence(String, ClosedRange<Double>)
        /// A conclusion the rules draw — what reaches the screen — at a
        /// confidence in the range (0...0 for "must not be drawn").
        case concluded(String, ClosedRange<Double>)
        /// A truth the analysis does not reach yet, and why. The corpus
        /// still checks it and reports it as known, so a fix shows up.
        indirect case gap(Truth, String)
    }

    public let id: String
    public let topic: Topic
    /// One line: what the file is.
    public let summary: String
    /// ffmpeg arguments up to, not including, the output path.
    public let arguments: [String]
    public let fileExtension: String
    public let kind: MediaKind
    /// The stages worth running on it (`SignalStage.name`).
    public let stages: [String]
    public let truths: [Truth]

    public var fileName: String { "\(id).\(fileExtension)" }
    public var relativePath: String { "\(topic.rawValue)/\(fileName)" }
}

public enum SignalSamples {
    // MARK: - Building blocks

    /// High-quality H.264, square or declared pixels, 4:2:0. Close to
    /// lossless, so the picture's own properties survive the encode.
    static let h264 = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "10", "-pix_fmt", "yuv420p"]
    /// Moving test pattern: sharp edges, text, a moving disc.
    static func motion(_ size: String, _ rate: String, seconds: Double = 4) -> [String] {
        ["-f", "lavfi", "-t", "\(seconds)", "-i", "testsrc2=size=\(size):rate=\(rate)"]
    }
    /// A still, detailed backdrop (a grid, rich in vertical detail) with a
    /// test pattern moving across it — how most footage is: a still scene
    /// with something moving in it. testsrc2 alone has almost nothing that
    /// stays still, and a bob's sign lives in the parts that do.
    static func motionOverStill(_ rate: String, seconds: Double = 4) -> [String] {
        ["-f", "lavfi", "-t", "\(seconds)", "-i",
         "testsrc2=size=200x150:rate=\(rate)[moving];"
            + "color=c=0x404040:size=720x480:rate=\(rate),drawgrid=w=12:h=9:t=2:c=0xd0d0d0[still];"
            + "[still][moving]overlay=x='mod(n*6,520)':y=160"]
    }

    /// Fractal zoom: detail at every scale, like a real picture has —
    /// rendered at twice the size and brought down with a good filter,
    /// the way a sensor oversamples. Rendered straight at size, every
    /// pixel is a sharp sample of an infinitely fine edge, which aliases
    /// into a flat top of the spectrum that looks exactly like noise.
    static func detail(_ size: String, _ rate: String = "24", seconds: Double = 3) -> [String] {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        let double = "\(parts[0] * 2)x\(parts[1] * 2)"
        return ["-f", "lavfi", "-t", "\(seconds)", "-i",
                "mandelbrot=size=\(double):rate=\(rate):maxiter=120:start_scale=1.5,scale=\(size):flags=lanczos"]
    }
    /// A luma ramp written as raw code values, so no range conversion can
    /// move it: `high` at both edges falling to `low` in the middle, colour
    /// neutral. Darkest in the middle, because a dark strip at an edge is
    /// what a pillarbox bar looks like, and the picture area would be
    /// measured inside it.
    static func levels(low: Int, high: Int) -> [String] {
        ["-f", "lavfi", "-t", "2", "-i",
         "color=size=640x360:rate=24,format=yuv420p,"
            + "geq=lum='\(low)+(\(high)-\(low))*abs(2*X/W-1)':cb=128:cr=128"]
    }
    static let noAudio = ["-an"]
    /// 8 s of pink noise, 48 kHz.
    static func pink(seed: Int = 1, amplitude: Double = 0.25, seconds: Int = 8) -> String {
        "anoisesrc=color=pink:amplitude=\(amplitude):seed=\(seed):sample_rate=48000:duration=\(seconds)"
    }
    static let alac = ["-c:a", "alac", "-ar", "48000"]

    static let declaredStage = "declared"
    static let probeStage = "probeTools"
    static let timingStage = "frameTiming"
    static let audioStage = "audioSignal"
    static let stillsStage = "pictureStills"
    static let sequenceStage = "pictureSequences"

    // MARK: - The samples

    public static let all: [SignalSample] =
        resolution + scan + timing + pictureArea + detailSamples + sound + cadence + tone

    static func video(
        _ id: String, _ topic: SignalSample.Topic, _ summary: String,
        input: [String], filter: String? = nil, codec: [String] = h264, extra: [String] = [],
        ext: String = "mp4", stages: [String], truths: [SignalSample.Truth]
    ) -> SignalSample {
        SignalSample(
            id: id, topic: topic, summary: summary,
            arguments: input + (filter.map { ["-vf", $0] } ?? []) + codec + extra + noAudio,
            fileExtension: ext, kind: .video, stages: stages, truths: truths)
    }

    static func audio(
        _ id: String, _ summary: String, graph: String, truths: [SignalSample.Truth]
    ) -> SignalSample {
        SignalSample(
            id: id, topic: .sound, summary: summary,
            arguments: ["-filter_complex", graph, "-map", "[out]"] + alac,
            fileExtension: "m4a", kind: .audio, stages: [audioStage], truths: truths)
    }

    // MARK: Resolution — standard and not

    static let resolution: [SignalSample] = {
        func raster(
            _ id: String, _ summary: String, _ w: Int, _ h: Int, sar: String = "1",
            standardAspect: Double? = nil, extraTruths: [SignalSample.Truth] = []
        ) -> SignalSample {
            var truths: [SignalSample.Truth] = [
                .declared("video.encodedWidth", "\(w)"),
                .declared("video.encodedHeight", "\(h)"),
            ]
            if let standardAspect {
                truths.append(.measured("geometry.encodedAspectRatio", standardAspect * 0.98...standardAspect * 1.02))
            }
            return video(
                id, .resolution, summary,
                input: motion("\(w)x\(h)", "24", seconds: 2), filter: "setsar=\(sar)",
                stages: [declaredStage, stillsStage], truths: truths + extraTruths)
        }
        return [
            raster("1920x1080 HD", "Full HD, square pixels, 16:9.", 1920, 1080, standardAspect: 16.0 / 9),
            raster("1280x720 HD", "720p HD, square pixels, 16:9.", 1280, 720, standardAspect: 16.0 / 9),
            raster(
                "720x480 NTSC widescreen", "NTSC DVD raster, anamorphic 16:9 (pixels 32:27).",
                720, 480, sar: "32/27", standardAspect: 16.0 / 9,
                extraTruths: [.declared("video.pixelAspectRatio", "32:27")]),
            raster(
                "720x576 PAL 4x3", "PAL DVD raster, 4:3 (pixels 16:15).",
                720, 576, sar: "16/15", standardAspect: 4.0 / 3,
                extraTruths: [.declared("video.pixelAspectRatio", "16:15")]),
            raster("640x480 VGA", "VGA, square pixels, 4:3 — early web and webcams.", 640, 480, standardAspect: 4.0 / 3),
            raster("352x240 SIF", "Video CD / early web raster.", 352, 240),
            raster("1000x562 odd", "Not a standard raster: a crop or a web export.", 1000, 562),
            raster("854x480 web", "The common web 480p width, not a broadcast raster.", 854, 480),
            raster("1440x1080 HDV", "HDV: 1440 stored, shown 16:9 (pixels 4:3).", 1440, 1080, sar: "4/3", standardAspect: 16.0 / 9,
                   extraTruths: [.declared("video.pixelAspectRatio", "4:3")]),
        ]
    }()

    // MARK: Interlaced and progressive

    static let scan: [SignalSample] = [
        video(
            "progressive 29.97", .scan, "Progressive frames, declared progressive.",
            input: motion("720x480", "30000/1001"),
            stages: [declaredStage, sequenceStage],
            truths: [.measured("interlace.combedFrameFraction", 0...0.05)]),
        video(
            "interlaced tff declared", .scan,
            "True interlace from 59.94 moving frames, top field first, declared interlaced.",
            input: motion("720x480", "60000/1001"), filter: "interlace=scan=tff:lowpass=0",
            extra: ["-flags", "+ilme+ildct", "-x264opts", "tff=1"],
            stages: [declaredStage, probeStage, sequenceStage],
            // An MP4 has no fiel atom, so AVFoundation declares nothing about
            // fields; the bitstream's own flags are read by ffprobe.
            truths: [
                .declared("ffprobe.video.field_order", "tt"),
                .measured("interlace.combedFrameFraction", 0.3...1),
            ]),
        video(
            "interlaced tff declared prores", .scan,
            "The same as interlaced ProRes in a QuickTime file, whose fiel atom declares the fields.",
            input: motion("720x480", "60000/1001"), filter: "interlace=scan=tff:lowpass=0",
            codec: ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le", "-flags", "+ildct+ilme", "-field_order", "tt"],
            ext: "mov", stages: [declaredStage, sequenceStage],
            truths: [.declared("video.fieldCount", "2"), .measured("interlace.combedFrameFraction", 0.3...1)]),
        video(
            "interlaced stored progressive", .scan,
            "The same interlaced frames, but encoded (and declared) as progressive.",
            input: motion("720x480", "60000/1001"), filter: "interlace=scan=tff:lowpass=0",
            stages: [declaredStage, sequenceStage],
            truths: [.measured("interlace.combedFrameFraction", 0.3...1)]),
        video(
            "bob deinterlaced 59.94", .scan,
            "Interlaced, then bob-deinterlaced to 59.94 frames: alternate frames sit half a line apart.",
            input: motionOverStill("60000/1001"), filter: "interlace=scan=tff:lowpass=0,yadif=mode=send_field",
            stages: [sequenceStage],
            truths: [
                .measured("interlace.combedFrameFraction", 0...0.05),
                .gap(.measured("interlace.bobFlutter", 0.3...1),
                     "yadif's bob is motion-adaptive: it weaves still areas from both fields, so nothing "
                        + "flutters; it would need another sign (double rate with halved vertical detail in motion)"),
            ]),
        video(
            "naive bob 59.94", .scan,
            "Interlaced, then each field line-doubled into its own frame: still areas flip half a line, frame to frame.",
            input: motionOverStill("60000/1001"),
            filter: "interlace=scan=tff:lowpass=0,separatefields,scale=720:480:flags=bilinear,setsar=1",
            stages: [sequenceStage],
            truths: [
                .measured("interlace.combedFrameFraction", 0...0.05),
                .measured("interlace.bobFlutter", 0.3...1),
            ]),
        video(
            "field deinterlaced 29.97", .scan,
            "Interlaced, then deinterlaced to 29.97 frames: no combs, vertical detail halved in motion.",
            input: motion("720x480", "60000/1001"), filter: "interlace=scan=tff:lowpass=0,yadif=mode=send_frame",
            stages: [sequenceStage],
            truths: [.measured("interlace.combedFrameFraction", 0...0.05)]),
    ]

    // MARK: Frame timing

    static let timing: [SignalSample] = {
        func cfr(_ label: String, _ rate: String, _ value: Double) -> SignalSample {
            video(
                "constant \(label)", .timing, "Constant \(label) frames a second.",
                input: motion("640x360", rate), stages: [declaredStage, timingStage],
                truths: [
                    .measured("timing.averageFrameRate", value - 0.02...value + 0.02),
                    .measured("timing.constantFrameRate", 1...1),
                ])
        }
        return [
            cfr("23.976", "24000/1001", 23.976),
            cfr("25", "25", 25),
            cfr("29.97", "30000/1001", 29.97),
            cfr("50", "50", 50),
            cfr("59.94", "60000/1001", 59.94),
            video(
                "variable rate", .timing,
                "Variable frame rate: frame intervals wander between about 29 and 38 ms, as a phone records.",
                input: motion("640x360", "30"),
                filter: "settb=1/90000,setpts='(N/30+0.006*sin(N*0.7))/TB'",
                extra: ["-fps_mode", "passthrough", "-enc_time_base", "1/90000", "-video_track_timescale", "90000"],
                stages: [timingStage],
                truths: [
                    .measured("timing.constantFrameRate", 0...0),
                    .measured("timing.intervalJitterSeconds", 0.002...0.02),
                ]),
        ]
    }()

    // MARK: Active picture area

    static let pictureArea: [SignalSample] = [
        video(
            "full frame 16x9", .pictureArea, "Picture to every edge.",
            input: detail("1280x720"),
            stages: [stillsStage],
            truths: [
                .measured("geometry.letterboxed", 0...0), .measured("geometry.pillarboxed", 0...0),
                .measured("geometry.activeAspectRatio", 1.74...1.82),
            ]),
        video(
            "letterbox 2.39 in 16x9", .pictureArea, "A 2.39 scope picture with black bars top and bottom.",
            input: detail("1280x536"), filter: "pad=1280:720:0:92:black",
            stages: [stillsStage],
            truths: [.measured("geometry.letterboxed", 1...1), .measured("geometry.activeAspectRatio", 2.3...2.45)]),
        video(
            "pillarbox 4x3 in 16x9", .pictureArea, "A 4:3 picture with black bars left and right.",
            input: detail("960x720"), filter: "pad=1280:720:160:0:black",
            stages: [stillsStage],
            truths: [.measured("geometry.pillarboxed", 1...1), .measured("geometry.activeAspectRatio", 1.28...1.38)]),
        video(
            "windowbox", .pictureArea, "Bars on all four sides: a letterboxed picture pillarboxed again.",
            input: detail("1024x432"), filter: "pad=1280:720:128:144:black",
            stages: [stillsStage],
            truths: [
                .measured("geometry.letterboxed", 1...1), .measured("geometry.pillarboxed", 1...1),
                .measured("geometry.activeAspectRatio", 2.3...2.45),
            ]),
        video(
            "noisy grey borders", .pictureArea,
            "Bars that are not clean black: lifted a little and noisy, as captured from tape.",
            input: detail("960x720"), filter: "pad=1280:720:160:0:0x0a0a0a,noise=alls=10:allf=t",
            stages: [stillsStage],
            truths: [.measured("geometry.pillarboxed", 1...1), .measured("geometry.borderNoise", 1.5...100)]),
        video(
            "soft border edges", .pictureArea,
            "Bars added before a scaling: the edge between bar and picture is several pixels wide.",
            input: detail("480x360"), filter: "pad=640:360:80:0:black,scale=1280:720:flags=bicubic",
            stages: [stillsStage],
            truths: [.measured("geometry.pillarboxed", 1...1), .measured("geometry.borderEdgeWidth", 2...20)]),
    ]

    // MARK: Effective resolution

    static let detailSamples: [SignalSample] = [
        video(
            "native 1280x720", .detail, "Detail right up to the raster: nothing scaled.",
            input: detail("1280x720"),
            stages: [stillsStage],
            truths: [.measured("detail.effectiveWidth", 960...1300), .measured("detail.effectiveHeight", 540...740)]),
        video(
            "upscaled from 640x360", .detail, "Made at 640x360, scaled up to 1280x720: half the detail the raster could hold.",
            input: detail("640x360"), filter: "scale=1280:720:flags=bicubic",
            stages: [stillsStage],
            truths: [.measured("detail.effectiveWidth", 480...800), .measured("detail.effectiveHeight", 270...450)]),
        video(
            "upscaled from 320x180", .detail, "Made at 320x180, scaled up to 1280x720.",
            input: detail("320x180"), filter: "scale=1280:720:flags=bicubic",
            stages: [stillsStage],
            truths: [.measured("detail.effectiveWidth", 240...420), .measured("detail.effectiveHeight", 135...240)]),
        video(
            "soft horizontally 720x480", .detail,
            "Tape-like: 360 columns of detail stretched to 720, all 480 lines kept.",
            input: detail("360x480"), filter: "scale=720:480:flags=bicubic,setsar=1",
            stages: [stillsStage],
            truths: [.measured("detail.effectiveWidth", 270...460), .measured("detail.effectiveHeight", 380...490)]),
        video(
            "detail lost in noise", .detail,
            "Upscaled from 640x360 and then heavily noised: the true detail limit lies in the noise, so no width may be claimed.",
            input: detail("640x360"), filter: "scale=1280:720:flags=bicubic,noise=alls=40:allf=t",
            stages: [stillsStage],
            truths: [.withheld("detail.effectiveWidth"), .measured("detail.noiseLimitedShare", 0.5...1)]),
    ]

    // MARK: Soundtrack

    static let sound: [SignalSample] = [
        audio(
            "loudness -23 LUFS", "Pink noise at the broadcast target.",
            graph: "\(pink()),loudnorm=I=-23:LRA=5:TP=-2:linear=true,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.integratedLoudnessLufs", -25 ... -21)]),
        audio(
            "loudness -9 LUFS", "A steady tone mastered loud (noise cannot get there under a peak limit).",
            graph: "sine=f=997:sample_rate=48000:duration=8,loudnorm=I=-9:LRA=5:TP=-1:linear=true,"
                + "aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.integratedLoudnessLufs", -12 ... -7)]),
        audio(
            "loudness -35 LUFS", "Pink noise, very quiet.",
            graph: "\(pink(amplitude: 0.05)),loudnorm=I=-35:LRA=5:TP=-9:linear=true,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.integratedLoudnessLufs", -38 ... -32)]),
        audio(
            "bandwidth full", "White noise to 24 kHz: digital, nothing cut.",
            graph: "anoisesrc=color=white:amplitude=0.2:sample_rate=48000:duration=8,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.bandwidth40Hz", 19_000...24_000)]),
        audio(
            "bandwidth 16k brick wall", "Cut hard at 16 kHz, as a 128 kbit/s MP3 generation does.",
            graph: "anoisesrc=color=white:amplitude=0.2:sample_rate=48000:duration=8,"
                + "firequalizer=gain='if(lt(f,16000),0,-120)':delay=0.05,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.bandwidth40Hz", 15_000...17_500)]),
        audio(
            "bandwidth 10k gentle", "A gentle analog roll-off, gone by about 12 kHz, as VHS linear audio is.",
            graph: "anoisesrc=color=white:amplitude=0.3:sample_rate=48000:duration=8,"
                + "lowpass=f=7000:poles=2,lowpass=f=7000:poles=2,lowpass=f=7000:poles=2,aformat=channel_layouts=stereo[out]",
            truths: [
                .measured("audio.bandwidth40Hz", 9_000...14_000),
                .measured("audio.rolloffSteepnessDbPerKhz", 0...12),
            ]),
        audio(
            "bandwidth 10k true stereo", "Two independent hisses, each rolled off gently: a stereo tape transfer.",
            graph: "anoisesrc=color=white:amplitude=0.3:seed=1:sample_rate=48000:duration=8,"
                + "lowpass=f=7000:poles=2,lowpass=f=7000:poles=2,lowpass=f=7000:poles=2[l];"
                + "anoisesrc=color=white:amplitude=0.3:seed=2:sample_rate=48000:duration=8,"
                + "lowpass=f=7000:poles=2,lowpass=f=7000:poles=2,lowpass=f=7000:poles=2[r];"
                + "[l][r]amerge=inputs=2[out]",
            truths: [
                .measured("audio.bandwidth40Hz", 9_000...14_000),
                .measured("audio.channelCorrelation", -0.2...0.2),
            ]),
        audio(
            "mono as stereo", "One channel copied into two.",
            graph: "\(pink()),pan=stereo|c0=c0|c1=c0[out]",
            truths: [
                .measured("audio.monoAsStereo", 1...1),
                .measured("audio.channelCorrelation", 0.98...1.001),
            ]),
        audio(
            "true stereo", "Two independent channels.",
            graph: "\(pink(seed: 1))[l];\(pink(seed: 2))[r];[l][r]amerge=inputs=2[out]",
            truths: [
                .measured("audio.monoAsStereo", 0...0),
                .measured("audio.channelCorrelation", -0.2...0.2),
            ]),
        audio(
            "out of phase", "The right channel inverted: a wiring or azimuth fault.",
            graph: "\(pink()),pan=stereo|c0=c0|c1=-1*c0[out]",
            truths: [
                .measured("audio.channelCorrelation", -1.001 ... -0.95),
                .measured("audio.bandwidth40Hz", 19_000...24_000),
            ]),
        audio(
            "hum 50 Hz", "Mains hum at 50 Hz and harmonics under quiet passages — a PAL-region analog chain. "
                + "A minute long: hum is read from the quietest sixteen seconds.",
            graph: "\(pink(seconds: 60)),volume=volume=0.01:enable='gte(mod(t,2),1)'[p];"
                + "sine=f=50:sample_rate=48000:duration=60,volume=0.08[h1];"
                + "sine=f=100:sample_rate=48000:duration=60,volume=0.04[h2];"
                + "sine=f=150:sample_rate=48000:duration=60,volume=0.04[h3];"
                + "[p][h1][h2][h3]amix=inputs=4:normalize=0,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.hum50Db", 10...80)]),
        audio(
            "hum 60 Hz", "Mains hum at 60 Hz and harmonics under quiet passages — an NTSC-region analog chain. "
                + "A minute long: hum is read from the quietest sixteen seconds.",
            graph: "\(pink(seconds: 60)),volume=volume=0.01:enable='gte(mod(t,2),1)'[p];"
                + "sine=f=60:sample_rate=48000:duration=60,volume=0.08[h1];"
                + "sine=f=120:sample_rate=48000:duration=60,volume=0.04[h2];"
                + "sine=f=180:sample_rate=48000:duration=60,volume=0.04[h3];"
                + "[p][h1][h2][h3]amix=inputs=4:normalize=0,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.hum60Db", 10...80)]),
        audio(
            "line whistle NTSC 15734 Hz", "The NTSC line frequency leaking into the sound.",
            graph: "\(pink()),lowpass=f=12000[p];sine=f=15734:sample_rate=48000:duration=8,volume=0.024[w];"
                + "[p][w]amix=inputs=2:normalize=0,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.lineWhistleHz", 15_700...15_770)]),
        audio(
            "line whistle PAL 15625 Hz", "The PAL line frequency leaking into the sound.",
            graph: "\(pink()),lowpass=f=12000[p];sine=f=15625:sample_rate=48000:duration=8,volume=0.024[w];"
                + "[p][w]amix=inputs=2:normalize=0,aformat=channel_layouts=stereo[out]",
            truths: [.measured("audio.lineWhistleHz", 15_590...15_660)]),
        audio(
            "clipped", "A tone driven far past full scale: flat tops.",
            // ffmpeg's sine is 1/8 of full scale: 32 times that is four
            // times past it.
            graph: "sine=f=440:sample_rate=48000:duration=8,volume=32,"
                + "aformat=sample_fmts=s16:channel_layouts=stereo[out]",
            truths: [.measured("audio.clippedFraction", 0.01...1)]),
        audio(
            "clean tone", "A tone with headroom: nothing clipped.",
            graph: "sine=f=440:sample_rate=48000:duration=8,volume=4,aformat=channel_layouts=stereo[out]",
            truths: [
                .measured("audio.clippedFraction", 0...0.0001),
                .withheld("audio.lineWhistleHz"),
                .withheld("audio.hum60Db"),
            ]),
    ]

    // MARK: Cadence and residue

    static let cadence: [SignalSample] = [
        video(
            "film 24p clean", .cadence, "23.976 progressive frames, every one new.",
            input: motion("720x480", "24000/1001"),
            stages: [sequenceStage],
            truths: [.measured("cadence.duplicateFraction", 0...0.02), .measured("interlace.combedFrameFraction", 0...0.05)]),
        video(
            "telecine 3-2", .cadence,
            "23.976 film telecined to 29.97 by 3:2 pulldown: two frames in five are combed.",
            input: motion("720x480", "24000/1001"), filter: "telecine=first_field=top:pattern=23",
            stages: [sequenceStage],
            truths: [.measured("interlace.combedPeriod", 5...5), .measured("interlace.combedFrameFraction", 0.3...0.5)]),
        video(
            "repeated frames 24 to 30", .cadence,
            "23.976 film brought to 29.97 by repeating one frame in five.",
            input: motion("720x480", "24000/1001"), filter: "fps=30000/1001",
            stages: [sequenceStage],
            truths: [.measured("cadence.duplicatePeriod", 5...5), .measured("cadence.duplicateFraction", 0.15...0.25)]),
        video(
            "blended 24 to 30", .cadence,
            "23.976 film brought to 29.97 by blending neighbours: ghosted frames, no repeats.",
            input: motion("720x480", "24000/1001"), filter: "framerate=fps=30000/1001",
            stages: [sequenceStage],
            truths: [
                .gap(.measured("cadence.blendedFraction", 0.1...1), "a blending rate conversion is not detected yet"),
                .measured("cadence.duplicateFraction", 0...0.05),
            ]),
        video(
            "low native rate 15 in 30", .cadence,
            "Captured at 15 frames a second and stored at 30: every frame twice — early web or webcam.",
            input: motion("640x480", "15"), filter: "fps=30",
            stages: [sequenceStage],
            truths: [.measured("cadence.duplicateFraction", 0.45...0.55), .measured("cadence.duplicatePeriod", 2...2)]),
        video(
            "PAL 2-2 progressive in interlace", .cadence,
            "25 progressive frames carried as 50 fields (2:2): both fields of a frame match, so no combs.",
            input: motion("720x576", "25"), filter: "setfield=tff",
            codec: ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le", "-flags", "+ildct+ilme", "-field_order", "tt"],
            ext: "mov", stages: [declaredStage, sequenceStage],
            truths: [.declared("video.fieldCount", "2"), .measured("interlace.combedFrameFraction", 0...0.05)]),
    ]

    // MARK: Range, depth, chroma and noise

    static let tone: [SignalSample] = [
        video(
            "video range tagged video", .tone, "Levels 16–235, declared video range: correct.",
            input: levels(low: 16, high: 235), filter: "setparams=range=tv",
            stages: [declaredStage, stillsStage],
            truths: [
                .declared("video.range", "video"),
                .measured("colour.belowVideoBlackShare", 0...0.01),
                .measured("colour.usesFullRange", 0...0),
                .evidence("rangeBeyondItsTag", 0...0),
                .evidence("videoLevelsInAFullTag", 0...0),
                .concluded("Range converted wrongly", 0...0),
            ]),
        video(
            "full range tagged video", .tone,
            "Levels 0–255 declared as 16–235: blacks crushed and whites clipped on playback.",
            input: levels(low: 0, high: 255), filter: "setparams=range=tv",
            stages: [declaredStage, stillsStage],
            truths: [
                .declared("video.range", "video"),
                .measured("colour.usesFullRange", 1...1),
                .evidence("rangeBeyondItsTag", 0.5...1),
                .concluded("Range converted wrongly", 0.5...1),
            ]),
        video(
            "video range tagged full", .tone,
            "Levels 16–235 declared as full range: washed out on playback.",
            input: levels(low: 16, high: 235), filter: "setparams=range=pc",
            stages: [declaredStage, stillsStage],
            truths: [
                .declared("video.range", "full"),
                .evidence("videoLevelsInAFullTag", 0.5...1),
                .concluded("Range converted wrongly", 0.5...1),
            ]),
        video(
            "video range tagged full, grainy", .tone,
            "Video-range levels with grain, declared full range: the extremes overshoot 16–235 a little, "
                + "short of full range, and it still plays washed out.",
            input: levels(low: 16, high: 235),
            filter: "noise=alls=10:allf=t,setparams=range=pc",
            codec: ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p"],
            stages: [declaredStage, stillsStage],
            truths: [
                .declared("video.range", "full"),
                .measured("colour.usesFullRange", 0...0),
                .concluded("Range converted wrongly", 0.5...1),
            ]),
        video(
            "lifted and flattened", .tone,
            "Levels squeezed into 40–200: a range conversion applied twice. Never near black or white.",
            input: levels(low: 40, high: 200), filter: "setparams=range=tv",
            stages: [stillsStage],
            truths: [.measured("colour.washedOut", 1...1)]),
        video(
            "10-bit real", .tone, "10-bit HEVC holding a 10-bit ramp: the low bits carry picture.",
            // Written as raw 10-bit code values: ffmpeg's gradients source
            // picks random colours each run, so a sample built on it read
            // differently every time.
            input: ["-f", "lavfi", "-t", "2", "-i",
                    "color=size=640x360:rate=24,format=yuv420p10le,geq=lum='64+X*(940-64)/W':cb=512:cr=512"],
            codec: ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le", "-x265-params", "lossless=1:log-level=error"],
            ext: "mov", stages: [declaredStage, stillsStage],
            truths: [.declared("video.bitDepth", "10"), .measured("colour.lowBitsUsedShare", 0.2...1)]),
        video(
            "10-bit holding 8-bit", .tone, "10-bit HEVC whose picture was an 8-bit ramp: the low bits are empty.",
            input: ["-f", "lavfi", "-t", "2", "-i",
                    "color=size=640x360:rate=24,format=yuv420p,geq=lum='16+X*219/W':cb=128:cr=128,format=yuv420p10le"],
            codec: ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le", "-x265-params", "lossless=1:log-level=error"],
            ext: "mov", stages: [declaredStage, stillsStage],
            truths: [.declared("video.bitDepth", "10"), .measured("colour.lowBitsUsedShare", 0...0.005)]),
        video(
            "chroma full", .tone, "Colour detail as sharp as 4:2:0 allows.",
            input: detail("1280x720"), filter: "hue=s=3",
            stages: [stillsStage],
            truths: [.measured("chroma.horizontalFill", 0.5...1.5)]),
        video(
            "chroma soft horizontally", .tone,
            "Colour smeared sideways while the picture stays sharp — analog tape's narrow colour bandwidth.",
            input: detail("1280x720"), filter: "hue=s=3,format=yuv444p,gblur=sigma=6:sigmaV=0.01:planes=6,format=yuv420p",
            stages: [stillsStage],
            truths: [.measured("chroma.horizontalFill", 0...0.35), .measured("chroma.horizontalToVerticalFill", 0...0.6)]),
        video(
            "monochrome", .tone, "Black and white: no colour at all.",
            input: detail("640x360"), filter: "hue=s=0",
            stages: [stillsStage],
            truths: [.measured("colour.monochrome", 1...1)]),
        video(
            "noise clean", .tone, "A clean digital picture: almost no noise.",
            input: detail("1280x720"),
            stages: [stillsStage],
            truths: [.measured("noise.sigma", 0...1.5)]),
        video(
            "noise moderate grain", .tone, "Moderate moving grain, as film or a small sensor adds.",
            input: detail("1280x720"), filter: "noise=alls=10:allf=t",
            stages: [stillsStage],
            truths: [.measured("noise.sigma", 2...8)]),
        video(
            "noise heavy", .tone,
            "Heavy noise over a picture that was upscaled: readings of detail and chroma lie in the noise and must be withheld.",
            input: detail("640x360"), filter: "scale=1280:720:flags=bicubic,noise=alls=40:allf=t",
            stages: [stillsStage],
            truths: [
                .measured("noise.sigma", 6...40),
                .withheld("detail.effectiveWidth"),
                .measured("detail.noiseLimitedShare", 0.5...1),
            ]),
    ]

    // MARK: - Writing

    /// Write one sample. ffmpeg writes to a working name and it is moved
    /// into place whole, so a failed sample leaves nothing half-written.
    public static func write(_ sample: SignalSample, into folder: URL, ffmpeg: String) throws -> URL {
        let url = folder.appendingPathComponent(sample.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let working = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(sample.fileExtension)")
        defer { try? FileManager.default.removeItem(at: working) }
        try FfmpegTool.run(sample.arguments + [working.path], tool: ffmpeg)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: working, to: url)
        return url
    }

    /// A library holding every sample: one source, one item per file with
    /// its truth in the notes, and a Topic tag per area so the sidebar
    /// narrows to one. The Media Signal sweep then reads them like any
    /// other library, and what it concludes can be set beside the truth.
    @discardableResult
    public static func makeLibrary(
        at libraryURL: URL, mediaFolder: URL, ffmpeg: String,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> LibraryDatabase {
        let library = try LibraryDatabase.open(at: libraryURL)
        try library.ensureInfo(name: "Signal Samples")
        let source = Source(name: "Signal Samples", rootPath: mediaFolder.path)
        let topic = TagCategory(name: "Topic")
        try await library.writer.write { db in
            try source.insert(db)
            try topic.insert(db)
        }
        var tagIDs: [SignalSample.Topic: UUID] = [:]
        for area in SignalSample.Topic.allCases {
            tagIDs[area] = try library.ensureTag(named: area.rawValue, inCategory: topic.id).id
        }
        for (index, sample) in all.enumerated() {
            let url = try write(sample, into: mediaFolder, ffmpeg: ffmpeg)
            let probe = await MediaProbe.probe(url: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            var item = MediaItem(
                sourceID: source.id, kind: sample.kind, relativePath: sample.relativePath,
                fileSize: size, durationSeconds: probe.durationSeconds,
                width: probe.width, height: probe.height,
                videoCodec: probe.videoCodec, audioCodec: probe.audioCodec,
                frameRate: probe.frameRate, bitrate: probe.bitrate,
                ingestDate: Date(), needsReview: false)
            item.notes = sample.summary + " Truth: " + sample.truths.map(\.description).joined(separator: "; ")
            let made = item
            try await library.writer.write { try made.insert($0) }
            if let tagID = tagIDs[sample.topic] { try library.assignTag(tagID, to: made.id) }
            progress(index + 1, all.count)
        }
        return library
    }
}

extension SignalSample.Truth: CustomStringConvertible {
    public var description: String {
        switch self {
        case .declared(let key, let value): "\(key) = \(value)"
        case .measured(let key, let range): "\(key) in \(range.lowerBound)…\(range.upperBound)"
        case .withheld(let key): "\(key) withheld"
        case .evidence(let key, let range): "evidence \(key) at \(range.lowerBound)…\(range.upperBound)"
        case .concluded(let category, let range): "concludes “\(category)” at \(range.lowerBound)…\(range.upperBound)"
        case .gap(let truth, _): "\(truth) (not yet read)"
        }
    }
}

extension SignalSample: CustomStringConvertible {
    public var description: String { id }
}

