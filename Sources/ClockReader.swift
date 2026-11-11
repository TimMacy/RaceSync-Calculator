import Foundation
import CoreGraphics
import Vision

// MARK: - Clock times -

/// Times as the clocks show them: "49:50", "1:59:43", "12:34.5".
enum ClockTime {
    // Only the first field may be one digit: "4:30" is a time, "43:0" and "1:59:4" are cut off.
    private static let wholeString = try! NSRegularExpression(
        pattern: "^(\\d{1,2}):(\\d{2})(?::(\\d{2}))?(?:\\.(\\d{1,3}))?$")
    // The same shape inside other text, with no digit or colon left over on either side,
    // so a clipped "1:59:4" isn't taken as "1:59".
    private static let insideText = try! NSRegularExpression(
        pattern: "(?<![\\d:.])\\d{1,2}:\\d{2}(?::\\d{2})?(?:\\.\\d{1,3})?(?![\\d:]|\\.\\d)")

    /// Milliseconds for a complete time (MM:SS or H:MM:SS, with optional fractions), or nil.
    static func milliseconds(_ timeString: String) -> Int? {
        let string = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = string as NSString
        guard let match = wholeString.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func field(_ i: Int) -> String? {
            let range = match.range(at: i)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        guard let first = field(1).flatMap({ Int($0) }), let second = field(2).flatMap({ Int($0) }) else { return nil }

        let hours: Int, minutes: Int, seconds: Int
        if let third = field(3).flatMap({ Int($0) }) {
            (hours, minutes, seconds) = (first, second, third) // H:MM:SS
        } else {
            (hours, minutes, seconds) = (0, first, second)     // MM:SS
        }
        guard minutes < 60, seconds < 60 else { return nil }

        var fraction = 0
        if let digits = field(4), let value = Int(digits) {
            fraction = digits.count == 1 ? value * 100 : digits.count == 2 ? value * 10 : value // .5 -> 500 ms
        }
        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + fraction
    }

    /// The first whole time in a line of recognized text, or nil.
    static func firstTime(in text: String) -> String? {
        let ns = text as NSString
        guard let match = insideText.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range)
    }
}

// MARK: - Clock reading -

/// Reads the clock in a captured image with Vision text recognition.
enum ClockReader {
    /// The time shown in the image ("1:59:43"), or nil. Runs synchronously: call it off the main thread.
    static func readTime(from image: CGImage) -> String? {
        let request = makeRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            print("OCR Request Handler Error: \(error)")
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        // Use the biggest time in the region: the timer itself, not a small clock
        // next to it (e.g. the Clock app's "4:48 PM" above its timer).
        let biggestFirst = observations.sorted { $0.boundingBox.height > $1.boundingBox.height }
        for observation in biggestFirst {
            if let text = observation.topCandidates(1).first?.string, let time = ClockTime.firstTime(in: text) {
                return time
            }
        }

        let recognizedText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        guard let time = ClockTime.firstTime(in: recognizedText) else {
            print("OCR Found Text, but no time pattern match: '\(recognizedText)'")
            return nil
        }
        return time
    }

    /// The first text recognition in a process loads Apple's model, which can take
    /// many seconds on a cold system. Do it at launch so Calculate answers right away.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let width = 160, height = 48
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = ctx.makeImage() else { return }
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([makeRequest()])
        }
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["en-US"]
        return request
    }
}