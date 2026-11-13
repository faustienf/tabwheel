import CoreImage
import ScreenCaptureKit

/// A low-resolution, screen-only stream. Frame conversion runs off the input/UI thread.
@MainActor
final class ScreenPreviewCapture: PreviewCapture {
    private let stream: SCStream
    private let output: PreviewStreamOutput
    private let framesTask: Task<Void, Never>
    private var attemptedStart = false

    init(window: SCWindow, maxSize: CGSize, onImage: @escaping @MainActor (CGImage) -> Void) throws {
        let (frames, continuation) = AsyncStream<CGImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        output = PreviewStreamOutput(continuation: continuation)
        let (filter, configuration) = Self.configuration(window: window, maxSize: maxSize)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.preservesAspectRatio = true
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "com.faustienf.CmdTabWheel.preview", qos: .userInitiated))
        framesTask = Task {
            for await image in frames {
                guard !Task.isCancelled else { break }
                onImage(image)
            }
        }
    }

    func start() async throws {
        attemptedStart = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func stop() async {
        framesTask.cancel()
        output.finish()
        if attemptedStart {
            attemptedStart = false
            await withCheckedContinuation { continuation in
                stream.stopCapture { _ in continuation.resume() }
            }
        }
        try? stream.removeStreamOutput(output, type: .screen)
    }

    /// Share the same point-to-pixel sizing with the initial cached screenshots.
    static func configuration(window: SCWindow, maxSize: CGSize) -> (SCContentFilter, SCStreamConfiguration) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let fit = min(maxSize.width / max(window.frame.width, 1), maxSize.height / max(window.frame.height, 1), 1)
        configuration.width = max(1, Int(window.frame.width * fit * scale))
        configuration.height = max(1, Int(window.frame.height * fit * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return (filter, configuration)
    }
}

/// ScreenCaptureKit calls this on its serial sample queue. Only complete frames are images;
/// idle, blank or suspended samples leave the last useful preview on screen.
private final class PreviewStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let continuation: AsyncStream<CGImage>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(continuation: AsyncStream<CGImage>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let frame = context.createCGImage(image, from: image.extent) {
            continuation.yield(frame)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
        log.error("live preview: stream stopped: \(error.localizedDescription, privacy: .public)")
    }

    func finish() {
        continuation.finish()
    }
}
