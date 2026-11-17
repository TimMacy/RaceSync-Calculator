import AppKit
import Combine
import CoreImage
import ScreenCaptureKit
import os // OSAllocatedUnfairLock

// MARK: - Capture Engine -
// Records one display with ScreenCaptureKit and publishes the selected regions of every new frame.

/// Why capture isn't running, so the feed cards can say so instead of waiting forever.
enum CaptureFailure {
    case permissionDenied // Screen Recording is off for this app
    case displayNotFound  // the screen the region was selected on is gone
    case stopped          // the stream ended on its own, e.g. Stop Sharing in the menu bar
    case failed           // any other error while starting

    /// Short text for the capture previews.
    var message: String {
        switch self {
        case .permissionDenied: return "Screen recording not allowed"
        case .displayNotFound:  return "Display not found"
        case .stopped:          return "Capture stopped"
        case .failed:           return "Capture failed"
        }
    }

    /// What to do about it, shown when Calculate has no image to read.
    var help: String {
        switch self {
        case .permissionDenied:
            return "Screen recording isn't allowed. Turn it on in System Settings > Privacy & Security, then reselect the region."
        case .displayNotFound:
            return "The display with the selected region wasn't found. Reselect the region."
        case .stopped:
            return "Screen capture stopped. Reselect the region to start it again."
        case .failed:
            return "Screen capture couldn't start. Reselect the region to try again."
        }
    }
}

/// One captured image of a clock region and the host time (`RaceTimer.hostNow()` clock) it was on screen.
struct ClockFrame {
    let image: CGImage
    let time: Double
}

/// What `recordTicks` saw: for each region, every frame that looked different from the one before, in time order.
struct TickRecording {
    var multiViewer: [ClockFrame] = []
    var clockApp: [ClockFrame] = []
}

final class CaptureEngine: NSObject, ObservableObject {
    static let idleFrameRate = 5
    static let measuringFrameRate = 60
    private static let settleTime = 0.25
    @Published var isCapturing = false
    @Published private(set) var frameRate = CaptureEngine.idleFrameRate
    @Published var multiViewerImage: CGImage?
    @Published var clockAppImage: CGImage?
    @Published var multiViewerFrameTime: Double?
    @Published var failure: CaptureFailure?
    private var stream: SCStream? // Main thread only
    private var streamConfiguration: SCStreamConfiguration? // Main thread only; kept to change the frame rate
    @MainActor private var recordingID = 0
    @MainActor private var captureTask: Task<Void, Never>?
    private struct CropSettings {
        let multiViewerRegion: CGRect?
        let clockAppRegion: CGRect?
        let scaleFactor: CGFloat // points -> pixels
    }
    /// Written on the main thread and read on `videoOutputQueue`, so it sits behind a lock.
    private let cropSettings = OSAllocatedUnfairLock<CropSettings?>(initialState: nil)

    /// Collects one region's frames during a tick recording, skipping frames identical to the one before.
    private struct FrameLog {
        static let maxBytes = 256 * 1024 * 1024

        private(set) var frames: [ClockFrame] = []
        private var lastPixels: CFData?
        private var bytes = 0

        mutating func add(_ image: CGImage?, at time: Double) {
            guard let image, bytes < Self.maxBytes, let pixels = image.dataProvider?.data else { return }
            if let lastPixels, CFEqual(lastPixels, pixels) { return }
            lastPixels = pixels
            bytes += CFDataGetLength(pixels)
            frames.append(ClockFrame(image: image, time: time))
        }
    }
    private struct Recorder {
        var multiViewer = FrameLog()
        var clockApp = FrameLog()
    }
    private let recorder = OSAllocatedUnfairLock<Recorder?>(uncheckedState: nil)

    private let videoOutputQueue = DispatchQueue(label: "com.racesync.calculator.videoOutput", qos: .userInitiated)
    /// One Core Image context for every frame: creating one is expensive, and it is safe to use from any thread.
    private let ciContext = CIContext()

    /// Starts capturing `screen` (the one the regions were selected on) and cropping the regions out of every frame.
    /// Regions are in points with a top-left origin, relative to that screen.
    @MainActor
    func startCapture(multiViewerRegion: CGRect?, clockAppRegion: CGRect?, on screen: NSScreen?) {
        let previousTask = captureTask
        captureTask = Task {
            await previousTask?.value
            guard !isCapturing else { return }
            failure = nil

            do {
                // Throws SCStreamError.userDeclined when Screen Recording isn't allowed for this app.
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                // Find the SCDisplay for that screen by display ID. (Their frames use different
                // coordinate systems and only agree on the primary display.)
                guard let screen,
                      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let targetDisplay = availableContent.displays.first(where: { $0.displayID == displayID }) else {
                    print("Error: Could not find target SCDisplay.")
                    failure = .displayNotFound
                    return
                }
                let scaleFactor = screen.backingScaleFactor

                // Leave this app's own windows out of the capture, as Apple's ScreenCaptureKit sample does,
                let ownApps = availableContent.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: targetDisplay, excludingApplications: ownApps, exceptingWindows: [])

                let streamConfig = SCStreamConfiguration()
                // Use backingScaleFactor from NSScreen for correct pixel dimensions
                streamConfig.width = Int(CGFloat(targetDisplay.width) * scaleFactor)
                streamConfig.height = Int(CGFloat(targetDisplay.height) * scaleFactor)
                streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.idleFrameRate))
                streamConfig.queueDepth = 5
                streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
                streamConfig.scalesToFit = true // Important for matching display coordinates
                streamConfig.showsCursor = false

                let settings = CropSettings(multiViewerRegion: multiViewerRegion,
                                            clockAppRegion: clockAppRegion,
                                            scaleFactor: scaleFactor)
                cropSettings.withLock { $0 = settings }

                let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
                self.stream = stream
                streamConfiguration = streamConfig
                frameRate = Self.idleFrameRate

                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoOutputQueue)
                try await stream.startCapture()

                isCapturing = self.stream === stream // false if it already stopped with an error
            } catch {
                print("Error starting capture: \(error.localizedDescription)")
                stream = nil
                cropSettings.withLock { $0 = nil }
                isCapturing = false
                failure = Self.isPermissionDenied(error) ? .permissionDenied : .failed
            }
        }
    }

    @MainActor
    func stopCapture() {
        let previousTask = captureTask
        captureTask = Task {
            await previousTask?.value
            failure = nil
            guard isCapturing, let stream = self.stream else { return }
            self.stream = nil // Ignore callbacks from this stream while it stops

            do {
                try await stream.stopCapture()
            } catch {
                print("Error stopping capture: \(error.localizedDescription)")
            }
            // Even if stop fails, update UI state and clear the images and regions
            isCapturing = false
            multiViewerImage = nil; multiViewerFrameTime = nil
            clockAppImage = nil
            cropSettings.withLock { $0 = nil }
        }
    }

    // MARK: Tick recording
    @MainActor
    func recordTicks(for duration: Double) async -> TickRecording? {
        guard isCapturing, let stream else { return nil }
        recordingID += 1
        let id = recordingID
        guard await setFrameRate(Self.measuringFrameRate, of: stream) else { return nil }

        try? await Task.sleep(for: .seconds(Self.settleTime))
        guard id == recordingID else { return nil }

        // Start from what is on screen now, so the first change has a frame to be compared with.
        var start = Recorder()
        let now = multiViewerFrameTime ?? RaceTimer.hostNow()
        start.multiViewer.add(multiViewerImage, at: now)
        start.clockApp.add(clockAppImage, at: now)
        recorder.withLockUnchecked { $0 = start }

        try? await Task.sleep(for: .seconds(duration))
        guard id == recordingID else { return nil }

        let recorded = recorder.withLockUnchecked { recorder in
            defer { recorder = nil }
            return recorder
        }
        if self.stream === stream {
            _ = await setFrameRate(Self.idleFrameRate, of: stream)
        }
        guard let recorded else { return nil }
        return TickRecording(multiViewer: recorded.multiViewer.frames, clockApp: recorded.clockApp.frames)
    }

    /// Changes the running stream's frame rate with `SCStream.updateConfiguration`, without restarting it.
    /// False if the stream didn't take the new configuration.
    @MainActor
    private func setFrameRate(_ framesPerSecond: Int, of stream: SCStream) async -> Bool {
        guard let streamConfiguration else { return false }
        // Apple: "specify the minimum frame interval as the reciprocal of the maximum frame rate".
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        do {
            try await stream.updateConfiguration(streamConfiguration)
        } catch {
            print("Error changing the frame rate: \(error.localizedDescription)")
            return false
        }
        if self.stream === stream { frameRate = framesPerSecond }
        return true
    }

    /// ScreenCaptureKit reports a missing Screen Recording permission as `SCStreamError.userDeclined`.
    private static func isPermissionDenied(_ error: Error) -> Bool {
        (error as? SCStreamError)?.code == .userDeclined
    }

    // MARK: Cropping

    /// Where `region` (points, top-left origin) sits in a frame, in Core Image's pixel coordinates
    /// (bottom-left origin), clamped to the frame. Nil if nothing of it is inside the frame.
    static func pixelRect(for region: CGRect, scaleFactor: CGFloat, in frameExtent: CGRect) -> CGRect? {
        let rect = CGRect(x: frameExtent.minX + region.minX * scaleFactor,
                          y: frameExtent.maxY - region.maxY * scaleFactor,
                          width: region.width * scaleFactor,
                          height: region.height * scaleFactor)
            .integral
            .intersection(frameExtent)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// Renders just `region` of a frame, so the full display is never drawn.
    static func crop(_ frame: CIImage, to region: CGRect, scaleFactor: CGFloat, context: CIContext) -> CGImage? {
        guard let rect = pixelRect(for: region, scaleFactor: scaleFactor, in: frame.extent) else {
            print("Engine: region \(region) is outside the captured frame \(frame.extent)")
            return nil
        }
        return context.createCGImage(frame, from: rect)
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate -
extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // Only complete frames carry a new image; idle ones (nothing on screen changed) have none.
        // Same check as Apple's "Capturing screen content in macOS" sample.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRawValue = info[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // When the frame was actually shown on screen (mach absolute time), falling back to "now".
        var frameTime = RaceTimer.hostNow()
        if let displayTime = info[.displayTime] as? UInt64 {
            frameTime = RaceTimer.seconds(fromMachTime: displayTime)
        }

        // Only process while a stream's crop settings are in place.
        // This runs on videoOutputQueue, so take one consistent copy from behind the lock.
        guard let settings = cropSettings.withLock({ $0 }) else { return }

        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let newMultiViewerImage = settings.multiViewerRegion.flatMap {
            Self.crop(frame, to: $0, scaleFactor: settings.scaleFactor, context: ciContext)
        }
        let newClockAppImage = settings.clockAppRegion.flatMap {
            Self.crop(frame, to: $0, scaleFactor: settings.scaleFactor, context: ciContext)
        }

        // During a tick recording, keep every frame that changed, with the time it was on screen.
        recorder.withLockUnchecked { recorder in
            recorder?.multiViewer.add(newMultiViewerImage, at: frameTime)
            recorder?.clockApp.add(newClockAppImage, at: frameTime)
        }

        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            // Update only if the new crop was successful to avoid flickering nil
            if let newMultiViewerImage {
                self.multiViewerImage = newMultiViewerImage
                self.multiViewerFrameTime = frameTime
            }
            if let newClockAppImage {
                self.clockAppImage = newClockAppImage
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped unexpectedly with error: \(error.localizedDescription)")
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            self.cropSettings.withLock { $0 = nil }
            self.isCapturing = false
            self.multiViewerImage = nil; self.multiViewerFrameTime = nil
            self.clockAppImage = nil
            // The feed cards show why; reselecting a region starts capture again.
            self.failure = Self.isPermissionDenied(error) ? .permissionDenied : .stopped
        }
    }
}