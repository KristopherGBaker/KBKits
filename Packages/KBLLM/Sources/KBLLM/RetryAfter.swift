import Foundation

/// Reads an HTTP `Retry-After` header value (RFC 9110 section 10.2.3) into a wait in seconds.
///
/// The header is either delay-seconds (`120`) or an HTTP date (`Wed, 21 Oct 2026 07:28:00 GMT`).
/// A date is turned into the time left until it from `now`, and a date already past is 0, so the
/// result is never negative. The two obsolete date forms the RFC still asks recipients to accept
/// (RFC 850 and asctime) are read too. Anything else is nil, so a caller falls back to its own
/// backoff rather than waiting on a guess.
public enum RetryAfter {
    /// The longest wait a header is read as: one day. A valid but absurd value ("100000000000000000", or a date centuries
    /// away) is clamped to it, so a caller converting the wait to an integer count of milliseconds or nanoseconds can
    /// never overflow, and every result is finite.
    public static let maximumSeconds: TimeInterval = 86_400

    /// The wait `value` asks for, in seconds, read at `now`; nil when it is neither form. `now`
    /// is the caller's, never read here: the core keeps off the wall clock, and a test passes a
    /// fixed one.
    public static func seconds(from value: String, now: Date) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // delay-seconds is 1*DIGIT: no sign, no fraction.
        if trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber) {
            // A digit string too long for a Double reads as infinity: clamped like any other huge value.
            guard let seconds = TimeInterval(trimmed), !seconds.isNaN else { return nil }
            return clamp(seconds)
        }
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return clamp(date.timeIntervalSince(now))
            }
        }
        return nil
    }

    /// `seconds` within `0...maximumSeconds` (a past date is no wait); NaN is never passed in.
    private static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(0, seconds), maximumSeconds)
    }

    /// IMF-fixdate, then the obsolete RFC 850 and asctime forms.
    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
        "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
        "EEE MMM d HH:mm:ss yyyy"
    ]
}
