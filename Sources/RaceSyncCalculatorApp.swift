import SwiftUI
import ScreenCaptureKit

@main
struct RaceSync_CalculatorApp: App {
    @StateObject private var captureEngine = CaptureEngine()

    init() {
        PWFonts.register()
        OCRWarmup.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(captureEngine: captureEngine)
                .fixedSize(horizontal: true, vertical: true)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowResizability(.contentSize)
    }
}
