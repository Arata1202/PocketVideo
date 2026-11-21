import Foundation

struct RecentVideo: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var sourceKey: String
    var contentFingerprint: String?
    var contentDigest: String?
    var contentModificationDate: Date?
    var bookmarkData: Data
    var lastPosition: TimeInterval
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        sourceKey: String,
        contentFingerprint: String? = nil,
        contentDigest: String? = nil,
        contentModificationDate: Date? = nil,
        bookmarkData: Data,
        lastPosition: TimeInterval = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.sourceKey = sourceKey
        self.contentFingerprint = contentFingerprint
        self.contentDigest = contentDigest
        self.contentModificationDate = contentModificationDate
        self.bookmarkData = bookmarkData
        self.lastPosition = lastPosition
        self.updatedAt = updatedAt
    }
}
