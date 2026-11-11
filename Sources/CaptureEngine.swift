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

final class CaptureEngine: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var multiViewerImage: CGImage?
    @Published var clockAppImage: CGImage?
    /// Host time (seconds, same clock as `RaceTimer.hostNow()`) at which the current `multiViewerImage` was on screen.
    @Published var multiViewerFrameTime: Double?
    /// Set when capture couldn't start or stopped on its own; cleared by the next start or stop.
    @Published var failure: CaptureFailure?

    private var stream: SCStream? // Main thread only
    @MainActor private var captureTask: Task<Void, Never>?

    /// Everything the frame handler needs to crop a frame, fixed for the life of one stream.
    /// Regions are in points with a top-left origin, relative to the captured screen.
    private struct CropSettings {
        let multiViewerRegion: CGRect?
        let clockAppRegion: CGRect?
        let scaleFactor: CGFloat // points -> pixels
    }
    /// Written on the main thread and read on `videoOutputQueue`, so it sits behind a lock.
    private let cropSettings = OSAllocatedUnfairLock<CropSettings?>(initialState: nil)

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
                // so this window can overlap a selected region without being read as the timer.
                let ownApps = availableContent.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: targetDisplay, excludingApplications: ownApps, exceptingWindows: [])

                let streamConfig = SCStreamConfiguration()
                // Use backingScaleFactor from NSScreen for correct pixel dimensions
                streamConfig.width = Int(CGFloat(targetDisplay.width) * scaleFactor)
                streamConfig.height = Int(CGFloat(targetDisplay.height) * scaleFactor)
                streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 5) // 5 fps is enough for clocks that tick once a second
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