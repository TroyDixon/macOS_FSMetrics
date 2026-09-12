import Foundation

/// Publishes the IDs seen in a completed enumeration, so detached mounts vanish
/// immediately from inventory while their database history remains queryable.
public final class MountInventoryStore {
    struct Snapshot {
        let ids: [Int64]
        let ts: Int64
    }
    private let lock = NSLock()
    private var value: Snapshot?
    public init() {}
    func publish(ids: [Int64], ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        value = Snapshot(ids: ids, ts: ts)
    }
    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
