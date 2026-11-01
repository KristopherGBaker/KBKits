import Foundation
import KBLLM
import Testing

/// `Retry-After` in both of its forms, and the error case that carries it.
@Suite struct RetryAfterTests {
    /// 2026-10-21 07:28:00 GMT.
    private let now = Date(timeIntervalSince1970: 1_792_567_680)

    @Test func delaySecondsReadAsSeconds() {
        #expect(RetryAfter.seconds(from: "120", now: now) == 120)
        #expect(RetryAfter.seconds(from: " 0 ", now: now) == 0)
    }

    @Test func anHTTPDateReadsAsTheTimeLeftUntilIt() {
        #expect(RetryAfter.seconds(from: "Wed, 21 Oct 2026 07:28:30 GMT", now: now) == 30)
        // The two obsolete forms RFC 9110 still asks a recipient to accept.
        #expect(RetryAfter.seconds(from: "Wednesday, 21-Oct-26 07:28:05 GMT", now: now) == 5)
        #expect(RetryAfter.seconds(from: "Wed Oct 21 07:28:10 2026", now: now) == 10)
        // A date already past is no wait, never a negative one.
        #expect(RetryAfter.seconds(from: "Wed, 21 Oct 2026 07:00:00 GMT", now: now) == 0)
    }

    @Test func aHugeValueIsClampedToTheMaximumNeverInfiniteOrNegative() throws {
        for value in ["100000000000000000", String(repeating: "9", count: 400), "Fri, 31 Dec 9999 23:59:59 GMT"] {
            let seconds = try #require(RetryAfter.seconds(from: value, now: now), "\(value.prefix(20))")
            #expect(seconds == RetryAfter.maximumSeconds && seconds.isFinite, "\(value.prefix(20))")
            // Safe to turn into whole milliseconds, which an unclamped 1e17 s would overflow.
            #expect(Int64(exactly: (seconds * 1000).rounded()) != nil)
        }
        #expect(RetryAfter.seconds(from: "0", now: now) == 0)
        #expect(RetryAfter.seconds(from: "Thu, 01 Jan 1970 00:00:00 GMT", now: now) == 0, "a past date is no wait")
        #expect(RetryAfter.seconds(from: "-100000000000000000", now: now) == nil, "a negative is not delay-seconds")
    }

    @Test func anythingElseIsNil() {
        for value in ["", "soon", "-5", "1.5", "+3", "Wed, 21 Oct 2026"] {
            #expect(RetryAfter.seconds(from: value, now: now) == nil, "\(value)")
        }
    }

    @Test func theRetryAfterCaseReadsLikeAnHTTPStatus() {
        let carried = KBLLMError.httpStatusRetryAfter(code: 429, message: "slow down", retryAfter: 2)
        #expect(carried.httpStatusCode == 429)
        #expect(carried.httpStatusMessage == "slow down")
        #expect(carried.retryAfter == 2)
        #expect(carried.errorDescription == KBLLMError.httpStatus(code: 429, message: "slow down").errorDescription)

        let plain = KBLLMError.httpStatus(code: 503, message: "")
        #expect(plain.httpStatusCode == 503)
        #expect(plain.retryAfter == nil)
        #expect(KBLLMError.cancelled.httpStatusCode == nil)
    }
}
