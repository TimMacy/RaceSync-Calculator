import SwiftUI

@main
struct RaceSync_CalculatorApp: App {
    @StateObject private var captureEngine = CaptureEngine()

    init() {
        PWFonts.register()
        ClockReader.warmUp()
    }

    var body: some Scene {
        Window("RaceSync Calculator", id: "main") {
            ContentView(captureEngine: captureEngine)
                .fixedSize(horizontal: true, vertical: true)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowResizability(.contentSize)
    }
}