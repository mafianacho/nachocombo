import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import NachoComboCore

/// Records an area of the screen to an MP4 file (ScreenCaptureKit, macOS 12.3 and later), Nacho Combo's own windows
/// left out. Frames go straight from the stream into the writer on one queue; nothing is kept in memory.
@available(macOS 12.3, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let url: URL
    private(set) var startDate = Date()
    var onStop: ((URL?) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var stopping = false
    private let queue = DispatchQueue(label: "com.mafianacho.nachocombo.record")

    init(url: URL) {
        self.url = url
    }

    /// `cocoa`: the area in Cocoa screen coordinates.
    func start(cocoa: CGRect, completion: @escaping (String?) -> Void) {
        let center = NSPoint(x: cocoa.midX, y: cocoa.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            completion("No display under the area")
            return
        }
        let area = cocoa.intersection(screen.frame)
        let scale = screen.backingScaleFactor
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let content = content, let display = content.displays.first(where: { $0.displayID == number }) else {
                    completion(error?.localizedDescription ?? "The screen could not be recorded")
                    return
                }
                let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                // Display-local points with a top-left origin.
                configuration.sourceRect = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY,
                                                  width: area.width, height: area.height)
                let width = Int(area.width * scale) / 2 * 2, height = Int(area.height * scale) / 2 * 2
                configuration.width = width
                configuration.height = height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.showsCursor = true
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.queueDepth = 6
                do {
                    let writer = try AVAssetWriter(outputURL: self.url, fileType: .mp4)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                    ])
                    input.expectsMediaDataInRealTime = true
                    writer.add(input)
                    self.writer = writer
                    self.input = input
                    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    self.stream = stream
                    self.startDate = Date()
                    stream.startCapture { error in
                        DispatchQueue.main.async { completion(error?.localizedDescription) }
                    }
                } catch {
                    completion(error.localizedDescription)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !stopping,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer = writer, let input = input else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { finish() }

    /// The owner may let go of the recorder right away: the closures below keep it alive until the file is written.
    func stop() {
        guard let stream = stream else { finish(); return }
        stream.stopCapture { _ in self.finish() }
    }

    private func finish() {
        queue.async {
            guard !self.stopping else { return }
            self.stopping = true
            self.stream = nil
            guard self.started, let writer = self.writer else {
                DispatchQueue.main.async { self.onStop?(nil) }
                return
            }
            self.input?.markAsFinished()
            writer.finishWriting {
                let url = writer.status == .completed ? self.url : nil
                DispatchQueue.main.async { self.onStop?(url) }
            }
        }
    }
}

enum RecordingFiles {
    static func movieURL() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return desktop.appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")
    }

    /// A looping GIF of the first 15 seconds, 10 frames a second, at most 640 points wide, next to the movie.
    static func makeGIF(from movie: URL, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: movie)
            let duration = min(15, CMTimeGetSeconds(asset.duration))
            guard duration > 0 else { DispatchQueue.main.async { completion(nil) }; return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.appliesPreferredTrackTransform = true
            let tolerance = CMTime(value: 1, timescale: 20)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let count = max(1, Int(duration * 10))
            let url = movie.deletingPathExtension().appendingPathExtension("gif")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil)
            else { DispatchQueue.main.async { completion(nil) }; return }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                as CFDictionary)
            let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            var added = 0
            for index in 0..<count {
                let time = CMTime(seconds: Double(index) / 10, preferredTimescale: 600)
                guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
                CGImageDestinationAddImage(destination, image, frame)
                added += 1
            }
            let ok = added > 0 && CGImageDestinationFinalize(destination)
            DispatchQueue.main.async { completion(ok ? url : nil) }
        }
    }
}

/// The system's color picker loupe; the picked color's hex code goes to the clipboard.
enum ColorPicker {
    private static var sampler: NSColorSampler?

    static func pick(_ done: @escaping (String?) -> Void) {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { color in
            self.sampler = nil
            guard let rgb = color?.usingColorSpace(.sRGB) else { done(nil); return }
            let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)
            done(hex)
        }
    }
}
