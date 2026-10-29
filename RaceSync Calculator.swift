import SwiftUI
import Vision
import AppKit // Needed for NSWindow, NSScreen, NSColor, etc.
import ScreenCaptureKit
// MARK: - Capture Engine
class CaptureEngine: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var multiViewerImage: CGImage?
    @Published var clockAppImage: CGImage?

    private var stream: SCStream?
    // Store regions using top-left origin convention, matching ScreenCaptureKit
    private var multiViewerRegionRectTopLeft: CGRect?
    private var clockAppRegionRectTopLeft: CGRect?

    private let videoOutputQueue = DispatchQueue(label: "com.example.videoOutputQueue", qos: .userInitiated)
    private var screen: NSScreen? // Store the NSScreen being captured

    // Store references to the regions passed during startCapture
    // Note: This function now EXPECTS top-left coordinates
    func startCapture(multiViewerRegionTopLeft: CGRect?, clockAppRegionTopLeft: CGRect?) {
        guard !isCapturing else { return }

        self.multiViewerRegionRectTopLeft = multiViewerRegionTopLeft
        self.clockAppRegionRectTopLeft = clockAppRegionTopLeft

        Task {
            do {
                // Basic check - real permission check is complex and handled by OS prompt
                guard await checkScreenCapturePermission() else {
                    print("Screen capture permission denied.")
                    // Maybe add user feedback here
                    return
                }

                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                // Find the main screen NSScreen first
                self.screen = NSScreen.main

                // Find the corresponding SCDisplay
                guard let targetDisplay = availableContent.displays.first(where: { $0.frame == self.screen?.frame }) ?? availableContent.displays.first else {
                    print("Error: Could not find target SCDisplay.")
                    self.screen = nil // Clear screen if SCDisplay not found
                    // Add user feedback
                    return
                }

                 guard let actualScreen = self.screen else {
                     print("Error: NSScreen instance is nil.")
                     // Add user feedback
                     return
                 }
                 let scaleFactor = actualScreen.backingScaleFactor

                let filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: [])

                let streamConfig = SCStreamConfiguration()
                // Use backingScaleFactor from NSScreen for correct pixel dimensions
                streamConfig.width = Int(CGFloat(targetDisplay.width) * scaleFactor)
                streamConfig.height = Int(CGFloat(targetDisplay.height) * scaleFactor)
                streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 5) // 5 fps is likely sufficient
                streamConfig.queueDepth = 5 // Increased queue depth slightly
                streamConfig.pixelFormat = kCVPixelFormatType_32BGRA // Explicitly set common format
                streamConfig.scalesToFit = true // Important for matching display coordinates
                streamConfig.showsCursor = false

                self.stream = SCStream(filter: filter, configuration: streamConfig, delegate: self) // Set delegate

                try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoOutputQueue)
                try await self.stream?.startCapture()

                await MainActor.run { // Use MainActor for UI updates
                    self.isCapturing = true
                }
            } catch {
                print("Error starting capture: \(error.localizedDescription)")
                self.screen = nil // Clear screen on error
                await MainActor.run { // Use MainActor for UI updates
                    self.isCapturing = false
                    // Add user feedback about the error
                }
            }
        }
    }

    func stopCapture() {
        guard isCapturing, let stream = self.stream else { return }
        self.stream = nil // Release reference BEFORE stopping

        Task {
            do {
                try await stream.stopCapture()
                await MainActor.run { // Use MainActor for UI updates
                    self.isCapturing = false
                    // Clear images and regions when stopping explicitly
                    self.multiViewerImage = nil
                    self.clockAppImage = nil
                    self.multiViewerRegionRectTopLeft = nil
                    self.clockAppRegionRectTopLeft = nil
                    self.screen = nil // Clear screen reference
                }
            } catch {
                print("Error stopping capture: \(error.localizedDescription)")
                // Even if stop fails, update UI state
                await MainActor.run { self.isCapturing = false }
                self.screen = nil // Still clear screen reference
            }
        }
    }

    // Basic permission check placeholder
    private func checkScreenCapturePermission() async -> Bool {
        // A real implementation would involve checking CGMainDisplayID() != 0
        // or attempting a capture and catching the specific error, but
        // ScreenCaptureKit generally triggers the system prompt automatically.
        return true
    }

    // MARK: Cropping (Uses top-left coordinates and screen scale factor)
    // screenHeightPoints is needed IF converting from bottom-left inside this func,
    // but since we pass top-left now, it's only used for potential debug logging.
    // MARK: Cropping (Correct Conversion: Bottom-Left Points -> Top-Left Pixels)
    private func cropImage(_ image: CGImage, // The full screenshot CGImage
                           to rectBottomLeftPoints: CGRect, // The user selection (bottom-left points)
                           screenScaleFactor: CGFloat,
                           screenHeightPoints: CGFloat) -> CGImage? { // Screen height in POINTS

        // 1. Convert bottom-left points (user selection) to top-left points
        //    y_topLeft_points = screenHeight_points - y_bottomLeft_points - height_points
        let yTopLeftPoints = screenHeightPoints - rectBottomLeftPoints.origin.y - rectBottomLeftPoints.height
        let xTopLeftPoints = rectBottomLeftPoints.origin.x

        // 2. Convert top-left points to top-left PIXELS (for the CGImage's coordinate system)
        //    y_pixel = y_topLeft_points * scaleFactor
        //    x_pixel = x_topLeft_points * scaleFactor
        let xPixels = xTopLeftPoints * screenScaleFactor
        let yPixels = yTopLeftPoints * screenScaleFactor // Y=0 is the top pixel row in CGImage
        let widthPixels = rectBottomLeftPoints.width * screenScaleFactor
        let heightPixels = rectBottomLeftPoints.height * screenScaleFactor

        // 3. Create the final cropping rectangle in PIXEL coordinates (top-left origin)
        let croppingRectPixels = CGRect(
            x: xPixels,
            y: yPixels,
            width: widthPixels,
            height: heightPixels
        )

        // 4. Clamp the pixel rectangle to the actual bounds of the captured image
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clampedRectPixels = croppingRectPixels.intersection(imageBounds)

        // 5. Check for validity (minimum 1x1 pixel)
        guard clampedRectPixels.width >= 1 && clampedRectPixels.height >= 1 else {
            print("Engine: ❌ cropImage returning nil because clampedRectPixels is invalid: \(clampedRectPixels). Original points: \(rectBottomLeftPoints)")
            return nil
        }

         // Debug Print (Optional - uncomment if needed)
         /*
         print("--- Cropping (Correct Logic) ---")
         print("  Input Rect (Bottom-Left Points): \(rectBottomLeftPoints)")
         print("  Screen Height (Points): \(screenHeightPoints)")
         print("  Screen Scale Factor: \(screenScaleFactor)")
         print("  Image Dimensions (Pixels): w=\(image.width), h=\(image.height)")
         print("  --> Calculated Top-Left Points: (x: \(xTopLeftPoints), y: \(yTopLeftPoints))")
         print("  --> Calculated Cropping Rect (Top-Left Pixels): \(croppingRectPixels)")
         print("  --> Clamped Cropping Rect (Top-Left Pixels): \(clampedRectPixels)")
         */

        // 6. Perform the crop using the correctly calculated and clamped top-left pixel rectangle
        return image.cropping(to: clampedRectPixels)
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate
extension CaptureEngine: SCStreamOutput, SCStreamDelegate { // Add SCStreamDelegate
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // Only process if we have regions defined AND a screen reference
        guard (multiViewerRegionRectTopLeft != nil || clockAppRegionRectTopLeft != nil), let screen = self.screen else {
             // print("Skipping frame: No regions defined or screen reference missing.") // Reduce noise
             return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Error: Could not get pixel buffer from sample buffer.")
            return
        }

        let scaleFactor = screen.backingScaleFactor
        let screenHeightPoints = screen.frame.height // Use stored screen's height

        // Create CIImage and CGImage (Consider optimizing CIContext creation)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil) // Creating context per frame might be inefficient
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Error: Could not create CGImage from CIImage.")
            return
        }

        // --- Cropping Logic ---
        var newMultiViewerImage: CGImage? = nil
        if let region = multiViewerRegionRectTopLeft {
            newMultiViewerImage = cropImage(cgImage, to: region, screenScaleFactor: scaleFactor, screenHeightPoints: screenHeightPoints)
        }

        var newClockAppImage: CGImage? = nil
        if let region = clockAppRegionRectTopLeft {
            newClockAppImage = cropImage(cgImage, to: region, screenScaleFactor: scaleFactor, screenHeightPoints: screenHeightPoints)
        }

        // --- Update Published Properties on Main Thread ---
        DispatchQueue.main.async {
            // Update only if the new crop was successful to avoid flickering nil
            if newMultiViewerImage != nil {
                self.multiViewerImage = newMultiViewerImage
            } else if self.multiViewerRegionRectTopLeft != nil {
                 // If a region IS defined, but cropping failed, explicitly set to nil
                 // self.multiViewerImage = nil // Optional: uncomment to clear preview on crop fail
            }

            if newClockAppImage != nil {
                self.clockAppImage = newClockAppImage
            } else if self.clockAppRegionRectTopLeft != nil {
                 // If a region IS defined, but cropping failed, explicitly set to nil
                 // self.clockAppImage = nil // Optional: uncomment to clear preview on crop fail
            }
        }
    }

    // Conformance to SCStreamDelegate to handle errors
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped unexpectedly with error: \(error.localizedDescription)")
        // Ensure UI state reflects the stoppage
        Task {
            await MainActor.run { // Use MainActor for UI updates
                self.isCapturing = false
                self.multiViewerImage = nil
                self.clockAppImage = nil
                // Consider whether to clear regions or keep them for restart attempt
                // self.multiViewerRegionRectTopLeft = nil
                // self.clockAppRegionRectTopLeft = nil
                self.screen = nil // Clear screen reference
                // Potentially show an error message to the user here
            }
        }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @ObservedObject var captureEngine: CaptureEngine

    private enum InputField: Hashable {
        case sessionTime
        case currentDelay
    }

    @FocusState private var focusedField: InputField?
    @State private var sessionTimeBounds = CGRect.zero
    @State private var currentDelayBounds = CGRect.zero

    // State variables to store the REGIONS SELECTED BY THE USER (bottom-left origin from RegionSelectionView)
    @State private var multiViewerRegionBottomLeft: CGRect?
    @State private var clockAppRegionBottomLeft: CGRect?
    @State private var manualTimeInput: String = ""
    @State private var currentDelay: String = ""
    @State private var recommendedDelay: String = ""
    @State private var isSelectingMultiViewerRegion: Bool = false // Used for visual feedback if needed
    @State private var isSelectingClockAppRegion: Bool = false  // Used for visual feedback if needed
    @State private var multiViewerOcrResult: String = "" // For display/debug
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
            captureEngine.stopCapture() // Stop capture when view disappears
            stopCountdown() // Stop countdown timer
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
                        isSelectingMultiViewerRegion = true // Keep for potential UI feedback
                        selectScreenRegion { selectedRegion in // This completion gives BOTTOM-LEFT rect
                            if let region = selectedRegion {
                                self.multiViewerRegionBottomLeft = region // Store the bottom-left rect
                                // Restart capture using the NEW regions (will be converted)
                                restartCaptureWithCurrentRegions()
                            }
                            isSelectingMultiViewerRegion = false
                        }
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 100)

                            if multiViewerRegionBottomLeft != nil { // Check if bottom-left region is set
                                Text("Multi Viewer Region Selected")
                                    .foregroundColor(.green) // Indicate success
                            } else {
                                Text("Capture region: Multi Viewer timer")
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Preview of captured image (using CaptureEngine's published image)
                    if let image = captureEngine.multiViewerImage {
                        VStack {
                            Image(nsImage: image.nsImage) // Use helper extension
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 100)
                                .border(Color.blue, width: 1)
                        }
                    } else if multiViewerRegionBottomLeft != nil && captureEngine.isCapturing { // Check if region selected
                        Text("Waiting for capture...")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(height: 100) // Match button height
                            .padding(4)
                    } else {
                         // Placeholder if no region selected or not capturing
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
                        selectScreenRegion { selectedRegion in // This completion gives BOTTOM-LEFT rect
                            if let region = selectedRegion {
                                self.clockAppRegionBottomLeft = region // Store the bottom-left rect
                                // Restart capture using the NEW regions (will be converted)
                                restartCaptureWithCurrentRegions()
                            }
                            isSelectingClockAppRegion = false
                        }
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 45)

                            if clockAppRegionBottomLeft != nil { // Check if bottom-left region is set
                                Text("Clock App Region Selected")
                                    .foregroundColor(.green) // Indicate success
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

                    // Preview of clock app image (using CaptureEngine's published image)
                    if let image = captureEngine.clockAppImage {
                        Image(image, scale: 1.0, label: Text("Clock Preview")) // Use helper extension
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 100)
                            .border(Color.green, width: 1)
                    } else if clockAppRegionBottomLeft != nil && captureEngine.isCapturing { // Check if region selected
                        Text("Waiting for capture...")
                             .font(.caption)
                             .foregroundColor(.orange)
                             .frame(height: 100) // Match size approximately
                             .padding(4)
                    } else {
                         // Placeholder
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
            .buttonStyle(BorderedButtonStyle()) // Changed to Bordered for better visibility
            .controlSize(.large)
            .disabled(!captureEngine.isCapturing || multiViewerRegionBottomLeft == nil || currentDelay.isEmpty || Int(currentDelay) == nil) // Disable if not ready

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended delay (ms)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    TextField("", text: $recommendedDelay)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(true) // Read-only but selectable
                        .foregroundColor(recommendedDelay.starts(with: "Error:") ? .red : .primary) // Error color
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

            // Display OCR results for debugging (optional)
            // Text("MV OCR: \(multiViewerOcrResult)")
            //      .font(.caption)
            //      .foregroundColor(.gray)

        }
    }

    // MARK: - Helper Functions
    func selectScreenRegion(completion: @escaping (CGRect?) -> Void) {
        // Create a borderless, transparent window that covers the whole screen
        let selectionWindow = NSWindow(
            contentRect: NSScreen.main!.frame,
            // Style mask allows it to become key to receive input, but is borderless
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        selectionWindow.backgroundColor = NSColor.clear // Transparent background
        selectionWindow.isOpaque = false              // Allows content underneath to be seen
        selectionWindow.level = .screenSaver          // Place it above most other windows
        selectionWindow.hasShadow = false             // No shadow
        selectionWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // Behaves well with spaces/fullscreen
        selectionWindow.isMovableByWindowBackground = false // Prevent accidental dragging
        let selectionView = RegionSelectionView(completion: { selectedRect in
            selectionWindow.orderOut(nil) // Dismiss the window
            completion(selectedRect)      // Pass the selected rect (bottom-left) back
        })

        selectionWindow.contentView = NSHostingView(rootView: selectionView)
        // Make the window visible and active to capture mouse events
        selectionWindow.makeKeyAndOrderFront(nil)
    }

    // Function to convert Bottom-Left CGRect (from selection) to Top-Left CGRect (for CaptureEngine)
    func convertToTopLeft(rectBottomLeft: CGRect) -> CGRect? {
        guard let screenHeight = NSScreen.main?.frame.height else {
            print("Error: Could not get screen height for coordinate conversion.")
            return nil
        }
        // Formula: y_topLeft = screenHeight - y_bottomLeft - height
        return CGRect(x: rectBottomLeft.origin.x,
                      y: screenHeight - rectBottomLeft.origin.y - rectBottomLeft.height,
                      width: rectBottomLeft.width,
                      height: rectBottomLeft.height)
    }

    // Function to restart capture, converting stored bottom-left regions to top-left
    func restartCaptureWithCurrentRegions() {
        captureEngine.stopCapture()

        let multiViewerTopLeft = multiViewerRegionBottomLeft.flatMap { convertToTopLeft(rectBottomLeft: $0) }
        let clockAppTopLeft = clockAppRegionBottomLeft.flatMap { convertToTopLeft(rectBottomLeft: $0) }

        // Add a small delay to ensure stopCapture completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { // Reduced delay slightly
            // Call the new startCapture with the correct parameter names and top-left coordinates
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
                    completion(recognizedText) // Return full text if no time match
                }
            } catch {
                 print("Regex Error: \(error)")
                 completion(recognizedText) // Return full text on regex error
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.revision = VNRecognizeTextRequestRevision3 // Use latest revision if available
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
            "^(\\d{1,2}):(\\d{1,2}):(\\d{1,2})\\.(\\d{1,3})$", // HH:MM:SS.ms
            "^(\\d{1,2}):(\\d{1,2}):(\\d{1,2})$",             // HH:MM:SS
            "^(\\d{1,2}):(\\d{1,2})\\.(\\d{1,3})$",           // MM:SS.ms
            "^(\\d{1,2}):(\\d{1,2})$"                         // MM:SS
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
                    case 0: // HH:MM:SS.ms
                        hours = valAt(1) ?? 0; minutes = valAt(2) ?? 0; seconds = valAt(3) ?? 0; milliseconds = msValAt(4) ?? 0
                    case 1: // HH:MM:SS
                        hours = valAt(1) ?? 0; minutes = valAt(2) ?? 0; seconds = valAt(3) ?? 0
                    case 2: // MM:SS.ms
                        minutes = valAt(1) ?? 0; seconds = valAt(2) ?? 0; milliseconds = msValAt(3) ?? 0
                    case 3: // MM:SS
                        minutes = valAt(1) ?? 0; seconds = valAt(2) ?? 0
                    default: break
                    }
                    // Basic validation
                    guard minutes < 60, seconds < 60, milliseconds < 1000 else { continue }
                    return (hours, minutes, seconds, milliseconds)
                }
            } catch { continue } // Ignore regex errors silently
        }
        print("Failed to parse time string: '\(timeString)'")
        return nil
    }

    private func normalizeMilliseconds(_ msString: String) -> Int {
        let ms = Int(msString) ?? 0
        switch msString.count {
        case 1: return ms * 100 // .1 -> 100ms
        case 2: return ms * 10  // .12 -> 120ms
        default: return ms      // .123 -> 123ms or .1234 -> 123ms (truncates)
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
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in // Keep 100ms interval
            if self.countdownTimeMs > 100 { // Decrement normally
                 self.countdownTimeMs -= 100
            } else { // Reached end
                 self.countdownTimeMs = 0
                 self.countdownTimer?.invalidate()
                 self.isCountdownRunning = false
             }
        }
        countdownTimer?.tolerance = 0.02 // Allow some tolerance
    }

    func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountdownRunning = false
        // Do not reset countdownTimeMs here, keep the last value
    }


    func getCurrentCountdownTimeString() -> String {
        let time = max(0, countdownTimeMs) // Ensure non-negative
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

    // Use this performSync to PREVENT the clock check when region not selected
    func performSync() {
        guard let multiViewerImage = captureEngine.multiViewerImage else {
            DispatchQueue.main.async { self.recommendedDelay = "Error: No Multi Viewer image" }
            return
        }

        // START OCR - This is the main source of delay
        performOCR(on: multiViewerImage) { [self] multiViewerTimeString in
            // --- OCR Completion Block (Runs AFTER OCR finishes) ---
            guard let multiViewerTime = multiViewerTimeString, parseTimeString(multiViewerTime) != nil else {
                DispatchQueue.main.async {
                    self.multiViewerOcrResult = multiViewerTimeString ?? "OCR Failed"
                    self.recommendedDelay = "Error: Invalid MV Time (\(multiViewerTimeString ?? "N/A"))"
                }
                return
            }
            DispatchQueue.main.async { self.multiViewerOcrResult = multiViewerTime }
            // Check if user INTENDED to capture clock via selection
            if self.clockAppRegionBottomLeft != nil {
                // Clock region WAS selected by user, proceed to check image/OCR
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
                // Clock region was NEVER selected by user, skip clock image check entirely
                print("ℹ️ No Clock region selected. Falling back to Countdown/Manual.") // Log that we are skipping
                self.fallbackToCountdownOrManual(multiViewerTimeString: multiViewerTime) // Go straight to fallback
            }
            // --- End of OCR Completion Block ---
        }
        // --- performSync returns immediately after starting OCR ---
        // --- The rest happens later when OCR completes ---
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
            // Ensure recommended delay isn't negative
            self.recommendedDelay = String(max(0, recommendedDelayMs))
        }
    }
}

// MARK: - Region Selection View
// This simple view is hosted in the temporary selection window
struct RegionSelectionView: View {
    @Environment(\.dismiss) var dismiss // Use dismiss environment action

    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    var completion: (CGRect?) -> Void

    var body: some View {
        ZStack {
            // Semi-transparent overlay to capture clicks/drags anywhere
            Color.black.opacity(0.15) // Slightly more visible overlay
                .edgesIgnoringSafeArea(.all)
                .onTapGesture { // Allow clicking background to cancel
                    if startPoint == nil { // Only cancel if not currently dragging
                        completion(nil)
                        // Dismiss is handled by the NSWindow orderOut in selectScreenRegion
                    }
                }

            // Draw the selection rectangle dynamically during drag
            if let start = startPoint, let current = currentPoint {
                let selectionRect = makeRect(from: start, to: current)
                Rectangle()
                    .fill(Color.blue.opacity(0.2)) // Fill color
                    .overlay(Rectangle().stroke(Color.blue.opacity(0.8), lineWidth: 1)) // Border
                    .frame(width: selectionRect.width, height: selectionRect.height)
                     // Position the top-left corner of the frame
                    .position(x: selectionRect.midX, y: selectionRect.midY)
            }

             // Instructions Text
             Text("Drag to select region. Click background to cancel.")
                 .font(.system(size: 16, weight: .semibold))
                 .foregroundColor(.white)
                 .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                 .background(Color.black.opacity(0.7))
                 .cornerRadius(8)
                 .shadow(radius: 5)
                 // Position near the top-center
                 .position(x: NSScreen.main?.frame.midX ?? 200, y: 60)

        }
        .edgesIgnoringSafeArea(.all) // Ensure ZStack covers the entire screen
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global) // Use screen coords
                .onChanged { value in
                    // Set start point only on the first change event
                    if startPoint == nil {
                        startPoint = value.startLocation
                    }
                    currentPoint = value.location // Update current location continuously
                }
                .onEnded { value in
                    // Only proceed if the drag actually started (startPoint is not nil)
                    if let start = startPoint {
                        // Use the final location directly - it's NOT optional
                        let end = value.location
                        let finalRect = makeRect(from: start, to: end)

                        // Validate minimum size before completing
                        if finalRect.width > 5 && finalRect.height > 5 { // Min 5x5 points
                            // Completion provides the rect with BOTTOM-LEFT origin
                            completion(finalRect)
                        } else {
                            print("Selection too small, cancelling.")
                            completion(nil) // Treat very small drags as cancellation
                        }
                    } else {
                        // If startPoint is nil, it means no valid drag occurred (maybe just a tap ended)
                        completion(nil)
                    }
                    // Reset state; window closure is handled by selectScreenRegion
                    self.startPoint = nil
                    self.currentPoint = nil
                }
        )
        // No need for .onTapGesture on the whole view if background handles cancel
    }

    // Helper to create CGRect from two points (handles dragging any direction)
    // Returns rect in the coordinate space used by DragGesture (.global -> screen bottom-left)
    private func makeRect(from p1: CGPoint, to p2: CGPoint) -> CGRect {
        return CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y), // Y is min (bottom-left origin)
            width: abs(p1.x - p2.x),
            height: abs(p1.y - p2.y)
        )
    }
}

// MARK: - Image Helpers
// These extensions are needed to display CGImage in SwiftUI Image views.
extension Image {
    // Convenience initializer for CGImage
    init(_ cgImage: CGImage, scale: CGFloat, label: Text) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        self.init(nsImage: nsImage)
    }
}

extension CGImage {
    // Computed property to easily convert CGImage to NSImage
    var nsImage: NSImage {
        return NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

@main
struct RaceSync_CalculatorApp: App {
    // This is important - initialize the engine at the app level
    @StateObject private var captureEngine = CaptureEngine()
    
    var body: some Scene {
        WindowGroup {
            ContentView(captureEngine: captureEngine)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}
