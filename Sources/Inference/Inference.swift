// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXNN
import Numerics

/// The base sample rate used by the SE-Mamba model for internal scaling.
/// All STFT parameters are derived from (noisy_sr / baseSampleRate).
let SE_MAMBA_BASE_SAMPLE_RATE: Int = 8000

/// SpeechLens is a Metal-only runtime. Keep MLX graph construction and
/// evaluation explicitly on the GPU instead of relying on the package's
/// process- or task-default device semantics.
private enum MLXExecutionContext {
    static func withGPU<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try Device.withDefaultDevice(.gpu, operation)
    }
}

/// Matches the post-processing in the pinned NVIDIA RE-USE inference path.
/// A time frame is suppressed when more than half of its frequency bins were
/// clamped to zero by the non-negative log-magnitude reconstruction.
func suppressSweepArtifactFrames(_ magnitude: MLXArray) -> MLXArray {
    precondition(magnitude.ndim == 3, "Expected magnitude shaped [batch, frequency, time]")
    let zeroCounts = (magnitude .== 0).sum(axis: 1, keepDims: true)
    let suppressFrame = zeroCounts .> (magnitude.shape[1] / 2)
    return which(suppressFrame, MLXArray(0.0), magnitude)
}

/// A single-use, mono enhancement stream. Implementations may retain a bounded
/// amount of look-ahead and overlap-add state between calls.
public protocol SpeechEnhancementSession: Sendable {
    var recommendedInputFrameCount: Int { get }

    func append(_ monoFrames: [Float]) async throws -> [Float]
    func finish() async throws -> [Float]
}

/// Creates independent mono sessions backed by one reusable enhancement model.
public protocol StreamingSpeechEnhancer: Sendable {
    func makeSession(
        sampleRate: Int,
        settings: InferenceSettings
    ) async throws -> any SpeechEnhancementSession
}

/// MLX-native implementation of the SE-Mamba speech enhancement model.
public actor MambaEnhancer: StreamingSpeechEnhancer {
    private let model: SEMamba
    public let mode: InferenceMode
    
    public init(modelWeightsURL: URL, mode: InferenceMode = .standard) throws {
        self.mode = mode
        guard FileManager.default.fileExists(atPath: modelWeightsURL.path) else {
            throw InferenceError.modelNotFound(modelWeightsURL)
        }
        try Self.validatePackagedMLXMetallib()

        do {
            self.model = try MLXExecutionContext.withGPU {
                let model = SEMamba(numBlocks: 30, mode: mode)
                let modelWeights = try MLX.loadArrays(url: modelWeightsURL)
                try Self.validateModelWeights(modelWeights)
                model.update(parameters: ModuleParameters.unflattened(modelWeights))
                return model
            }
        } catch let error as InferenceError {
            throw error
        } catch {
            throw InferenceError.weightMappingFailed("\(error)")
        }
        // Cap MLX's buffer cache (default 2048 MB) so retained buffers do not climb
        // unboundedly across chunks. Override via `SPEECHLENS_CACHE_LIMIT_MB`
        // (0 = disable cache, negative = leave MLX default). See
        // docs/performance.md.
        if let cacheLimitBytes = Self.cacheLimitBytes() {
            MLX.Memory.cacheLimit = cacheLimitBytes
            SpeechLensLog.inference.debug(
                "MLX cache limit set to \(cacheLimitBytes / (1024 * 1024), privacy: .public) MB"
            )
        }

        SpeechLensLog.inference.debug("Loaded weights path: \(modelWeightsURL.path, privacy: .private)")
    }

    static func cacheLimitBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        let cacheLimitMB = Int(environment["SPEECHLENS_CACHE_LIMIT_MB"] ?? "2048") ?? 2048
        guard cacheLimitMB >= 0 else { return nil }
        return cacheLimitMB * 1024 * 1024
    }

    static func validateModelWeights(_ weights: [String: MLXArray]) throws {
        let branches = ["timeMamba.forward", "timeMamba.backward", "freqMamba.forward", "freqMamba.backward"]
        let blockIndices = Set(weights.keys.compactMap { key -> Int? in
            let components = key.split(separator: ".", maxSplits: 2)
            guard components.count == 3, components[0] == "tfMamba" else { return nil }
            return Int(components[1])
        })

        guard blockIndices == Set(0..<30) else {
            throw InferenceError.unsupportedModelArchitecture(
                "expected exactly 30 TFMamba blocks indexed 0 through 29"
            )
        }

        for block in 0..<30 {
            for branch in branches {
                let prefix = "tfMamba.\(block).\(branch)"
                let aLog = try requiredWeight(weights, key: "\(prefix).A_log")
                let d = try requiredWeight(weights, key: "\(prefix).D")
                let xProj = try requiredWeight(weights, key: "\(prefix).xProj.weight")
                let dtProj = try requiredWeight(weights, key: "\(prefix).dtProj.weight")
                do {
                    try MetalSelectiveScan.validateModelLayout(
                        aLogShape: aLog.shape,
                        dShape: d.shape,
                        xProjWeightShape: xProj.shape,
                        dtProjWeightShape: dtProj.shape
                    )
                } catch let error as MetalSelectiveScanError {
                    throw InferenceError.metalInferenceIncompatible(error.localizedDescription)
                }
            }
        }
    }

    private static func requiredWeight(
        _ weights: [String: MLXArray],
        key: String
    ) throws -> MLXArray {
        guard let weight = weights[key] else {
            throw InferenceError.unsupportedModelArchitecture("missing required tensor \(key)")
        }
        return weight
    }

    @discardableResult
    static func validatePackagedMLXMetallib(
        executableURL overrideExecutableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let fm = FileManager.default

        // MLX C++ runtime derives its search path from `dladdr` on its own symbols,
        // which resolves to the binary that statically linked in MLX. Validate only
        // the read-only locations MLX itself will load from; build and package tools
        // are responsible for placing `mlx.metallib` there before runtime.
        let executableURL = overrideExecutableURL?.resolvingSymlinksInPath()
            ?? Self.resolveInferenceBinaryURL()
        let executableDir = executableURL.deletingLastPathComponent()
        let colocatedTarget = executableDir.appendingPathComponent("mlx.metallib")
        let resourcesTarget = executableDir.appendingPathComponent("Resources/mlx.metallib")

        if fm.fileExists(atPath: colocatedTarget.path) {
            if metallibLooksCompatible(at: colocatedTarget) {
                return colocatedTarget
            }
            throw InferenceError.inferenceFailed(
                "Packaged MLX metallib is incompatible: \(colocatedTarget.path). " +
                "Rebuild package resources with Tools/build_mlx_metallib.sh or Tools/package-local.sh."
            )
        }
        if fm.fileExists(atPath: resourcesTarget.path) {
            if metallibLooksCompatible(at: resourcesTarget) {
                return resourcesTarget
            }
            throw InferenceError.inferenceFailed(
                "Packaged MLX metallib is incompatible: \(resourcesTarget.path). " +
                "Rebuild package resources with Tools/build_mlx_metallib.sh or Tools/package-local.sh."
            )
        }

        var message = "MLX metallib is not packaged. Expected \(colocatedTarget.path) or \(resourcesTarget.path). "
        if let explicit = environment["MLX_METALLIB_PATH"], !explicit.isEmpty {
            message += "MLX_METALLIB_PATH is set to \(explicit), but runtime does not copy or compile metallib files. "
        }
        message += "Run Tools/package-local.sh --configuration release for packaged artifacts, or Tools/build_mlx_metallib.sh --output <path> during development."
        throw InferenceError.inferenceFailed(message)
    }

    /// Returns the URL of the binary that statically linked this `Inference` module.
    /// - In `swift test`: the `.xctest/Contents/MacOS/<TestBundle>` binary.
    /// - In the CLI/App: the main executable.
    /// This matches what MLX's C++ `current_binary_dir()` computes via `dladdr`,
    /// which is where MLX will look for `mlx.metallib`.
    private static func resolveInferenceBinaryURL() -> URL {
        if let url = Bundle(for: MambaEnhancer.self).executableURL {
            return url.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    static func metallibLooksCompatible(at url: URL) -> Bool {
        // Lightweight probe for a kernel symbol known to be required by this build.
        // This avoids selecting older/incompatible mlx.metallib files.
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        let needle = Data("layer_normfloat32".utf8)
        return data.range(of: needle) != nil
    }
    
    public func makeSession(
        sampleRate: Int,
        settings: InferenceSettings
    ) throws -> any SpeechEnhancementSession {
        try MambaEnhancementSession(
            enhancer: self,
            sampleRate: sampleRate,
            settings: settings
        )
    }

    func enhanceWindow(_ samples: [Float], sampleRate: Int) throws -> [Float] {
        try Task.checkCancellation()
        guard sampleRate > 0 else {
            throw InferenceError.inferenceFailed("Sample rate must be greater than zero")
        }
        guard !samples.isEmpty else { return [] }

        let params = Self.scaledSTFTParams(sampleRate: sampleRate)
        SpeechLensLog.inference.debug(
            "Running enhancement at \(sampleRate, privacy: .public) Hz with nFFT=\(params.nFFT, privacy: .public), hop=\(params.hop, privacy: .public), win=\(params.win, privacy: .public)"
        )
        let output = try MLXExecutionContext.withGPU {
            try enhanceChunkSamples(samples, params: params)
        }
        try Task.checkCancellation()
        guard output.count == samples.count else {
            throw InferenceError.inferenceFailed("Model window changed frame count")
        }
        return output
    }

    /// Runs STFT → model → iSTFT on one chunk and returns exactly
    /// `samples.count` samples.
    ///
    /// `MLX.eval` is called explicitly on the model output before `asArray` so
    /// intermediate graph state is released before the next chunk builds its
    /// graph.
    private func enhanceChunkSamples(
        _ samples: [Float],
        params: (nFFT: Int, hop: Int, win: Int)
    ) throws -> [Float] {
        let (magIn, phaIn, frameCount) = try stftInputs(
            samples: samples,
            nFFT: params.nFFT,
            hop: params.hop,
            win: params.win
        )
        let fBins = params.nFFT / 2 + 1

        let (modelOutMag, modelOutPha) = model(magIn, phaIn)
        if modelOutMag.shape != [1, fBins, frameCount]
            || modelOutPha.shape != [1, fBins, frameCount]
        {
            throw InferenceError.inferenceFailed("Unexpected model output shape")
        }
        let nonnegativeMagnitude = expm1(maximum(modelOutMag, MLXArray(0.0)))
        let enhMag = suppressSweepArtifactFrames(nonnegativeMagnitude)

        // Force MLX to evaluate and release the forward-pass graph before we
        // move on — without this barrier, intermediates from every chunk stack
        // up and RSS grows linearly with audio length.
        MLX.eval(enhMag, modelOutPha)

        let padLen = params.nFFT / 2
        let paddedLen = samples.count + 2 * padLen
        let reconstructed = istft(
            mag: enhMag,
            pha: modelOutPha,
            originalCount: paddedLen,
            nFFT: params.nFFT,
            hop: params.hop,
            win: params.win
        )
        let trimStart = padLen
        let trimEnd = min(trimStart + samples.count, reconstructed.count)
        if trimStart < trimEnd {
            return Array(reconstructed[trimStart..<trimEnd])
        }
        return [Float](repeating: 0, count: samples.count)
    }
    /// Mirrors NVIDIA RE-USE's `make_even(base * sampleRate // baseRate)`.
    /// The integer division is intentional: at 44.1 kHz, the trained hop
    /// scales to 220 rather than rounding the half sample up to 222.
    static func nvidiaScaledEvenParameter(
        base: Int,
        sampleRate: Int,
        baseSampleRate: Int = SE_MAMBA_BASE_SAMPLE_RATE
    ) -> Int {
        precondition(base > 0 && sampleRate > 0 && baseSampleRate > 0)
        let (product, overflow) = base.multipliedReportingOverflow(by: sampleRate)
        precondition(!overflow, "STFT parameter scaling overflowed Int")
        let scaled = product / baseSampleRate
        return (scaled % 2 == 0) ? max(2, scaled) : max(2, scaled + 1)
    }

    static func scaledSTFTParams(sampleRate: Int) -> (nFFT: Int, hop: Int, win: Int) {
        return (
            nFFT: nvidiaScaledEvenParameter(base: 320, sampleRate: sampleRate),
            hop: nvidiaScaledEvenParameter(base: 40, sampleRate: sampleRate),
            win: nvidiaScaledEvenParameter(base: 320, sampleRate: sampleRate)
        )
    }

    /// Returns the periodic Hann window used by PyTorch's
    /// `torch.hann_window(length)` default (`periodic == true`). Keeping the
    /// denominator at `length` is part of the NVIDIA RE-USE STFT contract;
    /// the symmetric `length - 1` form would produce a different model input
    /// and a different overlap-add synthesis window.
    static func nvidiaPeriodicHannWindow(_ length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1.0, count: max(1, length)) }
        let denom = Float(length)
        return (0..<length).map { i in
            0.5 - 0.5 * Foundation.cos(2.0 * Float.pi * Float(i) / denom)
        }
    }

    private func stftInputs(
        samples: [Float],
        nFFT: Int,
        hop: Int,
        win: Int
    ) throws -> (mag: MLXArray, pha: MLXArray, frameCount: Int) {
        // Center padding (reflect) — matches PyTorch center=True, pad_mode='reflect'
        let paddedArray = centeredReflectPaddedArray(samples, nFFT: nFFT)

        // STFT framing retains only complete windows, matching PyTorch's
        // floor-based torch.stft enumeration. Any incomplete final hop is
        // discarded from the model input; iSTFT still reconstructs to the
        // requested padded length and the outer trim preserves frame count.
        let framing: CompleteFrameWindowPlan
        let frames: MLXArray
        do {
            (frames, framing) = try MLXCompleteFrameFramer.frames(paddedArray, window: win, hop: hop)
        } catch {
            throw InferenceError.inferenceFailed(error.localizedDescription)
        }
        let window = MLXArray(Self.nvidiaPeriodicHannWindow(win), [1, win])

        var windowedFrames = frames * window
        if nFFT > win {
            let zeroTail = MLX.zeros([framing.frameCount, nFFT - win])
            windowedFrames = MLX.concatenated([windowedFrames, zeroTail], axis: 1)
        }

        let spec = rfft(windowedFrames, n: nFFT, axis: -1)
        let real = spec.realPart()
        let imag = spec.imaginaryPart()
        let mag = (real * real + imag * imag).sqrt().log1p().transposed(1, 0).expandedDimensions(axis: 0)
        let pha = MLX.atan2(imag, real).transposed(1, 0).expandedDimensions(axis: 0)
        return (mag, pha, framing.frameCount)
    }

    private func centeredReflectPaddedArray(_ samples: [Float], nFFT: Int) -> MLXArray {
        let padLen = nFFT / 2
        let n = samples.count
        if n > padLen + 1 {
            let samplesArr = MLXArray(samples)
            let prefix = samplesArr[.stride(from: padLen, to: 0, by: -1)]
            let suffix = samplesArr[.stride(from: n - 2, to: n - 2 - padLen, by: -1)]
            return MLX.concatenated([prefix, samplesArr, suffix])
        }
        var padded = [Float]()
        padded.reserveCapacity(n + 2 * padLen)
        for i in stride(from: padLen, through: 1, by: -1) {
            padded.append(samples[min(i, n - 1)])
        }
        padded.append(contentsOf: samples)
        for i in 0..<padLen {
            padded.append(samples[max(0, n - 2 - i)])
        }
        return MLXArray(padded)
    }

    private func istft(
        mag: MLXArray,
        pha: MLXArray,
        originalCount: Int,
        nFFT: Int,
        hop: Int,
        win: Int
    ) -> [Float] {
        let squeezedMag = mag.squeezed(axis: 0)
        let squeezedPha = pha.squeezed(axis: 0)
        let frameCount = squeezedMag.shape.count == 2 ? squeezedMag.shape[1] : 0
        guard frameCount > 0 else { return [Float](repeating: 0, count: originalCount) }
        let outLen = max(originalCount, (frameCount - 1) * hop + win)
        let window = Self.nvidiaPeriodicHannWindow(win)

        let magTF = squeezedMag.transposed(1, 0)
        let phaTF = squeezedPha.transposed(1, 0)
        let spectrum = magTF * phaTF.cos() + (magTF * phaTF.sin()).asImaginary()
        let timeFrames = irfft(spectrum, n: nFFT, axis: -1)
        MLX.eval(timeFrames)
        let frameTimeFlat = timeFrames.asArray(Float.self)

        var out = [Float](repeating: 0, count: outLen)
        var norm = [Float](repeating: 0, count: outLen)

        for t in 0..<frameCount {
            let start = t * hop
            let frameOffset = t * nFFT
            for i in 0..<win {
                let dst = start + i
                if dst < outLen {
                    let w = window[i]
                    out[dst] += frameTimeFlat[frameOffset + i] * w
                    norm[dst] += w * w
                }
            }
        }

        for i in 0..<outLen where norm[i] > 1e-8 {
            out[i] /= norm[i]
        }

        return Array(out.prefix(originalCount))
    }
}

/// Errors occurring during model loading or inference.
public enum InferenceError: Error, LocalizedError, Sendable, Equatable {
    case modelNotFound(URL)
    case unsupportedModelArchitecture(String)
    case metalInferenceIncompatible(String)
    case weightMappingFailed(String)
    case inferenceFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let url): return "Model weights not found at \(url.path)"
        case .unsupportedModelArchitecture(let message): return "Unsupported model architecture: \(message)"
        case .metalInferenceIncompatible(let message): return "Metal inference incompatible: \(message)"
        case .weightMappingFailed(let msg): return "Weight mapping failed: \(msg)"
        case .inferenceFailed(let msg): return "Inference failed: \(msg)"
        }
    }
}
