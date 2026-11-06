import Foundation
import Darwin

// MARK: - Race Timer -
// In-app replacement for the Mac Clock app's race timer (2 hours, or 1 hour for a sprint).
// Pressing LIGHTS OUT records that instant; the remaining time is always
// the race length minus the real time since then, so it can't fall behind.
// Nothing is saved: every launch starts fresh.

final class RaceTimer: ObservableObject {
    /// FIA maximum race time, as MultiViewer shows it: 2:00:00 counting down.
    static let grandPrixLengthMs = 2 * 60 * 60 * 1000
    /// Sprint races: 1:00:00 counting down.
    static let sprintLengthMs = 1 * 60 * 60 * 1000

    @Published private(set) var lightsOutTime: Double?
    @Published var isSprint = false

    var raceLengthMs: Int { isSprint ? RaceTimer.sprintLengthMs : RaceTimer.grandPrixLengthMs }

    var hasStarted: Bool { lightsOutTime != nil }

    func lightsOut() {
        lightsOutTime = RaceTimer.hostNow()
    }

    func reset() {
        lightsOutTime = nil
    }

    /// Remaining race time at the given host time, or nil before lights out.
    func remainingMs(at hostTime: Double) -> Int? {
        guard let start = lightsOutTime else { return nil }
        let elapsedMs = Int(((hostTime - start) * 1000).rounded())
        return max(0, raceLengthMs - elapsedMs)
    }

    // MARK: Clock

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Monotonic seconds; same clock ScreenCaptureKit uses for frame display times.
    static func hostNow() -> Double {
        seconds(fromMachTime: mach_absolute_time())
    }

    static func seconds(fromMachTime machTime: UInt64) -> Double {
        Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    // MARK: Formatting

    /// "1:59:43" (whole seconds, like MultiViewer)
    static func format(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1_000
        return String(format: "%d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
    }
}
