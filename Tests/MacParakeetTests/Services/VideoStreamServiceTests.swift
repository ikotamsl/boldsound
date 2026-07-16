import XCTest
@testable import MacParakeetCore

final class VideoStreamServiceTests: XCTestCase {
    func testInvalidateCacheDoesNotCrash() {
        let service = VideoStreamService()
        // Invalidating a non-cached URL should be a no-op
        service.invalidateCache(for: "https://www.youtube.com/watch?v=abc123")
    }
}
