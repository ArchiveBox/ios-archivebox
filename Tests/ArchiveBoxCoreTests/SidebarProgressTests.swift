import Foundation
import Testing
import ArchiveBoxCore

@Test func sidebarKeepsLastCollectionWithoutStallingLiveActivity() throws {
    let decoder = JSONDecoder()
    let pending = try decoder.decode(SidebarProgress.self, from: Data(
        #"{"crawls_active":2,"active_crawls":[{"label":"Newest crawl","status":"started"}],"collection":null}"#.utf8
    ))
    let populated = try decoder.decode(SidebarProgress.self, from: Data(
        #"{"crawls_active":1,"active_crawls":[],"collection":{"snapshots":12,"bytes":345}}"#.utf8
    ))
    let empty = try decoder.decode(SidebarProgress.self, from: Data(
        #"{"crawls_active":0,"active_crawls":[],"collection":{"snapshots":0,"bytes":0}}"#.utf8
    ))

    #expect(pending.retainingCollection(from: nil).collection == nil)
    let merged = pending.retainingCollection(from: populated)
    #expect(merged.collection?.snapshots == 12)
    #expect(merged.collection?.bytes == 345)
    #expect(merged.crawls_active == 2)
    #expect(merged.active_crawls.first?.label == "Newest crawl")
    #expect(empty.retainingCollection(from: merged).collection?.bytes == 0)
}
