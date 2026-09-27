import Foundation
import CoreBluetooth

/// All callbacks and state live on the main queue, like the AppKit controller.
final class BluetoothTransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device { let id: UUID; let name: String }
    var onDevices: (([Device]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onAck: (() -> Void)?
    private var central: CBCentralManager?
    private var devices: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var ack: CBCharacteristic?
    private var outbox = BLEOutbox(session: 1)
    private var active = false
    private var shouldScan = false
    private var wanted: UUID?
    private var ready = false
    private var retry: DispatchWorkItem?
    private var setupTimeout: DispatchWorkItem?
    private var confirmed = false
    private let savedKey = "bluetoothReceiverID"

    func scan() {
        active = true; shouldScan = true; wanted = nil
        retry?.cancel()
        ensureCentral()
        startScanIfPossible()
    }
    func reconnectSaved() {
        guard let text = UserDefaults.standard.string(forKey: savedKey), let id = UUID(uuidString: text) else {
            scan(); return
        }
        active = true; wanted = id; shouldScan = false
        ensureCentral(); resume()
    }
    func connect(id: UUID) {
        disconnect()
        active = true; wanted = id; shouldScan = false
        ensureCentral(); resume()
    }
    func disconnect() {
        active = false; shouldScan = false; wanted = nil
        retry?.cancel(); setupTimeout?.cancel(); central?.stopScan()
        let old = peripheral
        peripheral = nil; input = nil; ack = nil; confirmed = false
        ready = false; onReady?(false)
        if let old { central?.cancelPeripheralConnection(old) }
    }
    func forget() { disconnect(); UserDefaults.standard.removeObject(forKey: savedKey); onStatus?("已忘记接收器；清除系统蓝牙绑定需在系统设置操作") }
    private func ensureCentral() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }
    private func startScanIfPossible() {
        guard active, shouldScan, central?.state == .poweredOn else { return }
        central?.scanForPeripherals(withServices: [CBUUID(string: BLEFrame.serviceUUID)], options: nil)
        onStatus?("正在扫描键盘桥接收器…（需要配套 BLE 固件）")
    }
    private func resume() {
        guard active, let central, central.state == .poweredOn else { return }
        if shouldScan { startScanIfPossible(); return }
        guard let id = wanted, peripheral == nil else { return }
        if let p = devices[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p; p.delegate = self
            onStatus?("正在连接蓝牙接收器…")
            central.connect(p, options: nil)
            let timeout = DispatchWorkItem { [weak self, weak p] in
                guard let self, let p, self.peripheral === p, !self.confirmed else { return }
                self.fail("蓝牙连接或配对超时")
            }
            setupTimeout?.cancel(); setupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        } else {
            central.scanForPeripherals(withServices: [CBUUID(string: BLEFrame.serviceUUID)], options: nil)
            onStatus?("等待已记住的接收器上线…")
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active else { return }
        switch central.state {
        case .poweredOn: resume()
        case .poweredOff: resetLink(); onStatus?("蓝牙已关闭，请打开 Mac 蓝牙")
        case .unauthorized: resetLink(); onStatus?("请在系统设置 → 隐私与安全性 → 蓝牙中允许键盘桥")
        case .unsupported: resetLink(); onStatus?("这台 Mac 不支持所需的蓝牙功能")
        default: resetLink(); onStatus?("蓝牙正在初始化…")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active else { return }
        devices[p.identifier] = p
        onDevices?(devices.values.map { Device(id: $0.identifier, name: $0.name ?? "键盘桥接收器") }.sorted { $0.id.uuidString < $1.id.uuidString })
        if wanted == p.identifier, peripheral == nil { central.stopScan(); resume() }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard active, peripheral === p else { central.cancelPeripheralConnection(p); return }
        central.stopScan(); p.discoverServices([CBUUID(string: BLEFrame.serviceUUID)])
        onStatus?("正在检查接收器服务与配对…")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === p else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == CBUUID(string: BLEFrame.serviceUUID) }) else { fail("接收器缺少键盘桥服务"); return }
        p.discoverCharacteristics([CBUUID(string: BLEFrame.inputUUID), CBUUID(string: BLEFrame.ackUUID)], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === p else { return }
        input = service.characteristics?.first { $0.uuid == CBUUID(string: BLEFrame.inputUUID) }
        ack = service.characteristics?.first { $0.uuid == CBUUID(string: BLEFrame.ackUUID) }
        guard error == nil, let input, input.properties.contains(.write), let ack, ack.properties.contains(.notify), p.maximumWriteValueLength(for: .withResponse) >= 20 else { fail("接收器 BLE 协议不兼容"); return }
        p.setNotifyValue(true, for: ack)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === p, characteristic === ack else { return }
        guard error == nil, characteristic.isNotifying else { fail("无法订阅接收器响应，请检查配对"); return }
        outbox = BLEOutbox(session: UInt32.random(in: 1...UInt32.max))
        ready = true; confirmed = false
        onStatus?("等待接收器确认；首次连接可能出现系统配对提示")
        submit(enabled: false, modifiers: 0, keys: [])
    }
    func submit(enabled: Bool, modifiers: UInt8, keys: [UInt8]) {
        guard ready else { return }
        guard outbox.enqueue(enabled: enabled, modifiers: modifiers, keys: keys) else { fail("按键发送积压，已停止转发"); return }
        pump()
    }
    private func pump() {
        guard ready, let p = peripheral, let input else { return }
        if let frame = outbox.next(now: ProcessInfo.processInfo.systemUptime) { p.writeValue(frame.data, for: input, type: .withResponse) }
    }
    func tick() {
        guard ready else { return }
        if confirmed && outbox.timedOut(now: ProcessInfo.processInfo.systemUptime) { fail("蓝牙接收器响应超时，已返回 Mac") }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === p, characteristic === input, ready else { return }
        guard error == nil else { fail("蓝牙写入失败，请检查接收器配对"); return }
        outbox.markWritten(); pump()
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === p, characteristic === ack, ready else { return }
        guard error == nil, let data = characteristic.value, let frame = BLEFrame(data: data), outbox.acknowledge(frame) else { return }
        setupTimeout?.cancel()
        if !confirmed { confirmed = true; onReady?(true) }
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
        onAck?(); pump()
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard peripheral === p else { return }; resetLink(); scheduleRetry()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard peripheral === p else { return }; resetLink(); scheduleRetry()
    }
    private func resetLink() {
        setupTimeout?.cancel(); peripheral = nil; input = nil; ack = nil; ready = false; confirmed = false
        onReady?(false)
    }
    private func fail(_ message: String) {
        let old = peripheral; resetLink()
        if let old { central?.cancelPeripheralConnection(old) }
        onStatus?(message)
        scheduleRetry()
    }
    private func scheduleRetry() {
        guard active, wanted != nil else { return }
        onStatus?("连接中断 · 已返回 Mac，3 秒后尝试重连")
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resume() }
        retry = work; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
