import Foundation

/// Live MM:SS formatter for the TV session time field, following Apple's
/// "Creating a Custom Formatter" guide: AppKit calls `isPartialStringValid` on every
/// key press and applies the returned text and cursor together.
/// Digits only (max 4); the colon is inserted after the minutes, or typed after one digit ("4:" -> "04:").
final class SessionTimeFormatter: Formatter {

    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                       proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
                                       originalString origString: String,
                                       originalSelectedRange origSelRange: NSRange,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let partial = partialStringPtr.pointee as String

        // Reject letters and symbols outright: the key press never reaches the field.
        guard partial.allSatisfy({ $0 == ":" || ($0.isASCII && $0.isNumber) }) else { return false }
        var digits = partial.filter { $0 != ":" }

        // A colon typed after a single digit ("4:") means minutes under ten: keep it as "04:".
        let typedColon = partial.contains(":") && !origString.contains(":")
        let padded = typedColon && partial.prefix(while: { $0 != ":" }).count == 1
        if padded { digits = "0" + digits }
        guard digits.count <= 4 else { return false }

        // Backspacing the trailing colon ("49:" -> "49") removes it instead of re-adding it.
        let deletedColon = partial.count < origString.count && origString.contains(":") && !partial.contains(":")
        let formatted: String
        if digits.count < 2 || (digits.count == 2 && deletedColon) {
            formatted = digits
        } else {
            formatted = String(digits.prefix(2)) + ":" + String(digits.dropFirst(2))
        }
        if formatted == partial { return true } // AppKit keeps the proposed text and cursor

        // Keep the cursor right after the same digit it follows in the proposed text;
        // when it was at the end, it stays at the end.
        let caret = proposedSelRangePtr?.pointee.location ?? partial.utf16.count
        let newCaret: Int
        if caret >= partial.utf16.count {
            newCaret = formatted.utf16.count
        } else {
            let digitsBefore = partial.utf16.prefix(caret).filter { $0 != UInt16(UInt8(ascii: ":")) }.count
                + (padded ? 1 : 0)
            newCaret = digitsBefore + (digitsBefore > 2 ? 1 : 0)
        }

        // Per Apple's docs: returning false with a new string and range applies both.
        partialStringPtr.pointee = formatted as NSString
        proposedSelRangePtr?.pointee = NSRange(location: min(newCaret, formatted.utf16.count), length: 0)
        return false
    }
}