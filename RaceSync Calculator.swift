import SwiftUI
import Vision
import AppKit
import ScreenCaptureKit
class CaptureEngine: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var multiViewerImage: CGImage?
    @Published var clockAppImage: CGImage?

    private var stream: SCStream?
    private var multiViewerRegionRectTopLeft: CGRect?
    private var clockAppRegionRectTopLeft: CGRect?

    private let videoOutputQueue = DispatchQueue(label: "com.example.videoOutputQueue", qos: .userInitiated)
    private var screen: NSScreen?

    func startCapture(multiViewerRegionTopLeft: CGRect?, clockAppRegionTopLeft: CGRect?) {
        guard !isCapturing else { return }

        self.multiViewerRegionRectTopLeft = multiViewerRegionTopLeft
        self.clockAppRegionRectTopLeft = clockAppRegionTopLeft

        Task {
            do {
                guard await checkScreenCapturePermission() else {
                    print("Screen capture permission denied.")
                    return
                }

                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                self.screen = NSScreen.main

                guard let targetDisplay = availableContent.displays.first(where: { $0.frame == self.screen?.frame }) ?? availableContent.displays.first else {
                    print("Error: Could not find target SCDisplay.")
                    self.screen = nil
                    return
                }

                 guard let actualScreen = self.screen else {
                     print("Error: NSScreen instance is nil.")
                     return
                 }
                 let scaleFactor = actualScreen.backingScaleFactor

                let filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: [])

                let streamConfig = SCStreamConfiguration()
                streamConfig.width = Int(CGFloat(targetDisplay.width) * scaleFactor)
                streamConfig.height = Int(CGFloat(targetDisplay.height) * scaleFactor)
                streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 5)
                streamConfig.queueDepth = 5
                streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
                streamConfig.scalesToFit = true
                streamConfig.showsCursor = false

                self.stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

                try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoOutputQueue)
                try await self.stream?.startCapture()

                await MainActor.run {
                    self.isCapturing = true
                }
            } catch {
                print("Error starting capture: \(error.localizedDescription)")
                self.screen = nil
                await MainActor.run {
                    self.isCapturing = false
                }
            }
        }
    }

    func stopCapture() {
        guard isCapturing, let stream = self.stream else { return }
        self.stream = nil

        Task {
            do {
                try await stream.stopCapture()
                await MainActor.run {
                    self.isCapturing = false
                    self.multiViewerImage = nil
                    self.clockAppImage = nil
                    self.multiViewerRegionRectTopLeft = nil
                    self.clockAppRegionRectTopLeft = nil
                    self.screen = nil
                }
            } catch {
                print("Error stopping capture: \(error.localizedDescription)")
                await MainActor.run { self.isCapturing = false }
                self.screen = nil
            }
        }
    }

    private func checkScreenCapturePermission() async -> Bool {
        return true
    }

    private func cropImage(_ image: CGImage,
                           to rectBottomLeftPoints: CGRect,
                           screenScaleFactor: CGFloat,
                           screenHeightPoints: CGFloat) -> CGImage? {

        let yTopLeftPoints = screenHeightPoints - rectBottomLeftPoints.origin.y - rectBottomLeftPoints.height
        let xTopLeftPoints = rectBottomLeftPoints.origin.x

        let xPixels = xTopLeftPoints * screenScaleFactor
        let yPixels = yTopLeftPoints * screenScaleFactor
        let widthPixels = rectBottomLeftPoints.width * screenScaleFactor
        let heightPixels = rectBottomLeftPoints.height * screenScaleFactor

        let croppingRectPixels = CGRect(
            x: xPixels,
            y: yPixels,
            width: widthPixels,
            height: heightPixels
        )

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clampedRectPixels = croppingRectPixels.intersection(imageBounds)

        guard clampedRectPixels.width >= 1 && clampedRectPixels.height >= 1 else {
            print("Engine: ❌ cropImage returning nil because clampedRectPixels is invalid: \(clampedRectPixels). Original points: \(rectBottomLeftPoints)")
            return nil
        }

        return image.cropping(to: clampedRectPixels)
    }
}

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        guard (multiViewerRegionRectTopLeft != nil || clockAppRegionRectTopLeft != nil), let screen = self.screen else {
             return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Error: Could not get pixel buffer from sample buffer.")
            return
        }

        let scaleFactor = screen.backingScaleFactor
        let screenHeightPoints = screen.frame.height

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Error: Could not create CGImage from CIImage.")
            return
        }

        var newMultiViewerImage: CGImage? = nil
        if let region = multiViewerRegionRectTopLeft {
            newMultiViewerImage = cropImage(cgImage, to: region, screenScaleFactor: scaleFactor, screenHeightPoints: screenHeightPoints)
        }

        var newClockAppImage: CGImage? = nil
        if let region = clockAppRegionRectTopLeft {
            newClockAppImage = cropImage(cgImage, to: region, screenScaleFactor: scaleFactor, screenHeightPoints: screenHeightPoints)
        }

        DispatchQueue.main.async {
            if newMultiViewerImage != nil {
                self.multiViewerImage = newMultiViewerImage
            } else if self.multiViewerRegionRectTopLeft != nil {
            }

            if newClockAppImage != nil {
                self.clockAppImage = newClockAppImage
            } else if self.clockAppRegionRectTopLeft != nil {
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped unexpectedly with error: \(error.localizedDescription)")
        Task {
            await MainActor.run {
                self.isCapturing = false
                self.multiViewerImage = nil
                self.clockAppImage = nil
                self.screen = nil
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var captureEngine: CaptureEngine

    private enum InputField: Hashable {
        case sessionTime
        case currentDelay
    }

    @FocusState private var focusedField: InputField?
    @State private var sessionTimeBounds = CGRect.zero
    @State private var currentDelayBounds = CGRect.zero

    @State private var multiViewerRegionBottomLeft: CGRect?
    @State private var clockAppRegionBottomLeft: CGRect?
    @State private var manualTimeInput: String = ""
    @State private var currentDelay: String = ""
    @State private var recommendedDelay: String = ""
    @State private var isSelectingMultiViewerRegion: Bool = false
    @State private var isSelectingClockAppRegion: Bool = false
    @State private var multiViewerOcrResult: String = ""
    @State private var countdownTimer: Timer?
    @State private var countdownTimeMs: Int = 0
    @State private var isCountdownRunning: Bool = false
    init(captureEngine: CaptureEngine) {
        self.captureEngine = captureEngine
    }

    var body: some View {
        VStack(spacing: 0) {
            calculator
                .padding()
                .frame(width: 600)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Link("View on GitHub ↗", destination: URL(string: "https://github.com/TimMacy/RaceSync-Calculator")!)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .pointerStyle(.link)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 600)
        .contentShape(Rectangle())
        .coordinateSpace(name: "calculatorWindow")
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("calculatorWindow"))
                .onEnded { tap in
                    if !sessionTimeBounds.contains(tap.location) && !currentDelayBounds.contains(tap.location) {
                        focusedField = nil
                    }
                }
        )
        .onDisappear {
            captureEngine.stopCapture()
            stopCountdown()
        }
    }

    private var calculator: some View {
        VStack(spacing: 20) {
            Text("RaceSync Calculator")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)

            HStack {
                VStack {
                    Button(action: {
                        isSelectingMultiViewerRegion = true
                        selectScreenRegion { selectedRegion in
                            if let region = selectedRegion {
                                self.multiViewerRegionBottomLeft = region
                                restartCaptureWithCurrentRegions()
                            }
                            isSelectingMultiViewerRegion = false
                        }
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 100)

                            if multiViewerRegionBottomLeft != nil {
                                Text("Multi Viewer Region Selected")
                                    .foregroundColor(.green)
                            } else {
                                Text("Capture region: Multi Viewer timer")
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())

                    if let image = captureEngine.multiViewerImage {
                        VStack {
                            Image(nsImage: image.nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 100)
                                .border(Color.blue, width: 1)
                        }
                    } else if multiViewerRegionBottomLeft != nil && captureEngine.isCapturing {
                        Text("Waiting for capture...")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(height: 100)
                            .padding(4)
                    } else {
                         Rectangle()
                             .fill(Color.gray.opacity(0.1))
                             .frame(height: 100)
                             .overlay(Text("No Capture").font(.caption).foregroundColor(.secondary))
                             .cornerRadius(4)
                    }
                }

                VStack {
                    Button(action: {
                        isSelectingClockAppRegion = true
                        selectScreenRegion { selectedRegion in
                            if let region = selectedRegion {
                                self.clockAppRegionBottomLeft = region
                                restartCaptureWithCurrentRegions()
                            }
                            isSelectingClockAppRegion = false
                        }
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 45)

                            if clockAppRegionBottomLeft != nil {
                                Text("Clock App Region Selected")
                                    .foregroundColor(.green)
                            } else {
                                Text("Capture region: Mac clock app")
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session time")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("e.g., 34:20", text: $manualTimeInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .accessibilityLabel("Session time")
                            .focused($focusedField, equals: .sessionTime)
                            .onGeometryChange(for: CGRect.self) { geometry in
                                geometry.frame(in: .named("calculatorWindow"))
                            } action: { bounds in
                                sessionTimeBounds = bounds
                            }
                    }
                    .frame(height: 45)

                    if let image = captureEngine.clockAppImage {
                        Image(image, scale: 1.0, label: Text("Clock Preview"))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 100)
                            .border(Color.green, width: 1)
                    } else if clockAppRegionBottomLeft != nil && captureEngine.isCapturing {
                        Text("Waiting for capture...")
                             .font(.caption)
                             .foregroundColor(.orange)
                             .frame(height: 100)
                             .padding(4)
                    } else {
                         Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(height: 100)
                            .overlay(Text("No Capture").font(.caption).foregroundColor(.secondary))
                            .cornerRadius(4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Current MultiViewer delay (ms)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("", text: $currentDelay)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .accessibilityLabel("Current MultiViewer delay in milliseconds")
                    .focused($focusedField, equals: .currentDelay)
                    .onGeometryChange(for: CGRect.self) { geometry in
                        geometry.frame(in: .named("calculatorWindow"))
                    } action: { bounds in
                        currentDelayBounds = bounds
                    }
            }

            Button("Calculate delay") {
                performSync()
            }
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.large)
            .disabled(!captureEngine.isCapturing || multiViewerRegionBottomLeft == nil || currentDelay.isEmpty || Int(currentDelay) == nil)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended delay (ms)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    TextField("", text: $recommendedDelay)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(true)
                        .foregroundColor(recommendedDelay.starts(with: "Error:") ? .red : .primary)
                        .accessibilityLabel("Recommended delay in milliseconds")

                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(recommendedDelay, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .help("Copy to clipboard")
                    .disabled(recommendedDelay.isEmpty || recommendedDelay.starts(with: "Error:"))
                }
            }
            .padding(.vertical, 8)

        }
    }

    func selectScreenRegion(completion: @escaping (CGRect?) -> Void) {
        let selectionWindow = NSWindow(
            contentRect: NSScreen.main!.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        selectionWindow.backgroundColor = NSColor.clear
        selectionWindow.isOpaque = false
        selectionWindow.level = .screenSaver
        selectionWindow.hasShadow = false
        selectionWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        selectionWindow.isMovableByWindowBackground = false
        let selectionView = RegionSelectionView(completion: { selectedRect in
            selectionWindow.orderOut(nil)
            completion(selectedRect)
        })

        selectionWindow.contentView = NSHostingView(rootView: selectionView)
        selectionWindow.makeKeyAndOrderFront(nil)
    }

    func convertToTopLeft(rectBottomLeft: CGRect) -> CGRect? {
        guard let screenHeight = NSScreen.main?.frame.height else {
            print("Error: Could not get screen height for coordinate conversion.")
            return nil
        }
        return CGRect(x: rectBottomLeft.origin.x,
                      y: screenHeight - rectBottomLeft.origin.y - rectBottomLeft.height,
                      width: rectBottomLeft.width,
                      height: rectBottomLeft.height)
    }

    func restartCaptureWithCurrentRegions() {
        captureEngine.stopCapture()

        let multiViewerTopLeft = multiViewerRegionBottomLeft.flatMap { convertToTopLeft(rectBottomLeft: $0) }
        let clockAppTopLeft = clockAppRegionBottomLeft.flatMap { convertToTopLeft(rectBottomLeft: $0) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            captureEngine.startCapture(multiViewerRegionTopLeft: multiViewerTopLeft,
                                       clockAppRegionTopLeft: clockAppTopLeft)
        }
    }

    func performOCR(on image: CGImage, completion: @escaping (String?) -> Void) {
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                let observations = request.results as? [VNRecognizedTextObservation],
                !observations.isEmpty else {
                print("OCR Error or no observations: \(error?.localizedDescription ?? "Unknown")")
                completion(nil)
                return
            }
            let recognizedText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let timePattern = "\\b\\d+:\\d+(?::\\d+)?(?:\\.\\d+)?\\b"
            do {
                let timeRegex = try NSRegularExpression(pattern: timePattern)
                let nsString = recognizedText as NSString
                let range = NSRange(location: 0, length: nsString.length)
                if let match = timeRegex.firstMatch(in: recognizedText, options: [], range: range) {
                    let timeString = nsString.substring(with: match.range)
                    completion(timeString)
                } else {
                    print("OCR Found Text, but no time pattern match: '\(recognizedText)'")
                    completion(recognizedText)
                }
            } catch {
                 print("Regex Error: \(error)")
                 completion(recognizedText)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["en-US"]
        do {
            try requestHandler.perform([request])
        } catch {
            print("OCR Request Handler Error: \(error)")
            completion(nil)
        }
    }

    func parseTimeString(_ timeString: String) -> (hours: Int, minutes: Int, seconds: Int, milliseconds: Int)? {
        let cleanedString = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "^(\\d{1,2}):(\\d{1,2}):(\\d{1,2})\\.(\\d{1,3})$",
            "^(\\d{1,2}):(\\d{1,2}):(\\d{1,2})$",
            "^(\\d{1,2}):(\\d{1,2})\\.(\\d{1,3})$",
            "^(\\d{1,2}):(\\d{1,2})$"
        ]
        for (index, pattern) in patterns.enumerated() {
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let nsString = cleanedString as NSString
                let range = NSRange(location: 0, length: nsString.length)
                if let match = regex.firstMatch(in: cleanedString, options: [], range: range) {
                    var hours = 0, minutes = 0, seconds = 0, milliseconds = 0
                    func valAt(_ i: Int) -> Int? { Int(nsString.substring(with: match.range(at: i))) }
                    func msValAt(_ i: Int) -> Int? { normalizeMilliseconds(nsString.substring(with: match.range(at: i))) }

                    switch index {
                    case 0:
                        hours = valAt(1) ?? 0; minutes = valAt(2) ?? 0; seconds = valAt(3) ?? 0; milliseconds = msValAt(4) ?? 0
                    case 1:
                        hours = valAt(1) ?? 0; minutes = valAt(2) ?? 0; seconds = valAt(3) ?? 0
                    case 2:
                        minutes = valAt(1) ?? 0; seconds = valAt(2) ?? 0; milliseconds = msValAt(3) ?? 0
                    case 3:
                        minutes = valAt(1) ?? 0; seconds = valAt(2) ?? 0
                    default: break
                    }
                    guard minutes < 60, seconds < 60, milliseconds < 1000 else { continue }
                    return (hours, minutes, seconds, milliseconds)
                }
            } catch { continue }
        }
        print("Failed to parse time string: '\(timeString)'")
        return nil
    }

    private func normalizeMilliseconds(_ msString: String) -> Int {
        let ms = Int(msString) ?? 0
        switch msString.count {
        case 1: return ms * 100
        case 2: return ms * 10
        default: return ms
        }
    }

    func timeComponentsToMilliseconds(hours: Int, minutes: Int, seconds: Int, milliseconds: Int) -> Int {
        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds
    }

    func calculateTimeDifference(time1: String, time2: String) -> Int? {
        guard let components1 = parseTimeString(time1), let components2 = parseTimeString(time2) else {
            print("Error calculating difference: Could not parse one or both times ('\(time1)', '\(time2)')")
            return nil
        }
        let milliseconds1 = timeComponentsToMilliseconds(hours: components1.hours, minutes: components1.minutes, seconds: components1.seconds, milliseconds: components1.milliseconds)
        let milliseconds2 = timeComponentsToMilliseconds(hours: components2.hours, minutes: components2.minutes, seconds: components2.seconds, milliseconds: components2.milliseconds)
        return milliseconds2 - milliseconds1
    }

    func startCountdown(from timeString: String) {
        guard let timeComponents = parseTimeString(timeString) else {
             print("Error starting countdown: Invalid time format '\(timeString)'")
             return
        }
        let totalMilliseconds = timeComponentsToMilliseconds(hours: timeComponents.hours, minutes: timeComponents.minutes, seconds: timeComponents.seconds, milliseconds: timeComponents.milliseconds)
        guard totalMilliseconds > 0 else {
            print("Error starting countdown: Time must be positive.")
            isCountdownRunning = false
            countdownTimeMs = 0
            return
        }

        countdownTimeMs = totalMilliseconds
        isCountdownRunning = true
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if self.countdownTimeMs > 100 {
                 self.countdownTimeMs -= 100
            } else {
                 self.countdownTimeMs = 0
                 self.countdownTimer?.invalidate()
                 self.isCountdownRunning = false
             }
        }
        countdownTimer?.tolerance = 0.02
    }

    func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountdownRunning = false
    }

    func getCurrentCountdownTimeString() -> String {
        let time = max(0, countdownTimeMs)
        let hours = time / 3_600_000
        let minutes = (time % 3_600_000) / 60_000
        let seconds = (time % 60_000) / 1_000
        let milliseconds = time % 1_000
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        } else {
            return String(format: "%d:%02d.%03d", minutes, seconds, milliseconds)
        }
    }

    func performSync() {
        guard let multiViewerImage = captureEngine.multiViewerImage else {
            DispatchQueue.main.async { self.recommendedDelay = "Error: No Multi Viewer image" }
            return
        }

        performOCR(on: multiViewerImage) { [self] multiViewerTimeString in
            guard let multiViewerTime = multiViewerTimeString, parseTimeString(multiViewerTime) != nil else {
                DispatchQueue.main.async {
                    self.multiViewerOcrResult = multiViewerTimeString ?? "OCR Failed"
                    self.recommendedDelay = "Error: Invalid MV Time (\(multiViewerTimeString ?? "N/A"))"
                }
                return
            }
            DispatchQueue.main.async { self.multiViewerOcrResult = multiViewerTime }
            if self.clockAppRegionBottomLeft != nil {
                print("ℹ️ Clock region was selected, attempting to use captured image...")
                if let clockAppImage = captureEngine.clockAppImage {
                    performOCR(on: clockAppImage) { [self] clockAppTimeString in
                        if let clockTime = clockAppTimeString, parseTimeString(clockTime) != nil {
                            print("✅ Using Clock App OCR result: \(clockTime)")
                            self.calculateDelay(multiViewerTime: multiViewerTime, referenceTime: clockTime)
                        } else {
                            print("⚠️ Clock region selected, but OCR failed ('\(clockAppTimeString ?? "N/A")'). Falling back...")
                            self.fallbackToCountdownOrManual(multiViewerTimeString: multiViewerTime)
                        }
                    }
                } else {
                    print("⚠️ Clock region selected, but no image available from engine. Falling back...")
                    self.fallbackToCountdownOrManual(multiViewerTimeString: multiViewerTime)
                }
            } else {
                print("ℹ️ No Clock region selected. Falling back to Countdown/Manual.")
                self.fallbackToCountdownOrManual(multiViewerTimeString: multiViewerTime)
            }
        }
    }

    private func fallbackToCountdownOrManual(multiViewerTimeString: String) {
        if isCountdownRunning {
            let countdownTimeString = getCurrentCountdownTimeString()
            calculateDelay(multiViewerTime: multiViewerTimeString, referenceTime: countdownTimeString)
        } else if !manualTimeInput.isEmpty {
            let cleanedManual = manualTimeInput.trimmingCharacters(in: .whitespaces)
            if parseTimeString(cleanedManual) != nil {
                calculateDelay(multiViewerTime: multiViewerTimeString, referenceTime: cleanedManual)
            } else {
                DispatchQueue.main.async {
                    self.recommendedDelay = "Error: Invalid Manual Time (\(cleanedManual))"
                }
            }
        } else {
            DispatchQueue.main.async {
                self.recommendedDelay = "Error: No reference time available"
            }
        }
    }

    func calculateDelay(multiViewerTime: String, referenceTime: String) {
        guard let currentDelayMs = Int(self.currentDelay.trimmingCharacters(in: .whitespaces)) else {
            DispatchQueue.main.async { self.recommendedDelay = "Error: Invalid current delay" }
            return
        }
        guard let timeDifferenceMs = calculateTimeDifference(time1: multiViewerTime, time2: referenceTime) else {
            DispatchQueue.main.async {
                self.recommendedDelay = "Error: Calc Diff Failed (\(multiViewerTime) vs \(referenceTime))"
            }
            return
        }
        let recommendedDelayMs = currentDelayMs + timeDifferenceMs
        DispatchQueue.main.async {
            self.recommendedDelay = String(max(0, recommendedDelayMs))
        }
    }
}

struct RegionSelectionView: View {
    @Environment(\.dismiss) var dismiss

    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    var completion: (CGRect?) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    if startPoint == nil {
                        completion(nil)
                    }
                }

            if let start = startPoint, let current = currentPoint {
                let selectionRect = makeRect(from: start, to: current)
                Rectangle()
                    .fill(Color.blue.opacity(0.2))
                    .overlay(Rectangle().stroke(Color.blue.opacity(0.8), lineWidth: 1))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
            }

             Text("Drag to select region. Click background to cancel.")
                 .font(.system(size: 16, weight: .semibold))
                 .foregroundColor(.white)
                 .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                 .background(Color.black.opacity(0.7))
                 .cornerRadius(8)
                 .shadow(radius: 5)
                 .position(x: NSScreen.main?.frame.midX ?? 200, y: 60)

        }
        .edgesIgnoringSafeArea(.all)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startPoint == nil {
                        startPoint = value.startLocation
                    }
                    currentPoint = value.location
                }
                .onEnded { value in
                    if let start = startPoint {
                        let end = value.location
                        let finalRect = makeRect(from: start, to: end)

                        if finalRect.width > 5 && finalRect.height > 5 {
                            completion(finalRect)
                        } else {
                            print("Selection too small, cancelling.")
                            completion(nil)
                        }
                    } else {
                        completion(nil)
                    }
                    self.startPoint = nil
                    self.currentPoint = nil
                }
        )
    }

    private func makeRect(from p1: CGPoint, to p2: CGPoint) -> CGRect {
        return CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p1.x - p2.x),
            height: abs(p1.y - p2.y)
        )
    }
}

extension Image {
    init(_ cgImage: CGImage, scale: CGFloat, label: Text) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        self.init(nsImage: nsImage)
    }
}

extension CGImage {
    var nsImage: NSImage {
        return NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

@main
struct RaceSync_CalculatorApp: App {
    @StateObject private var captureEngine = CaptureEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(captureEngine: captureEngine)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}
