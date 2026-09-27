import Foundation

/// One ATT payload (20 bytes), independent of the negotiated MTU.
struct BLEFrame: Equatable {
    static let serviceUUID = "77E10001-4B42-4D41-8B52-494447453031"
    static let inputUUID = "77E10002-4B42-4D41-8B52-494447453031"
    static let ackUUID = "77E10003-4B42-4D41-8B52-494447453031"
    let kind: UInt8 // 1=input, 2=applied acknowledgement
    let session: UInt32
    let sequence: UInt32
    let enabled: Bool
    let modifiers: UInt8
    let keys: [UInt8]

    init(kind: UInt8 = 1, session: UInt32, sequence: UInt32, enabled: Bool, modifiers: UInt8, keys: [UInt8]) {
        self.kind = kind; self.session = session; self.sequence = sequence
        self.enabled = enabled; self.modifiers = enabled ? modifiers : 0
        let normalized = Array(Set(keys.filter { $0 != 0 })).sorted()
        // USB boot-keyboard ErrorRollOver; never silently lose the seventh key.
        self.keys = enabled ? ((normalized.count > 6 || normalized.contains(1)) ? Array(repeating: 1, count: 6) : normalized) : []
    }
    var data: Data {
        var bytes: [UInt8] = [1, kind]
        for n in [session, sequence] {
            for shift in [0,8,16,24] { bytes.append(UInt8(truncatingIfNeeded: n >> shift)) }
        }
        bytes += [enabled ? 1 : 0, modifiers]
        bytes += keys + Array(repeating: 0, count: 6 - keys.count)
        bytes += [0,0]
        return Data(bytes)
    }
    init?(data: Data) {
        let b = Array(data)
        guard b.count == 20, b[0] == 1, [1,2].contains(b[1]), b[10] <= 1, b[18] == 0, b[19] == 0 else { return nil }
        func number(_ i: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[i+$1]) << (8*$1) } }
        kind = b[1]; session = number(2); sequence = number(6); enabled = b[10] == 1; modifiers = b[11]
        keys = Array(b[12..<18]).filter { $0 != 0 }
        guard enabled || (modifiers == 0 && keys.isEmpty) else { return nil }
    }
    func acknowledges(_ input: BLEFrame) -> Bool {
        kind == 2 && session == input.session && sequence == input.sequence && enabled == input.enabled && modifiers == input.modifiers && keys == input.keys
    }
}

/// Bounded FIFO: preserve short key-down/up edges; a stop discards queued input.
struct BLEOutbox {
    struct State: Equatable { let enabled: Bool; let modifiers: UInt8; let keys: [UInt8] }
    private(set) var pending: [State] = []
    private(set) var inFlight: BLEFrame?
    private(set) var startedAt: TimeInterval = 0
    private var written = false
    private var applied = false
    private var lastState: State?
    private var sequence: UInt32 = 0
    let session: UInt32
    init(session: UInt32) { self.session = session }
    mutating func enqueue(enabled: Bool, modifiers: UInt8, keys: [UInt8]) -> Bool {
        let f = BLEFrame(session: session, sequence: 0, enabled: enabled, modifiers: modifiers, keys: keys)
        let state = State(enabled: f.enabled, modifiers: f.modifiers, keys: f.keys)
        if state == lastState && (inFlight != nil || !pending.isEmpty) { return true }
        if !enabled { pending.removeAll() }
        guard pending.count < 32 else { return false }
        pending.append(state); lastState = state; return true
    }
    mutating func next(now: TimeInterval) -> BLEFrame? {
        guard inFlight == nil, !pending.isEmpty, sequence < UInt32.max else { return nil }
        let s = pending.removeFirst(); sequence += 1
        let frame = BLEFrame(session: session, sequence: sequence, enabled: s.enabled, modifiers: s.modifiers, keys: s.keys)
        inFlight = frame; startedAt = now; written = false; applied = false
        return frame
    }
    mutating func markWritten() { written = true; complete() }
    mutating func acknowledge(_ ack: BLEFrame) -> Bool {
        guard let input = inFlight, ack.acknowledges(input), !applied else { return false }
        applied = true; complete(); return true
    }
    private mutating func complete() { if written && applied { inFlight = nil } }
    func timedOut(now: TimeInterval) -> Bool { inFlight != nil && now - startedAt > 0.5 }
}
