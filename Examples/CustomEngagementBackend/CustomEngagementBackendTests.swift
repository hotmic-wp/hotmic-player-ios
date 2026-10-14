import Foundation
import Testing

// The Sample's unit target compiles the copyable adapter alongside this focused contract check.
extension EngagementTests {
    @Test("Custom backend rejects missing cursors instead of silently restarting pagination")
    func customBackendCursor() async throws {
        let client = FakeRESTClient()
        client.latency = .zero
        let newest = try await client.getComments(itemID: "cursor-item", before: nil)
        let cursor = try #require(newest.olderCursor)
        let older = try await client.getComments(itemID: "cursor-item", before: cursor)
        #expect(newest.comments.count == 3 && older.comments.count == 3 && older.olderCursor == nil)
        #expect(Set(newest.comments.map(\.id)).isDisjoint(with: older.comments.map(\.id)))
        do {
            _ = try await client.getComments(itemID: "cursor-item", before: "deleted-cursor")
            Issue.record("Missing cursors must fail")
        } catch { #expect((error as? URLError)?.code == .badURL) }
    }
}
