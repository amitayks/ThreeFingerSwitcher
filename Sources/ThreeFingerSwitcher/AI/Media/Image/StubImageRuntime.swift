import Foundation

/// A deterministic, weight-free image `MediaRuntime` for `swift test` (design D8, tasks 3.2–3.3). Unlike
/// the generic `StubMediaRuntime` (which plays an arbitrary scripted shape), this stub models the IMAGE
/// backend's real generate shape: it runs `ImageRequestValidator` at the boundary (so the seed-capability
/// / param-bounds gate is exercised end-to-end), emits ordered `.step(index:total:preview:)` progress,
/// WRITES a real placeholder PNG to disk, and terminates in `.finished(MediaAsset)` whose `kind == .image`
/// and dimensions match the request. It honors cancellation (the stream ends WITHOUT a `.finished`, never
/// throwing — cancellation is not a failure, design D10).
///
/// It lets the full route → progress → asset → (Files-entry shape) path be tested without MLX/GPU,
/// including the seed/img2img branch (a present seed routes through the seed-capable descriptor).
///
/// MLX-free Core (test + integration support).
public final class StubImageRuntime: MediaRuntime, @unchecked Sendable {

    public let capabilities: Set<MediaKind> = [.image]

    /// The descriptor this stub generates as (its capability tags gate the seed branch). Defaults to the
    /// Q4 seed-capable variant so an img2img request passes; pass `ImageModelCatalog.q4Descriptor` etc.
    private let descriptor: ModelDescriptor
    /// Where placeholder PNGs are written (a temp dir by default — the asset URL is readable).
    private let outputDirectory: URL
    /// How many `.step`s to emit before finishing (defaults to the request's step count, capped for speed).
    private let maxSteps: Int
    /// An optional per-step delay (nanoseconds) so a test can reliably cancel a gen MID-FLIGHT. Default 0
    /// (instant — the common path stays fast). A non-zero value models the real diffusion's step latency.
    private let perStepDelayNanos: UInt64
    /// Records the requests driven (so tests assert seed/kind/params threaded through).
    public private(set) var receivedRequests: [MediaRequest] = []
    private let lock = NSLock()

    public init(descriptor: ModelDescriptor = ImageModelCatalog.q4Descriptor,
                outputDirectory: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("StubImageRuntime-\(UUID().uuidString)", isDirectory: true),
                maxSteps: Int = 4,
                perStepDelayNanos: UInt64 = 0) {
        self.descriptor = descriptor
        self.outputDirectory = outputDirectory
        self.maxSteps = maxSteps
        self.perStepDelayNanos = perStepDelayNanos
    }

    public func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error> {
        lock.lock(); receivedRequests.append(request); lock.unlock()
        let descriptor = self.descriptor
        let outputDirectory = self.outputDirectory
        let stepBudget = max(1, min(maxSteps, request.parameters.steps))
        let perStepDelayNanos = self.perStepDelayNanos

        return AsyncThrowingStream { continuation in
            let task = Task {
                // (1) BOUNDARY VALIDATION — the same gate the real runtime runs. A bad request (seed vs
                // non-seed descriptor, out-of-range params) THROWS a clean `MediaError` and never paints.
                if let err = ImageRequestValidator.validate(request, descriptor: descriptor) {
                    continuation.finish(throwing: err)
                    return
                }

                // (2) ORDERED STEPS — ascending index, with a tiny placeholder preview frame.
                let preview = Data(MediaSeedValidation.pngMagic)
                for i in 0..<stepBudget {
                    if Task.isCancelled { continuation.finish(); return }   // cancellation → no .finished
                    continuation.yield(.step(index: i, total: stepBudget, preview: preview))
                    // A suspension point so a discard can cancel mid-flight. A non-zero delay makes the
                    // cancellation window deterministic in tests (a discarded gen stops here, no .finished).
                    if perStepDelayNanos > 0 {
                        do { try await Task.sleep(nanoseconds: perStepDelayNanos) }
                        catch { continuation.finish(); return }   // sleep cancelled → stop, no .finished
                    } else {
                        await Task.yield()
                    }
                }
                if Task.isCancelled { continuation.finish(); return }

                // (3) WRITE the placeholder PNG + emit the terminal asset (dimensions match the request).
                do {
                    let url = try Self.writePlaceholderPNG(in: outputDirectory)
                    let asset = MediaAsset(url: url, kind: .image,
                                           width: request.parameters.size.width,
                                           height: request.parameters.size.height)
                    continuation.yield(.finished(asset))
                    continuation.finish()
                } catch {
                    // A write failure is a real `.failed` (mapped to a clean MediaError) — never a false done.
                    continuation.finish(throwing: MediaError.outputWriteFailed(detail: String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Write a minimal but VALID, readable PNG placeholder to `dir` (the asset URL the sink turns into a
    /// Files-band `.fileEntry`). A real 1×1 PNG so the file is decodable, not just a magic-number stub.
    static func writePlaceholderPNG(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
        try minimalPNG.write(to: url)
        return url
    }

    /// A hand-rolled, byte-valid 1×1 opaque-black PNG (no AppKit/MLX dependency — Core stays portable).
    /// Signature + IHDR(1×1, 8-bit RGB) + IDAT (zlib stored block of one filtered RGB scanline) + IEND.
    static let minimalPNG: Data = {
        func be32(_ v: UInt32) -> [UInt8] {
            [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                crc ^= UInt32(b)
                for _ in 0..<8 {
                    crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let typeBytes = Array(type.utf8)
            var out = be32(UInt32(payload.count))
            out += typeBytes
            out += payload
            out += be32(crc32(typeBytes + payload))
            return out
        }
        // Signature.
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // IHDR: width=1, height=1, bitDepth=8, colorType=2 (RGB), compression=0, filter=0, interlace=0.
        let ihdr = be32(1) + be32(1) + [8, 2, 0, 0, 0]
        png += chunk("IHDR", ihdr)
        // IDAT: one scanline = filter byte (0) + RGB (0,0,0). zlib: header 0x78 0x01, one STORED block.
        let raw: [UInt8] = [0x00, 0x00, 0x00, 0x00]            // filter + R,G,B
        // adler32 of `raw`.
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        let len = UInt16(raw.count)
        var zlib: [UInt8] = [0x78, 0x01, 0x01]                 // CMF/FLG + final stored block
        zlib += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)]  // LEN (little-endian)
        zlib += [UInt8(~len & 0xFF), UInt8((~len >> 8) & 0xFF)]// NLEN
        zlib += raw
        zlib += be32(adler)
        png += chunk("IDAT", zlib)
        png += chunk("IEND", [])
        return Data(png)
    }()
}
