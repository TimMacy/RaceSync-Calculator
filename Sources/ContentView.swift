import SwiftUI
import Vision
import AppKit // Needed for NSWindow, NSScreen, NSColor, etc.
import ScreenCaptureKit

// MARK: - Capture Engine (FROM SECOND VERSION) -

class CaptureEngine: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var multiViewerImage: CGImage?
    @Published var clockAppImage: CGImage?
    /// Host time (seconds, same clock as `RaceTimer.hostNow()`) at which the current `multiViewerImage` was on screen.
    @Published var multiViewerFrameTime: Double?

    private var stream: SCStream?
    @MainActor private var captureTask: Task<Void, Never>?
    // Store regions using top-left origin convention, matching ScreenCaptureKit
    private var multiViewerRegionRectTopLeft: CGRect?
    private var clockAppRegionRectTopLeft: CGRect?

    private let videoOutputQueue = DispatchQueue(label: "com.example.videoOutputQueue", qos: .userInitiated)
    private var screen: NSScreen? // Store the NSScreen being captured

    // Store references to the regions passed during startCapture
    // Note: This function now EXPECTS top-left coordinates
    @MainActor
    func startCapture(multiViewerRegionTopLeft: CGRect?, clockAppRegionTopLeft: CGRect?) {
        let previousTask = captureTask
        captureTask = Task {
            await previousTask?.value
            guard !isCapturing else { return }

            self.multiViewerRegionRectTopLeft = multiViewerRegionTopLeft
            self.clockAppRegionRectTopLeft = clockAppRegionTopLeft
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

    @MainActor
    func stopCapture() {
        let previousTask = captureTask
        captureTask = Task {
            await previousTask?.value
            guard isCapturing, let stream = self.stream else { return }
            self.stream = nil // Ignore callbacks from this stream while it stops

            do {
                try await stream.stopCapture()
                await MainActor.run { // Use MainActor for UI updates
                    self.isCapturing = false
                    // Clear images and regions when stopping explicitly
                    self.multiViewerImage = nil; self.multiViewerFrameTime = nil
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

// MARK: - SCStreamOutput & SCStreamDelegate (FROM SECOND VERSION) -
extension CaptureEngine: SCStreamOutput, SCStreamDelegate { // Add SCStreamDelegate
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // When the frame was actually shown on screen (mach absolute time), falling back to "now".
        var frameTime = RaceTimer.hostNow()
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let displayTime = info[.displayTime] as? UInt64 {
            frameTime = RaceTimer.seconds(fromMachTime: displayTime)
        }

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
            guard self.stream === stream else { return }
            // Update only if the new crop was successful to avoid flickering nil
            if newMultiViewerImage != nil {
                self.multiViewerImage = newMultiViewerImage
                self.multiViewerFrameTime = frameTime
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
                guard self.stream === stream else { return }
                self.stream = nil
                self.isCapturing = false
                self.multiViewerImage = nil; self.multiViewerFrameTime = nil
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

// MARK: - ContentView (Pit Wall layout) -

enum TimerMode: String, CaseIterable, Identifiable {
    case session = "Session timer"
    case race = "Race timer"
    var id: String { rawValue }
}

enum SyncOutcome {
    case delay(ms: Int, offsetMs: Int)
    case waitingForMultiViewer
    case error(String)
}

/// What the MultiViewer time is compared against.
private enum SyncReference {
    case fixed(Int)          // typed session time or in-app race timer, in ms
    case clockImage(CGImage) // Mac Clock app capture, read by OCR
}

struct ContentView: View {
    @ObservedObject var captureEngine: CaptureEngine
    @StateObject private var raceTimer = RaceTimer()

    @State private var mode: TimerMode = .session
    @Namespace private var modeNamespace

    // Regions selected by the user (bottom-left origin from RegionSelectionView)
    @State private var multiViewerRegionBottomLeft: CGRect?
    @State private var clockAppRegionBottomLeft: CGRect?

    @State private var manualTimeInput: String = ""
    @State private var currentDelay: String = ""
    @State private var outcome: SyncOutcome?
    @State private var calculationID = 0
    @State private var confirmReset = false
    @State private var isCalculating = false
    @State private var showReadingHint = false // only if reading takes over a second
    @State private var copied = false
    @State private var copyID = 0
    @State private var isHoveringModeToggle = false

    // Fixed sizes so the window never changes height.
    private static let feedsHeight: CGFloat = 330
    private static let headerHeight: CGFloat = 52
    /// Height of the (hidden) title bar the header sits under.
    private static let titlebarHeight: CGFloat = {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: [.titled, .closable, .miniaturizable])
        return frame.height - content.height
    }()
    private static let sessionFormatter = SessionTimeFormatter()
    private static let resultHeight: CGFloat = 144 // fits the 64 pt number without re-centering

    init(captureEngine: CaptureEngine) {
        self.captureEngine = captureEngine
    }

    /// Race mode uses exactly one source: the Clock app (region selected) or the in-app timer.
    private var usesClockApp: Bool { clockAppRegionBottomLeft != nil }

    var body: some View {
        VStack(spacing: 0) {
            // The header is drawn behind, starting under the title bar; this only reserves the rest of its height.
            Color.clear
                .frame(height: max(0, Self.headerHeight - Self.titlebarHeight))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                SectionLabel("01 · FEEDS")

                HStack(alignment: .top, spacing: 14) {
                    multiViewerCard
                    if mode == .session { sessionCard } else { raceCard }
                }
                .frame(height: Self.feedsHeight)

                SectionLabel("02 · DELAY").padding(.top, 4)

                HStack(alignment: .top, spacing: 14) {
                    currentDelayField
                    offsetField
                }

                resultPanel
                calculateButton
            }
            .padding(24)

            footer
        }
        .frame(width: 640)
        .background(alignment: .top) {
            header.ignoresSafeArea(.container, edges: .top)
        }
        .background(
            PW.background
                .ignoresSafeArea()
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) } // click on the background
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            (note.object as? NSWindow)?.makeFirstResponder(nil) // clicked into another app
        }
        .preferredColorScheme(.dark)
        .onChange(of: mode) { clearOutcome() }
        .onDisappear { captureEngine.stopCapture() }
        .confirmationDialog("Reset the race timer?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { raceTimer.reset(); clearOutcome() }
        } message: {
            Text("The lights-out moment is lost. You can't sync with the in-app timer until it's started again.")
        }
    }

    private func clearOutcome() {
        calculationID += 1 // drop any result still on its way
        isCalculating = false
        showReadingHint = false
        outcome = nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 62) // room for the window's traffic lights
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("RaceSync")
                    .pwDisplay(22)
                    .tracking(1.3)
                    .foregroundStyle(PW.text)
                Text("Calculator")
                    .font(PW.mono(11))
                    .tracking(1.3)
                    .foregroundStyle(PW.muted)
            }
            Spacer()
            modeToggle
        }
        .padding(.horizontal, 16)
        .frame(height: Self.headerHeight)
        .background(PW.header)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture()) // drag the window from anywhere on the header
        .allowsWindowActivationEvents(true)
        .overlay(alignment: .bottom) { PW.divider.frame(height: 1) }
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach(TimerMode.allCases) { m in
                Text(m.rawValue)
                    .font(PW.ui(12, .semibold))
                    .tracking(0.5)
                    .foregroundStyle(mode == m ? PW.text : PW.muted)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background {
                        if mode == m {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(PW.segmentOn)
                                .matchedGeometryEffect(id: "modePill", in: modeNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { mode = m } // no press effect, the highlight just slides over
                    .accessibilityElement()
                    .accessibilityLabel(m.rawValue)
                    .accessibilityAddTraits(mode == m ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { mode = m }
            }
        }
        .animation(.snappy(duration: 0.22), value: mode)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(PW.well))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PW.cardBorder))
    }

    // MARK: Feed A · MultiViewer

    private var multiViewerCard: some View {
        FeedCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    SmallCaps("FEED A")
                    Text("MultiViewer timer").font(PW.ui(13, .semibold)).foregroundStyle(PW.text)
                }
                Spacer()
                multiViewerStatus
            }

            Group {
                if let image = captureEngine.multiViewerImage {
                    CapturePreview(image: image)
                } else {
                    Viewfinder(active: false) {
                        Text(multiViewerRegionBottomLeft == nil ? "No region selected" : "Waiting for capture…")
                            .font(PW.mono(11))
                            .foregroundStyle(PW.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if multiViewerRegionBottomLeft == nil {
                Button("Select MultiViewer timer region") { selectMultiViewerRegion() }
                    .buttonStyle(OutlineButtonStyle())
            } else {
                HStack(spacing: 8) {
                    Button("Reselect region") { selectMultiViewerRegion() }
                        .buttonStyle(OutlineButtonStyle())
                    Button("Clear") {
                        multiViewerRegionBottomLeft = nil
                        clearOutcome()
                        restartCaptureWithCurrentRegions()
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private func selectMultiViewerRegion() {
        selectScreenRegion { region in
            if let region {
                multiViewerRegionBottomLeft = region
                clearOutcome()
                restartCaptureWithCurrentRegions()
            }
        }
    }

    @ViewBuilder private var multiViewerStatus: some View {
        if captureEngine.multiViewerImage != nil {
            StatusPill(text: "LOCKED", color: PW.green, background: PW.greenBG)
        } else if multiViewerRegionBottomLeft != nil {
            StatusPill(text: "WAITING", color: PW.yellow, background: PW.yellowBG)
        } else {
            StatusPill(text: "NO REGION", color: PW.muted, background: PW.well)
        }
    }

    // MARK: Feed B · Session timer

    private var sessionCard: some View {
        FeedCard {
            VStack(alignment: .leading, spacing: 2) {
                SmallCaps("FEED B")
                Text("TV session time").font(PW.ui(13, .semibold)).foregroundStyle(PW.text)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Target time (not reached yet)").font(PW.ui(12)).foregroundStyle(PW.muted)
                WellField(placeholder: "49:50",
                          text: $manualTimeInput,
                          font: PW.mono(34, .bold),
                          color: PW.yellow,
                          alignment: .center,
                          height: 64,
                          formatter: Self.sessionFormatter,
                          nativeFont: NSFont(name: "JetBrainsMono-Bold", size: 34))
            }

            Text("Hit Calculate the moment your TV clock shows this time.")
                .font(PW.ui(12))
                .foregroundStyle(PW.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Feed B · Race timer

    private var raceCard: some View {
        FeedCard(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SmallCaps("FEED B")
                Text("TV race clock").font(PW.ui(13, .semibold)).foregroundStyle(PW.text)
            }

            // Option 1: in-app timer
            HStack {
                SmallCaps("IN-APP TIMER")
                Spacer()
                if raceTimer.hasStarted {
                    StatusPill(text: "IN USE", color: PW.green, background: PW.greenBG)
                }
            }
            .frame(height: 22) // same height with or without the IN USE pill, so the timer doesn't move

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let remaining = raceTimer.remainingMs(at: RaceTimer.hostNow()) ?? raceTimer.raceLengthMs
                Text(RaceTimer.format(remaining))
                    .font(PW.mono(26, .bold))
                    .monospacedDigit()
                    .foregroundStyle(raceTimer.hasStarted ? PW.text : PW.muted)
                    .frame(maxWidth: .infinity)
            }

            if raceTimer.hasStarted {
                Button("Reset timer") { confirmReset = true }
                    .buttonStyle(OutlineButtonStyle(height: 40))
            } else {
                Button {
                    raceTimer.lightsOut()
                    clearOutcome()
                } label: {
                    Text("LIGHTS OUT")
                        .pwDisplay(18)
                        .tracking(1.4)
                }
                .buttonStyle(SolidButtonStyle(fill: PW.lightsButton, foreground: .white, height: 40))
                .disabled(usesClockApp)
                .help(usesClockApp ? "Clear the Clock app region to use the in-app timer"
                                   : "Press when the lights go out on your TV broadcast")
            }

            HStack(spacing: 8) {
                PW.divider.frame(height: 1)
                Text("OR").font(PW.mono(10, .bold)).foregroundStyle(PW.muted)
                PW.divider.frame(height: 1)
            }

            // Option 2: Mac Clock app
            HStack {
                SmallCaps("MAC CLOCK APP")
                Spacer()
                if usesClockApp {
                    StatusPill(text: "IN USE", color: PW.green, background: PW.greenBG)
                }
            }

            if clockAppRegionBottomLeft != nil {
                VStack(spacing: 8) {
                    Group {
                        if let image = captureEngine.clockAppImage {
                            CapturePreview(image: image)
                        } else {
                            Viewfinder(active: false) {
                                Text("Waiting for capture…").font(PW.mono(11)).foregroundStyle(PW.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)

                    HStack(spacing: 8) {
                        Button("Reselect") { selectClockAppRegion() }
                            .buttonStyle(OutlineButtonStyle())
                        Button("Clear") {
                            clockAppRegionBottomLeft = nil
                            clearOutcome()
                            restartCaptureWithCurrentRegions()
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                }
            } else {
                Button("Capture Clock app region") { selectClockAppRegion() }
                    .buttonStyle(OutlineButtonStyle(dashed: true))
                    .disabled(raceTimer.hasStarted)
                    .help(raceTimer.hasStarted ? "Reset the in-app timer to use the Clock app instead" : "")
            }
        }
    }

    private func selectClockAppRegion() {
        selectScreenRegion { region in
            if let region {
                clockAppRegionBottomLeft = region
                clearOutcome()
                restartCaptureWithCurrentRegions()
            }
        }
    }

    // MARK: Delay

    private var currentDelayField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current MultiViewer delay").font(PW.ui(12)).foregroundStyle(PW.muted)
            WellField(placeholder: "0",
                      text: $currentDelay,
                      font: PW.mono(20),
                      color: PW.text,
                      height: 48,
                      background: PW.card,
                      radius: 8,
                      suffix: "ms")
                .onChange(of: currentDelay) { _, new in
                    let digits = new.filter { $0.isASCII && $0.isNumber }
                    if digits != new { currentDelay = digits }
                }
        }
        .frame(maxWidth: .infinity)
    }

    private var offsetField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Offset detected").font(PW.ui(12)).foregroundStyle(PW.muted)
            HStack(spacing: 10) {
                if case let .delay(_, offsetMs) = outcome {
                    Text(String(format: "%+ds", offsetMs / 1000))
                        .font(PW.mono(20, .bold))
                        .foregroundStyle(PW.green)
                    Text(offsetMs > 0 ? "MultiViewer ahead of TV" : offsetMs < 0 ? "MultiViewer behind TV" : "In sync")
                        .font(PW.ui(12))
                        .foregroundStyle(PW.greenSoft)
                } else {
                    Text("—").font(PW.mono(20, .bold)).foregroundStyle(PW.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8).fill(isDelayOutcome ? PW.greenBG : PW.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isDelayOutcome ? PW.greenBorder : PW.inputBorder))
        }
        .frame(maxWidth: .infinity)
    }

    private var isDelayOutcome: Bool {
        if case .delay = outcome { return true }
        return false
    }

    // MARK: Result

    private var resultPanel: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("RECOMMENDED DELAY")
                if showReadingHint {
                    Text("Reading MultiViewer…")
                        .pwDisplay(28)
                        .foregroundStyle(PW.muted)
                } else {
                switch outcome {
                case let .delay(ms, _):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.grouped(ms))
                            .font(PW.mono(64, .bold))
                            .tracking(-1)
                            .foregroundStyle(PW.purple)
                            .textSelection(.enabled)
                        Text("ms").font(PW.mono(16)).foregroundStyle(PW.muted)
                    }
                case .waitingForMultiViewer:
                    Text("Waiting for MultiViewer…")
                        .pwDisplay(28)
                        .foregroundStyle(PW.yellow)
                    Text("MultiViewer still shows \(RaceTimer.format(raceTimer.raceLengthMs)). Hit Calculate again once it starts counting down.")
                        .font(PW.ui(12))
                        .foregroundStyle(PW.muted)
                        .fixedSize(horizontal: false, vertical: true)
                case let .error(message):
                    Text(message)
                        .font(PW.ui(15, .semibold))
                        .foregroundStyle(PW.red)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    Text("—")
                        .font(PW.mono(64, .bold))
                        .foregroundStyle(PW.muted.opacity(0.5))
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Button(action: copyDelay) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(PW.purple)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 10).fill(PW.purpleBG))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PW.purpleEdge))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isDelayOutcome)
            .opacity(isDelayOutcome ? 1 : 0.4)
            .help("Copy to clipboard")
            .accessibilityLabel("Copy recommended delay")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(height: Self.resultHeight)
        .background(RoundedRectangle(cornerRadius: 12).fill(PW.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PW.purpleBorder))
    }

    private var calculateButton: some View {
        Button(action: calculate) {
            HStack(spacing: 12) {
                Text("CALCULATE DELAY")
                    .pwDisplay(20)
                    .tracking(1.6)
                Text("⏎")
                    .font(PW.mono(11, .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(PW.background.opacity(0.14)))
            }
        }
        .buttonStyle(SolidButtonStyle(fill: PW.yellow, foreground: PW.background))
        .keyboardShortcut(.defaultAction)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(captureEngine.isCapturing ? "CAPTURING · 5 FPS" : "NOT CAPTURING")
            Spacer()
            if mode == .session {
                Text("SESSION MODE")
            } else {
                // Locked while the in-app timer runs, so a stray click can't change the race length mid-race.
                // A plain tap target (not a Button) so there's no press highlight; the text just swaps.
                // "MODE" is its own Text pinned to the right edge, so only the first word is redrawn on a swap.
                HStack(spacing: 0) {
                    Text(raceTimer.isSprint ? "SPRINT " : "RACE ")
                    Text("MODE")
                }
                    // Hover tint (Apple HIG: tint, not scale, for small elements). No tint while locked;
                    // the pointer stays the standard arrow either way.
                    .foregroundStyle(isHoveringModeToggle && !raceTimer.hasStarted ? PW.text : PW.muted)
                    .animation(.easeOut(duration: 0.15), value: isHoveringModeToggle)
                    .onHover { isHoveringModeToggle = $0 }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .onTapGesture(perform: toggleSprint)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleSprint() }
                    .help(raceTimer.hasStarted ? "Reset the timer to switch modes"
                          : raceTimer.isSprint ? "Switch to a 2-hour race" : "Switch to a 1-hour sprint race")
            }
        }
        .font(PW.mono(11))
        .tracking(1)
        .foregroundStyle(PW.muted)
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .top) { PW.divider.frame(height: 1) }
    }

    /// Swaps 2-hour race and 1-hour sprint. Locked while the in-app timer runs.
    private func toggleSprint() {
        guard !raceTimer.hasStarted else { return }
        var swap = Transaction()
        swap.disablesAnimations = true
        withTransaction(swap) {
            raceTimer.isSprint.toggle()
            clearOutcome()
        }
    }

    // MARK: - Sync

    private func calculate() {
        guard !isCalculating else { return }

        // Snapshot everything from the same captured frame first.
        let mvImage = captureEngine.multiViewerImage
        let mvFrameTime = captureEngine.multiViewerFrameTime ?? RaceTimer.hostNow()
        let clockImage = captureEngine.clockAppImage

        guard let delayMs = Int(currentDelay.trimmingCharacters(in: .whitespaces)) else {
            outcome = .error("Enter the current MultiViewer delay in ms.")
            return
        }
        guard multiViewerRegionBottomLeft != nil else {
            outcome = .error("Select the MultiViewer timer region first.")
            return
        }
        guard let mvImage else {
            outcome = .error("No MultiViewer image yet. Is screen recording allowed?")
            return
        }

        let reference: SyncReference
        switch mode {
        case .session:
            let target = manualTimeInput.trimmingCharacters(in: .whitespaces)
            guard let ms = milliseconds(target) else {
                outcome = .error("Enter the target session time, e.g. 49:50.")
                return
            }
            reference = .fixed(ms)
        case .race:
            if usesClockApp {
                guard let clockImage else {
                    outcome = .error("No Clock app image yet.")
                    return
                }
                reference = .clockImage(clockImage)
            } else if let ms = raceTimer.remainingMs(at: mvFrameTime) {
                reference = .fixed(ms)
            } else {
                outcome = .error("Press LIGHTS OUT when the lights go out on your TV, or capture the Clock app.")
                return
            }
        }

        // Text recognition can take a while; keep it off the main thread so the app never freezes.
        let raceLengthMs: Int? = mode == .race ? raceTimer.raceLengthMs : nil
        calculationID += 1
        let id = calculationID
        isCalculating = true // the current result stays on screen until the new one is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if isCalculating && id == calculationID { showReadingHint = true }
        }
        let worker = self
        DispatchQueue.global(qos: .userInitiated).async {
            let mvText = worker.readTime(from: mvImage)
            var clockText: String?
            if case let .clockImage(image) = reference {
                clockText = worker.readTime(from: image)
            }
            let result = worker.evaluate(mvText: mvText, reference: reference, clockText: clockText,
                                         currentDelayMs: delayMs, raceLengthMs: raceLengthMs)
            DispatchQueue.main.async {
                guard id == calculationID else { return } // mode or region changed meanwhile
                isCalculating = false
                showReadingHint = false
                outcome = result
            }
        }
    }

    private func evaluate(mvText: String?, reference: SyncReference, clockText: String?,
                          currentDelayMs: Int, raceLengthMs: Int?) -> SyncOutcome {
        // Everything is compared in whole seconds, the way the clocks show it.
        func wholeSeconds(_ ms: Int) -> Int { (ms / 1_000) * 1_000 }

        guard let mvText, let mvRawMs = milliseconds(mvText) else {
            return .error("Couldn't read the MultiViewer time.")
        }
        let mvMs = wholeSeconds(mvRawMs)

        let referenceMs: Int
        switch reference {
        case let .fixed(ms):
            referenceMs = wholeSeconds(ms) // the in-app timer as it is shown
        case .clockImage:
            guard let clockText, let ms = milliseconds(clockText) else {
                return .error("Couldn't read the Clock app time.")
            }
            referenceMs = wholeSeconds(ms)
        }

        // MultiViewer holds the full race length (2:00:00, or 1:00:00 for a sprint) until its own lights out.
        if let raceLengthMs, mvMs >= raceLengthMs {
            return .waitingForMultiViewer
        }

        // Both clocks count down: a positive offset means MultiViewer is ahead of the TV.
        let offsetMs = referenceMs - mvMs
        return .delay(ms: max(0, currentDelayMs + offsetMs), offsetMs: offsetMs)
    }

    private func copyDelay() {
        guard case let .delay(ms, _) = outcome else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(ms), forType: .string)

        copied = true
        copyID += 1
        let id = copyID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if id == copyID { copied = false }
        }
    }

    private func readTime(from image: CGImage) -> String? {
        var result: String?
        performOCR(on: image) { result = $0 } // Vision runs synchronously inside performOCR
        return result
    }

    private func milliseconds(_ timeString: String) -> Int? {
        guard let c = parseTimeString(timeString) else { return nil }
        return timeComponentsToMilliseconds(hours: c.hours, minutes: c.minutes, seconds: c.seconds, milliseconds: c.milliseconds)
    }

    /// 12480 -> "12 480"
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    // MARK: - Region selection & capture

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
        selectionWindow.isReleasedWhenClosed = false // Swift owns the window's lifetime

        let selectionView = RegionSelectionView(completion: { selectedRect in
            selectionWindow.orderOut(nil)
            selectionWindow.contentView = nil // Break the window/view/completion retain cycle
            selectionWindow.close()
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
        // Both regions cleared: leave capture off (the in-app timer keeps running).
        guard multiViewerRegionBottomLeft != nil || clockAppRegionBottomLeft != nil else { return }
        let multiViewerTopLeft = multiViewerRegionBottomLeft.flatMap { convertToTopLeft(rectBottomLeft: $0) }
        let clockAppTopLeft = clockAppRegionBottomLeft.flatMap { convertToTopLeft(rectBottomLeft: $0) }
        // The engine queues this start after the previous capture has finished stopping.
        captureEngine.startCapture(multiViewerRegionTopLeft: multiViewerTopLeft,
                                   clockAppRegionTopLeft: clockAppTopLeft)
    }

    // MARK: - OCR & time parsing (unchanged)

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
            let timePattern = "\\b\\d+:\\d+(?::\\d+)?(?:\\.\\d+)?\\b" // Keep original pattern
            do {
                let timeRegex = try NSRegularExpression(pattern: timePattern)

                // Use the biggest time in the region: the timer itself, not a small clock
                // next to it (e.g. the Clock app's "4:48 PM" above its timer).
                let biggestFirst = observations.sorted { $0.boundingBox.height > $1.boundingBox.height }
                for observation in biggestFirst {
                    guard let text = observation.topCandidates(1).first?.string else { continue }
                    let ns = text as NSString
                    if let match = timeRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                        completion(ns.substring(with: match.range))
                        return
                    }
                }

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

}


// MARK: - Region Selection View (FROM FIRST VERSION) -
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
                        // Window cleanup is handled by selectScreenRegion
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

// MARK: - Image Helpers (FROM FIRST VERSION) -
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


// MARK: - OCR warm-up -
// The first text recognition in a process loads Apple's model, which can take
// many seconds on a cold system. Do it at launch so Calculate answers right away.
enum OCRWarmup {
    static func start() {
        DispatchQueue.global(qos: .utility).async {
            let width = 160, height = 48
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = ctx.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = ["en-US"]
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }
}
