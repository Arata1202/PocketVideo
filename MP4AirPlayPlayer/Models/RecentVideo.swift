import Foundation

struct RecentVideo: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var sourceKey: String
    var bookmarkData: Data
    var lastPosition: TimeInterval
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, sourceKey: String, bookmarkData: Data, lastPosition: TimeInterval = 0, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.sourceKey = sourceKey
        self.bookmarkData = bookmarkData
        self.lastPosition = lastPosition
        self.updatedAt = updatedAt
    }
}
