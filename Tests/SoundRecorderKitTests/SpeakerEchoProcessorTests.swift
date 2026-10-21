import XCTest
@testable import SoundRecorderKit

final class SpeakerEchoProcessorTests: XCTestCase {
    func testDelayedEchoConvergesAndPreservesIndependentSpeech() throws {
        let processor = try SpeakerEchoProcessor()
        let frames = 480, blocks = 1800, delay = 4800
        var reference = [Float](repeating: 0, count: frames * blocks)
        var seed: UInt64 = 17
        var filtered: Float = 0
        for i in reference.indices {
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
            filtered = 0.75 * filtered + 0.25 * noise
            // Speech-like bursts let AEC distinguish the noise floor during pauses.
            let envelope = Float(max(0, sin(Double(i) * 2 * .pi * 2 / 48000)))
            reference[i] = filtered * 0.35 * envelope
        }
        var mic = [Float](repeating: 0, count: frames)
        var output = mic
        var rawEnergy = 0.0, cleanedEnergy = 0.0
        var localEnergy = 0.0, localOutput = 0.0
        for block in 0..<blocks {
            for f in 0..<frames {
                let i = block * frames + f
                let echo = i >= delay ? reference[i - delay] * 0.6 : 0
                // Independent, speech-band multi-tone enters after echo convergence.
                let local: Float = block >= 1200 ? Float(0.08 * sin(Double(i) * 2 * .pi * 311 / 48000)
                    + 0.04 * sin(Double(i) * 2 * .pi * 787 / 48000)) : 0
                mic[f] = echo + local
                if block >= 900 && block < 1200 { rawEnergy += Double(echo * echo) }
                if block >= 1500 { localEnergy += Double(local * local) }
            }
            try reference.withUnsafeBufferPointer { r in
                try mic.withUnsafeBufferPointer { m in
                    try output.withUnsafeMutableBufferPointer { o in
                        try processor.process(left: r.baseAddress! + block * frames,
                            right: r.baseAddress! + block * frames,
                            microphone: m.baseAddress!, cleaned: o.baseAddress!)
                    }
                }
            }
            if block >= 900 && block < 1200 { cleanedEnergy += output.reduce(0) { $0 + Double($1 * $1) } }
            if block >= 1500 { localOutput += output.reduce(0) { $0 + Double($1 * $1) } }
        }
        let reductionDB = 10 * log10(rawEnergy / max(cleanedEnergy, 1e-20))
        let retainedDB = 10 * log10(localOutput / max(localEnergy, 1e-20))
        print("WebRTC synthetic delayed echo reduction: \(reductionDB) dB; independent signal level: \(retainedDB) dB")
        XCTAssertGreaterThan(reductionDB, 20)
        XCTAssertGreaterThan(retainedDB, -6)
        XCTAssertLessThan(retainedDB, 3)
    }
}
