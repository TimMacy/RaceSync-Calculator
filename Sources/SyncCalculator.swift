import Foundation

// MARK: - Sync calculation -

enum SyncOutcome {
    case delay(ms: Int, offsetMs: Int)
    case waitingForMultiViewer
    case error(String)
}

/// Turns the two clock readings into the delay to set in MultiViewer.
enum SyncCalculator {
    /// What the MultiViewer time is compared against: the TV clock.
    enum Reference {
        case fixed(Int)         // typed session time or in-app race timer, in ms
        case clockText(String?) // Mac Clock app as read by text recognition; nil if nothing was read
    }

    /// Clocks further apart than this are a misread (e.g. the hours cut off), not a real offset:
    /// real ones are a few seconds.
    static let maxPlausibleOffsetMs = 30 * 60 * 1000

    /// - Parameters:
    ///   - mvText: MultiViewer's clock as read by text recognition; nil if nothing was read.
    ///   - raceLengthMs: the full race length in race mode, nil in session mode.
    static func evaluate(mvText: String?, reference: Reference,
                         currentDelayMs: Int, raceLengthMs: Int?) -> SyncOutcome {
        // Everything is compared in whole seconds, the way the clocks show it.
        func wholeSeconds(_ ms: Int) -> Int { (ms / 1_000) * 1_000 }

        guard let mvText, let mvRawMs = ClockTime.milliseconds(mvText) else {
            return .error("Couldn't read the MultiViewer time.")
        }
        let mvMs = wholeSeconds(mvRawMs)

        let referenceMs: Int
        switch reference {
        case let .fixed(ms):
            referenceMs = wholeSeconds(ms) // the in-app timer as it is shown
        case let .clockText(clockText):
            guard let clockText, let ms = ClockTime.milliseconds(clockText) else {
                return .error("Couldn't read the Clock app time.")
            }
            referenceMs = wholeSeconds(ms)
        }

        // MultiViewer holds the full race length (2:00:00, or 1:00:00 for a Sprint) until its own lights out.
        if let raceLengthMs, mvMs >= raceLengthMs {
            return .waitingForMultiViewer
        }

        // Both clocks count down: a positive offset means MultiViewer is ahead of the TV.
        let offsetMs = referenceMs - mvMs
        // A partly read clock (say "1:59" from "1:59:43") is still a valid time; catch it here.
        guard abs(offsetMs) <= maxPlausibleOffsetMs else {
            return .error("The two clocks are more than 30 minutes apart. Check that each region shows the whole timer.")
        }
        return .delay(ms: max(0, currentDelayMs + offsetMs), offsetMs: offsetMs)
    }
}