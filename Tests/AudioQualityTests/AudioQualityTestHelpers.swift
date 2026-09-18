// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import Accelerate

/// Independent structural and spectral quality oracles described in
/// `docs/audio-quality.md`. Spectral analysis uses Accelerate so it does not
/// share the MLX inference implementation under test.
enum AudioQualityAssertions {

    /// Criterion 1: Output sample rate must equal input sample rate (zero tolerance).
    static func assertSampleRatePreserved(
        input inputRate: Int,
        output outputRate: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(outputRate, inputRate,
            "Sample rate mismatch: input=\(inputRate), output=\(outputRate). " +
            "The sample rate invariant has been violated.",
            file: file, line: line)
    }

    /// Criterion 2: Output frame count must equal input frame count (zero tolerance).
    static func assertFrameCountPreserved(
        input inputCount: Int,
        output outputCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(outputCount, inputCount,
            "Frame count mismatch: input=\(inputCount), output=\(outputCount).",
            file: file, line: line)
    }

    /// Criterion 3: No clipped samples (|sample| > 1.0).
    static func assertNoClipping(
        samples: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (index, sample) in samples.enumerated() {
            if abs(sample) > 1.0 {
                XCTFail("Clipped sample at index \(index): value=\(sample), |value|=\(abs(sample)) > 1.0",
                    file: file, line: line)
                return
            }
        }
    }

    /// Criterion 4: No NaN or Inf in output.
    static func assertNoNaNOrInf(
        samples: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (index, sample) in samples.enumerated() {
            if sample.isNaN {
                XCTFail("NaN at sample index \(index)",
                    file: file, line: line)
                return
            }
            if sample.isInfinite {
                XCTFail("Inf at sample index \(index)",
                    file: file, line: line)
                return
            }
        }
    }

    // MARK: - Speech-cue spectral similarity

    /// Metrics returned by the spectral similarity computation.
    struct SpectralSimilarity {
        /// Mean per-frame Pearson correlation of log-magnitude spectra, in `[-1, 1]`.
        /// It measures spectral-envelope shape and is invariant to uniform log-spectral offsets such as gain.
        let meanFramePearson: Double
        /// Mean log-spectral distance in dB (lower is better). Standard SE metric.
        let meanLSDdB: Double
        /// Number of frames included after speech-activity gating.
        let activeFrameCount: Int
        /// Total frames in the STFT.
        let totalFrameCount: Int
    }

    /// Requires speech-active spectral similarity to the enhanced reference and
    /// guards against regression from the noisy input baseline. Signal-domain
    /// rationale, gating, and thresholds are canonical in `docs/audio-quality.md`.
    static func assertSpeechSpectralSimilarity(
        output: [Float],
        reference: [Float],
        baseline: [Float],
        sampleRate: Int,
        label: String,
        minFrameCorrelation: Double = 0.50,
        maxLSDdB: Double = 12.0,
        regressionTolerance: Double = 0.03,
        lsdRegressionToleranceDB: Double = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Align lengths — model preserves frame count but defensive clip to the shortest
        // keeps the metric well-defined even if the reference drifts by one sample.
        let n = min(output.count, reference.count, baseline.count)
        guard n > 0 else {
            XCTFail("[\(label)] Empty signal(s): out=\(output.count) ref=\(reference.count) base=\(baseline.count)",
                file: file, line: line)
            return
        }
        let out = Array(output.prefix(n))
        let ref = Array(reference.prefix(n))
        let base = Array(baseline.prefix(n))

        let (nFFT, hop) = stftParams(sampleRate: sampleRate)

        let outMag = magnitudeSTFT(samples: out, nFFT: nFFT, hop: hop)
        let refMag = magnitudeSTFT(samples: ref, nFFT: nFFT, hop: hop)
        let baseMag = magnitudeSTFT(samples: base, nFFT: nFFT, hop: hop)

        // Speech-active gate derived from the enhanced reference only (so the gate is not
        // polluted by model noise floor or input noise).
        let mask = speechActiveFrames(referenceMag: refMag, activeDBRange: 40.0)
        let active = mask.reduce(0) { $0 + ($1 ? 1 : 0) }

        let outLogDB = logMagnitudeDB(outMag)
        let refLogDB = logMagnitudeDB(refMag)
        let baseLogDB = logMagnitudeDB(baseMag)

        let outCorr = meanFramePearsonCorrelation(outLogDB, refLogDB, mask: mask)
        let baseCorr = meanFramePearsonCorrelation(baseLogDB, refLogDB, mask: mask)
        let outLSD = meanLogSpectralDistanceDB(outLogDB, refLogDB, mask: mask)
        let baseLSD = meanLogSpectralDistanceDB(baseLogDB, refLogDB, mask: mask)

        let summary = """

        ── Spectral similarity [\(label)] ──────────────────────────────────
          STFT: nFFT=\(nFFT) hop=\(hop)  frames=\(mask.count) active=\(active)
          Baseline (noisy input  vs reference): corr=\(fmt4(baseCorr))  LSD=\(fmt2(baseLSD)) dB
          Model    (enhanced out vs reference): corr=\(fmt4(outCorr))  LSD=\(fmt2(outLSD)) dB
          Δ corr = \(fmtSigned4(outCorr - baseCorr))    Δ LSD = \(fmtSigned2(outLSD - baseLSD)) dB
        ───────────────────────────────────────────────────────────────────
        """
        print(summary)

        guard active >= 4 else {
            XCTFail("[\(label)] Too few speech-active frames (\(active)) in reference to compute a meaningful metric",
                file: file, line: line)
            return
        }

        XCTAssertGreaterThanOrEqual(outCorr, minFrameCorrelation,
            "[\(label)] Output spectral-shape correlation to reference is \(fmt4(outCorr)), below floor \(minFrameCorrelation). Output does not resemble speech cues in the reference.",
            file: file, line: line)
        XCTAssertLessThanOrEqual(outLSD, maxLSDdB,
            "[\(label)] Output LSD is \(fmt2(outLSD)) dB, above ceiling \(maxLSDdB) dB. Spectral envelope is far from the reference.",
            file: file, line: line)

        // No-regression from the noisy baseline. This is the discriminating check:
        // if the enhancer's output is *less* similar to the expected reference than the
        // raw noisy input is, the model is actively hurting.
        XCTAssertGreaterThanOrEqual(outCorr, baseCorr - regressionTolerance,
            "[\(label)] Model output is LESS spectrally similar to reference than the noisy input baseline (corr \(fmt4(outCorr)) vs baseline \(fmt4(baseCorr))). Enhancement is regressing speech cues.",
            file: file, line: line)
        XCTAssertLessThanOrEqual(outLSD, baseLSD + lsdRegressionToleranceDB,
            "[\(label)] Model output has a LARGER log-spectral distance to reference than the noisy input baseline (LSD \(fmt2(outLSD)) dB vs baseline \(fmt2(baseLSD)) dB).",
            file: file, line: line)
    }

    // MARK: - STFT / Spectral helpers

    /// Returns (nFFT, hop) sized for the sample rate. Targets a ~32 ms window,
    /// power-of-two FFT size, and 75% overlap.
    static func stftParams(sampleRate: Int) -> (nFFT: Int, hop: Int) {
        let targetSamples = Double(sampleRate) * 0.032
        var nFFT = 256
        while Double(nFFT) < targetSamples && nFFT < 4096 {
            nFFT *= 2
        }
        return (nFFT, nFFT / 4)
    }

    /// Magnitude STFT via Accelerate's vDSP.DiscreteFourierTransform. Returns `[fBins][frames]`.
    /// Uses a Hann window and complex→complex DFT with zero imaginary input.
    /// If the signal is shorter than `nFFT`, this returns one zero-padded frame.
    /// For longer signals, it only analyzes complete `nFFT`-sample frames; any leftover
    /// samples at the end that are shorter than one hop are not included in the metric.
    static func magnitudeSTFT(samples: [Float], nFFT: Int, hop: Int) -> [[Float]] {
        precondition(nFFT > 0 && hop > 0, "STFT requires positive nFFT and hop")
        let fBins = nFFT / 2 + 1

        let dft: vDSP.DiscreteFourierTransform<Float>
        do {
            dft = try vDSP.DiscreteFourierTransform(
                count: nFFT,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            fatalError("Failed to create vDSP.DiscreteFourierTransform(count: \(nFFT)): \(error)")
        }

        var window = [Float](repeating: 0, count: nFFT)
        let denom = Float(max(1, nFFT - 1))
        for i in 0..<nFFT {
            window[i] = 0.5 - 0.5 * cosf(2.0 * .pi * Float(i) / denom)
        }

        let totalFrames: Int
        if samples.count < nFFT {
            totalFrames = 1
        } else {
            totalFrames = 1 + (samples.count - nFFT) / hop
        }

        var mag = Array(repeating: [Float](repeating: 0, count: totalFrames), count: fBins)

        var inReal = [Float](repeating: 0, count: nFFT)
        let inImag = [Float](repeating: 0, count: nFFT)
        var outReal = [Float](repeating: 0, count: nFFT)
        var outImag = [Float](repeating: 0, count: nFFT)

        for t in 0..<totalFrames {
            let start = t * hop
            for i in 0..<nFFT {
                let src = start + i
                if src < samples.count {
                    inReal[i] = samples[src] * window[i]
                } else {
                    inReal[i] = 0
                }
            }

            let (resReal, resImag) = dft.transform(real: inReal, imaginary: inImag)
            outReal = resReal
            outImag = resImag

            for k in 0..<fBins {
                let re = outReal[k]
                let im = outImag[k]
                mag[k][t] = sqrtf(re * re + im * im)
            }
        }

        return mag
    }

    /// Converts linear magnitude `[fBins][frames]` to `20 * log10(max(|X|, eps))` in dB.
    static func logMagnitudeDB(_ mag: [[Float]]) -> [[Float]] {
        let floor: Float = 1e-8
        var out = mag
        for f in 0..<out.count {
            for t in 0..<out[f].count {
                out[f][t] = 20.0 * log10f(max(mag[f][t], floor))
            }
        }
        return out
    }

    /// Boolean mask of frames where the reference frame power is within `activeDBRange`
    /// of the peak frame power. Frames outside this window (silence / breath / noise tail)
    /// are excluded from similarity metrics so noise-dominated regions cannot hide failures.
    static func speechActiveFrames(referenceMag: [[Float]], activeDBRange: Float) -> [Bool] {
        let fBins = referenceMag.count
        guard fBins > 0 else { return [] }
        let frameCount = referenceMag[0].count
        guard frameCount > 0 else { return [] }

        var frameDB = [Float](repeating: -200, count: frameCount)
        for t in 0..<frameCount {
            var sumSq: Double = 0
            for f in 0..<fBins {
                let m = Double(referenceMag[f][t])
                sumSq += m * m
            }
            let meanSq = sumSq / Double(fBins)
            frameDB[t] = Float(10.0 * Foundation.log10(max(meanSq, 1e-20)))
        }

        guard let peak = frameDB.max() else {
            return Array(repeating: false, count: frameCount)
        }
        let threshold = peak - activeDBRange
        return frameDB.map { $0 >= threshold }
    }

    /// Mean Pearson correlation of per-frame log-magnitude vectors over masked frames.
    /// Scale- and offset-invariant — measures *shape* of the spectral envelope.
    static func meanFramePearsonCorrelation(_ a: [[Float]], _ b: [[Float]], mask: [Bool]) -> Double {
        let fBins = min(a.count, b.count)
        guard fBins > 1 else { return 0 }
        let frames = min(a[0].count, b[0].count, mask.count)

        var sum: Double = 0
        var count = 0

        for t in 0..<frames where mask[t] {
            var meanA: Double = 0
            var meanB: Double = 0
            for f in 0..<fBins {
                meanA += Double(a[f][t])
                meanB += Double(b[f][t])
            }
            meanA /= Double(fBins)
            meanB /= Double(fBins)

            var num: Double = 0
            var da: Double = 0
            var db: Double = 0
            for f in 0..<fBins {
                let x = Double(a[f][t]) - meanA
                let y = Double(b[f][t]) - meanB
                num += x * y
                da += x * x
                db += y * y
            }
            let denom = Foundation.sqrt(da * db)
            if denom > 1e-12 {
                sum += num / denom
                count += 1
            }
        }

        return count > 0 ? sum / Double(count) : 0
    }

    /// Mean log-spectral distance (dB) over masked frames.
    /// Inputs are already in dB (20·log10|X|), so the per-frame distance is
    ///   `sqrt( mean_f (a_dB[f,t] - b_dB[f,t])^2 )`
    /// which matches the conventional LSD formulation once power vs. magnitude is
    /// absorbed into the constant (both sides use the same 20·log10 scaling).
    static func meanLogSpectralDistanceDB(_ aDB: [[Float]], _ bDB: [[Float]], mask: [Bool]) -> Double {
        let fBins = min(aDB.count, bDB.count)
        guard fBins > 0 else { return 0 }
        let frames = min(aDB[0].count, bDB[0].count, mask.count)

        var sum: Double = 0
        var count = 0

        for t in 0..<frames where mask[t] {
            var sqSum: Double = 0
            for f in 0..<fBins {
                let d = Double(aDB[f][t]) - Double(bDB[f][t])
                sqSum += d * d
            }
            sum += Foundation.sqrt(sqSum / Double(fBins))
            count += 1
        }

        return count > 0 ? sum / Double(count) : 0
    }

    // MARK: - Formatting

    private static func fmt4(_ v: Double) -> String { String(format: "%.4f", v) }
    private static func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func fmtSigned4(_ v: Double) -> String { String(format: "%+.4f", v) }
    private static func fmtSigned2(_ v: Double) -> String { String(format: "%+.2f", v) }
}
