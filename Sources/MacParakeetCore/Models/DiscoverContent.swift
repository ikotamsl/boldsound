import Foundation

// MARK: - Content Types

public enum DiscoverContentType: String, Sendable, Codable {
    case tip
    case quote
    case affirmation
    case sponsored
}

// MARK: - Content Item

public struct DiscoverItem: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let type: DiscoverContentType
    public let title: String
    public let body: String
    public let icon: String
    public let url: String?
    public let attribution: String?

    public init(
        id: String,
        type: DiscoverContentType,
        title: String,
        body: String,
        icon: String,
        url: String? = nil,
        attribution: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.icon = icon
        self.url = url
        self.attribution = attribution
    }
}

// MARK: - Content Feed

public struct DiscoverFeed: Sendable, Codable, Equatable {
    public let version: Int
    public let items: [DiscoverItem]
    public let featuredIndex: Int

    public init(version: Int, items: [DiscoverItem], featuredIndex: Int = 0) {
        self.version = version
        self.items = items
        self.featuredIndex = featuredIndex
    }

    /// The item designated for the sidebar card preview. Returns nil if feed is empty.
    public var featuredItem: DiscoverItem? {
        guard !items.isEmpty else { return nil }
        let index = min(featuredIndex, items.count - 1)
        return items[max(0, index)]
    }
}
