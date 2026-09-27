import Foundation

@main struct BLETests {
    static func main() {
        let frame = BLEFrame(session: 0x12345678, sequence: 0x01020304, enabled: true, modifiers: 2, keys: [26,4,26])
        assert(frame.data.count == 20)
        assert(Array(frame.data.prefix(10)) == [1,1,0x78,0x56,0x34,0x12,4,3,2,1])
        assert(BLEFrame(data: frame.data) == frame)
        assert(frame.keys == [4,26])
        assert(BLEFrame(data: Data(repeating: 0, count: 19)) == nil)
        var invalid = frame.data; invalid[18] = 1
        assert(BLEFrame(data: invalid) == nil)
        let release = BLEFrame(session: 1, sequence: 1, enabled: false, modifiers: 255, keys: [4])
        assert(release.modifiers == 0 && release.keys.isEmpty)
        let rollover = BLEFrame(session: 1, sequence: 1, enabled: true, modifiers: 0, keys: [4,5,6,7,8,9,10])
        assert(rollover.keys == Array(repeating: 1, count: 6))
        assert(BLEFrame(data: rollover.data) == rollover)
        func ack(_ f: BLEFrame, session: UInt32? = nil) -> BLEFrame {
            BLEFrame(kind: 2, session: session ?? f.session, sequence: f.sequence, enabled: f.enabled, modifiers: f.modifiers, keys: f.keys)
        }
        var q = BLEOutbox(session: 42)
        assert(q.enqueue(enabled: true, modifiers: 0, keys: [26]))
        let down = q.next(now: 10)!
        assert(q.enqueue(enabled: true, modifiers: 0, keys: []))
        assert(q.next(now: 10.1) == nil)
        assert(!q.acknowledge(ack(down, session: 99)))
        assert(!q.acknowledge(down))
        assert(q.acknowledge(ack(down))) // notification may precede didWrite callback
        assert(q.next(now: 10.1) == nil)
        q.markWritten()
        let up = q.next(now: 10.2)!
        assert(up.keys.isEmpty && up.sequence == down.sequence + 1)
        assert(!q.acknowledge(ack(down))) // stale ACK cannot complete the next write
        q.markWritten(); assert(q.inFlight != nil)
        assert(q.acknowledge(ack(up))); assert(q.inFlight == nil)
        assert(q.enqueue(enabled: true, modifiers: 0, keys: [4]))
        _ = q.next(now: 20)
        assert(!q.timedOut(now: 20.49)); assert(q.timedOut(now: 20.51))
        assert(q.enqueue(enabled: true, modifiers: 0, keys: [5]))
        assert(q.enqueue(enabled: false, modifiers: 0, keys: []))
        assert(q.pending.count == 1 && !q.pending[0].enabled)
        assert(q.enqueue(enabled: false, modifiers: 0, keys: []))
        assert(q.pending.count == 1) // repeated stop must not drop the queued release
        var capped = BLEOutbox(session: 1)
        for i in 0..<32 { assert(capped.enqueue(enabled: true, modifiers: 0, keys: [UInt8(4+i)])) }
        assert(!capped.enqueue(enabled: true, modifiers: 0, keys: [99]))
        assert(capped.enqueue(enabled: false, modifiers: 0, keys: []))
        assert(capped.pending.count == 1)
        var rollQueue = BLEOutbox(session: 2)
        assert(rollQueue.enqueue(enabled: true, modifiers: 0, keys: [4,5,6,7,8,9,10]))
        assert(rollQueue.next(now: 0)!.keys == Array(repeating: 1, count: 6))
        print("PASS: BLE wire format, rollover, edge order, both ACK orders, stale ACK rejection, timeout, queue limit, priority release")
    }
}
