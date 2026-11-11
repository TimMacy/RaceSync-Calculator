import SwiftUI
import AppKit // Needed for NSWindow, NSScreen, NSPasteboard, etc.

// MARK: - ContentView (Pit Wall layout) -

enum TimerMode: String, CaseIterable, Identifiable {
    case session = "Session timer"
    case race = "Race timer"
    var id: String { rawValue }
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

    // Regions selected by the user: points with a top-left origin, relative to `selectionScreen`
    @State private var multiViewerRegion: CGRect?
    @State private var clockAppRegion: CGRect?
    /// The screen the regions were selected on; capture records this one.
    @State private var selectionScreen: NSScreen?

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
    /// Longest current delay that can be typed (99 999 999 ms, over a day), so the sum can't overflow.
    private static let maxDelayDigits = 8

    init(captureEngine: CaptureEngine) {
        self.captureEngine = captureEngine
    }

    /// Race mode uses exactly one source: the Clock app (region selected) or the in-app timer.
    private var usesClockApp: Bool { clockAppRegion != nil }

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
        .background(NoInitialFocus().allowsHitTesting(false)) // no field is selected when the window opens
        .background(alignment: .top) {
            header.ignoresSafeArea(.container, edges: .top)
        }
        .background(PW.background.ignoresSafeArea())
        .onAppear { ClickOutsideEndsEditing.install() } // a click outside a text field deselects it
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
                    Viewfinder {
                        Text(multiViewerRegion == nil ? "No region selected"
                             : captureEngine.failure?.message ?? "Waiting for capture…")
                            .font(PW.mono(11))
                            .foregroundStyle(PW.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if multiViewerRegion == nil {
                Button("Select MultiViewer timer region") { selectMultiViewerRegion() }
                    .buttonStyle(OutlineButtonStyle())
            } else {
                HStack(spacing: 8) {
                    Button("Reselect region") { selectMultiViewerRegion() }
                        .buttonStyle(OutlineButtonStyle())
                    Button("Clear") {
                        multiViewerRegion = nil
                        clearOutcome()
                        restartCaptureWithCurrentRegions()
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private func selectMultiViewerRegion() {
        selectRegion { multiViewerRegion = $0 }
    }

    @ViewBuilder private var multiViewerStatus: some View {
        if captureEngine.multiViewerImage != nil {
            StatusPill(text: "LOCKED", color: PW.green, background: PW.greenBG)
        } else if multiViewerRegion != nil, captureEngine.failure != nil {
            StatusPill(text: "STOPPED", color: PW.red, background: PW.redBG)
        } else if multiViewerRegion != nil {
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

            if clockAppRegion != nil {
                VStack(spacing: 8) {
                    Group {
                        if let image = captureEngine.clockAppImage {
                            CapturePreview(image: image)
                        } else {
                            Viewfinder {
                                Text(captureEngine.failure?.message ?? "Waiting for capture…")
                                    .font(PW.mono(11)).foregroundStyle(PW.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)

                    HStack(spacing: 8) {
                        Button("Reselect") { selectClockAppRegion() }
                            .buttonStyle(OutlineButtonStyle())
                        Button("Clear") {
                            clockAppRegion = nil
                            clearOutcome()
                            restartCaptureWithCurrentRegions()
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                }
            } else {
                Button("Select Clock app timer region") { selectClockAppRegion() }
                    .buttonStyle(OutlineButtonStyle(dashed: true))
                    .disabled(raceTimer.hasStarted)
                    .help(raceTimer.hasStarted ? "Reset the in-app timer to use the Clock app instead" : "")
            }
        }
    }

    private func selectClockAppRegion() {
        selectRegion { clockAppRegion = $0 }
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
                    let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(Self.maxDelayDigits))
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
                          : raceTimer.isSprint ? "Switch to a 2-hour race" : "Switch to a 1-hour Sprint")
            }
        }
        .font(PW.mono(11))
        .tracking(1)
        .foregroundStyle(PW.muted)
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .top) { PW.divider.frame(height: 1) }
    }

    /// Swaps 2-hour race and 1-hour Sprint. Locked while the in-app timer runs.
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
        guard multiViewerRegion != nil else {
            outcome = .error("Select the MultiViewer timer region first.")
            return
        }
        guard let mvImage else {
            outcome = .error(captureEngine.failure?.help ?? "No MultiViewer image yet. Is screen recording allowed?")
            return
        }

        let reference: SyncReference
        switch mode {
        case .session:
            guard let ms = ClockTime.milliseconds(manualTimeInput) else {
                outcome = .error("Enter the target session time, e.g. 49:50.")
                return
            }
            reference = .fixed(ms)
        case .race:
            if usesClockApp {
                guard let clockImage else {
                    outcome = .error(captureEngine.failure?.help ?? "No Clock app image yet.")
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
        DispatchQueue.global(qos: .userInitiated).async {
            let mvText = ClockReader.readTime(from: mvImage)
            let tvClock: SyncCalculator.Reference
            switch reference {
            case let .fixed(ms): tvClock = .fixed(ms)
            case let .clockImage(image): tvClock = .clockText(ClockReader.readTime(from: image))
            }
            let result = SyncCalculator.evaluate(mvText: mvText, reference: tvClock,
                                                 currentDelayMs: delayMs, raceLengthMs: raceLengthMs)
            DispatchQueue.main.async {
                guard id == calculationID else { return } // mode or region changed meanwhile
                isCalculating = false
                showReadingHint = false
                outcome = result
            }
        }
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

    /// Lets the user drag a region on the screen this window is on, then restarts capture with it.
    private func selectRegion(assign: @escaping (CGRect) -> Void) {
        guard let screen = NSScreen.main else { return }
        RegionSelector.selectRegion(on: screen) { region in
            guard let region else { return } // canceled
            selectionScreen = screen
            assign(region)
            clearOutcome()
            restartCaptureWithCurrentRegions()
        }
    }

    private func restartCaptureWithCurrentRegions() {
        captureEngine.stopCapture()
        // Both regions cleared: leave capture off (the in-app timer keeps running).
        guard multiViewerRegion != nil || clockAppRegion != nil else { return }
        // The engine queues this start after the previous capture has finished stopping.
        captureEngine.startCapture(multiViewerRegion: multiViewerRegion,
                                   clockAppRegion: clockAppRegion,
                                   on: selectionScreen)
    }
}