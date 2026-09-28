import Testing
@testable import KBCore

// TEST: the display math on `DownloadProgress`. The transfer itself is URLSession's
// job and isn't exercised here; what breaks silently is the indeterminate case.

@Suite("Download progress")
struct DownloadProgressTests {
    @Test func fractionIsNilWhenTheServerReportsNoLength() {
        // -1 is what URLSession hands back with no Content-Length; a naive divide
        // would report a negative "fraction" and drive the bar backwards.
        #expect(DownloadProgress(received: 5_000_000, expected: -1).fraction == nil)
        #expect(DownloadProgress(received: 5_000_000, expected: -1).expectedMB == nil)
    }

    @Test func fractionClampsAtOne() {
        #expect(DownloadProgress(received: 120, expected: 100).fraction == 1)
    }

    @Test func megabytesRoundForDisplay() {
        let progress = DownloadProgress(received: 1_600_000, expected: 310_000_000)
        #expect(progress.receivedMB == 2)
        #expect(progress.expectedMB == 310)
    }
}
