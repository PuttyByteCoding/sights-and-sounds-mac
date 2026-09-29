import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The Operations slider offers half-second OCR sampling. The job floored
/// the interval at one second and the frame estimate at a tenth, so 0.5 s
/// scanned at 1 s without saying so and the estimate promised twice the
/// frames that ran. One minimum now serves the slider, the estimate and
/// the job.
@Suite struct OcrIntervalTests {
    @Test func theEstimateAndTheJobShareOneMinimum() {
        #expect(OcrJob.minimumSampleIntervalSeconds == 0.5)
        #expect(OcrJob.effectiveInterval(0.5) == 0.5)
        #expect(OcrJob.effectiveInterval(0.1) == 0.5)
        #expect(OcrJob.effectiveInterval(3) == 3)
        // Ten seconds at a requested 0.2 s: what the job will read.
        #expect(OcrJob.frameCount(durations: [10], sampleIntervalSeconds: 0.2) == 20)
        #expect(OcrJob.frameCount(durations: [10], sampleIntervalSeconds: 0.5) == 20)
    }
}
