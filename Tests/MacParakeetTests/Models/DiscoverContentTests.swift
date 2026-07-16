import XCTest
@testable import MacParakeetCore

final class DiscoverContentTests: XCTestCase {
    // MARK: - Codable Round-Trip

    func testDiscoverItemCodableRoundTrip() throws {
        let item = DiscoverItem(
            id: "tip-1",
            type: .tip,
            title: "Test Tip",
            body: "This is a test tip.",
            icon: "lightbulb.fill",
            url: nil,
            attribution: nil
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DiscoverItem.self, from: data)

        XCTAssertEqual(decoded, item)
    }

    func testDiscoverItemWithOptionalFields() throws {
        let item = DiscoverItem(
            id: "sponsored-1",
            type: .sponsored,
            title: "Check This Out",
            body: "A great product.",
            icon: "star.fill",
            url: "https://example.com",
            attribution: "Sponsor Inc."
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DiscoverItem.self, from: data)

        XCTAssertEqual(decoded.url, "https://example.com")
        XCTAssertEqual(decoded.attribution, "Sponsor Inc.")
    }

    func testDiscoverFeedCodableRoundTrip() throws {
        let feed = DiscoverFeed(
            version: 1,
            items: [
                DiscoverItem(id: "tip-1", type: .tip, title: "Tip", body: "Body", icon: "lightbulb.fill"),
                DiscoverItem(id: "quote-1", type: .quote, title: "Quote", body: "Words", icon: "quote.bubble", attribution: "Author"),
            ],
            featuredIndex: 1
        )

        let data = try JSONEncoder().encode(feed)
        let decoded = try JSONDecoder().decode(DiscoverFeed.self, from: data)

        XCTAssertEqual(decoded, feed)
    }

    // MARK: - Featured Item

    func testFeaturedItemReturnsCorrectItem() {
        let items = [
            DiscoverItem(id: "a", type: .tip, title: "First", body: "Body", icon: "star"),
            DiscoverItem(id: "b", type: .quote, title: "Second", body: "Body", icon: "star"),
        ]
        let feed = DiscoverFeed(version: 1, items: items, featuredIndex: 1)

        XCTAssertEqual(feed.featuredItem?.id, "b")
    }

    func testFeaturedItemDefaultsToFirst() {
        let items = [
            DiscoverItem(id: "a", type: .tip, title: "First", body: "Body", icon: "star"),
        ]
        let feed = DiscoverFeed(version: 1, items: items)

        XCTAssertEqual(feed.featuredItem?.id, "a")
    }

    func testFeaturedItemReturnsNilForEmptyFeed() {
        let feed = DiscoverFeed(version: 1, items: [])
        XCTAssertNil(feed.featuredItem)
    }

    func testFeaturedItemClampsOutOfBoundsIndex() {
        let items = [
            DiscoverItem(id: "a", type: .tip, title: "Only", body: "Body", icon: "star"),
        ]
        let feed = DiscoverFeed(version: 1, items: items, featuredIndex: 99)

        XCTAssertEqual(feed.featuredItem?.id, "a")
    }

    func testFeaturedItemClampsNegativeIndex() {
        let items = [
            DiscoverItem(id: "a", type: .tip, title: "Only", body: "Body", icon: "star"),
        ]
        let feed = DiscoverFeed(version: 1, items: items, featuredIndex: -1)

        XCTAssertEqual(feed.featuredItem?.id, "a")
    }

    func testUnknownTypeFailsToDecode() {
        let json = """
        {"id":"x","type":"news","title":"T","body":"B","icon":"s"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(DiscoverItem.self, from: Data(json.utf8)))
    }

    // MARK: - Content Types

    func testAllContentTypesDecodable() throws {
        for type in ["tip", "quote", "affirmation", "sponsored"] {
            let json = """
            {"id":"test","type":"\(type)","title":"T","body":"B","icon":"star"}
            """
            let item = try JSONDecoder().decode(DiscoverItem.self, from: Data(json.utf8))
            XCTAssertEqual(item.type.rawValue, type)
        }
    }
}
