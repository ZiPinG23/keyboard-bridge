import AppKit
import CoreGraphics
import Network

final class Bridge: NSObject, NSApplicationDelegate {
    let mode = NSPopUpButton()
    let devicePicker = NSPopUpButton()
    let networkFields = NSStackView()
    let bluetoothFields = NSStackView()
    let bluetooth = BluetoothTransport()
    var deviceIDs: [UUID] = []
    var usesBluetooth: Bool { mode.indexOfSelectedItem == 0 }
    var item: NSStatusItem!
    var window: NSWindow!
    let host = NSTextField(string: UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1")
    let port = NSTextField(string: UserDefaults.standard.string(forKey: "port") ?? "45832")
    let secret = NSSecureTextField(string: "")
    let status = NSTextField(labelWithString: "未转发 · 键盘控制 Mac")
    var connection: NWConnection?
    var tap: CFMachPort?
    var timer: Timer?
    var enabled = false
    var ready = false
    var keys = Set<UInt8>()
    var modifiers: UInt8 = 0
    var sequence: UInt64 = 0
    var session = UUID().uuidString
    var lastAck = Date.distantPast
    var lastSent: UInt64 = 0
    var hotkeyHeld = false
    var activeSecret = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌨ Mac"
        let menu = NSMenu()
        menu.addItem(withTitle: "设置与连接…", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "切换目标 ⌃⌥⌘K", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for child in menu.items { child.target = self }
        item.menu = menu
        makeWindow()
        bluetooth.onStatus = { [weak self] text in
            guard let self, self.usesBluetooth else { return }; self.status.stringValue = text
        }
        bluetooth.onDevices = { [weak self] devices in
            guard let self else { return }
            let selected = self.devicePicker.indexOfSelectedItem
            let oldID = self.deviceIDs.indices.contains(selected) ? self.deviceIDs[selected] : nil
            self.deviceIDs = devices.map(\.id)
            self.devicePicker.removeAllItems()
            for device in devices { self.devicePicker.addItem(withTitle: "\(device.name) · \(device.id.uuidString.prefix(8))") }
            if let oldID, let index = self.deviceIDs.firstIndex(of: oldID) { self.devicePicker.selectItem(at: index) }
        }
        bluetooth.onReady = { [weak self] value in
            guard let self, self.usesBluetooth else { return }
            self.ready = value
            if !value { self.lastAck = .distantPast; self.stop() }
        }
        bluetooth.onAck = { [weak self] in
            guard let self, self.usesBluetooth else { return }
            self.lastAck = Date()
            if !self.enabled { self.status.stringValue = "蓝牙接收器已响应 · 按 ⌃⌥⌘K 切到 Windows" }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        show()
        if usesBluetooth && UserDefaults.standard.string(forKey: "bluetoothReceiverID") != nil { bluetooth.reconnectSaved() }
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "键盘桥 · Keyboard Bridge"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        mode.addItems(withTitles: ["蓝牙直连（无需 Wi-Fi）", "局域网 UDP"])
        mode.selectItem(at: UserDefaults.standard.integer(forKey: "transportMode"))
        mode.target = self; mode.action = #selector(changeMode)
        stack.addArrangedSubview(mode)
        networkFields.orientation = .vertical; networkFields.alignment = .leading; networkFields.spacing = 8
        bluetoothFields.orientation = .vertical; bluetoothFields.alignment = .leading; bluetoothFields.spacing = 8
        bluetoothFields.addArrangedSubview(NSTextField(labelWithString: "附近的键盘桥接收器"))
        bluetoothFields.addArrangedSubview(devicePicker)
        devicePicker.widthAnchor.constraint(equalToConstant: 450).isActive = true
        let discovery = NSStackView()
        discovery.addArrangedSubview(NSButton(title: "扫描", target: self, action: #selector(scanBluetooth)))
        discovery.addArrangedSubview(NSButton(title: "重连已记住的设备", target: self, action: #selector(reconnectBluetooth)))
        discovery.addArrangedSubview(NSButton(title: "忘记设备", target: self, action: #selector(forgetBluetooth)))
        bluetoothFields.addArrangedSubview(discovery)
        stack.addArrangedSubview(bluetoothFields)
        stack.addArrangedSubview(networkFields)
        for (label, field) in [("接收器地址", host), ("UDP 端口", port), ("配对密钥（至少 16 个字符）", secret)] {
            networkFields.addArrangedSubview(NSTextField(labelWithString: label)); networkFields.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 450).isActive = true
        }
        let buttons = NSStackView()
        buttons.addArrangedSubview(NSButton(title: "连接 / 重新连接", target: self, action: #selector(connect)))
        buttons.addArrangedSubview(NSButton(title: "断开", target: self, action: #selector(disconnectAll)))
        buttons.addArrangedSubview(NSButton(title: "切换 ⌃⌥⌘K", target: self, action: #selector(toggle)))
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(status)
        let hint = NSTextField(wrappingLabelWithString: "首次切换需授权辅助功能。Ctrl + Option + Command + K 返回 Mac。\n蓝牙模式无需地址或 Wi-Fi，首次需系统蓝牙授权和接收器配对。\n需要配套固件；板子未到货时可用局域网模式的本机模拟器。")
        hint.font = .systemFont(ofSize: 11); stack.addArrangedSubview(hint)
        networkFields.isHidden = usesBluetooth; bluetoothFields.isHidden = !usesBluetooth
        window.center()
    }
    @objc func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func disconnectAll() {
        stop()
        let old = connection; connection = nil; old?.cancel()
        bluetooth.disconnect(); ready = false; lastAck = .distantPast
        status.stringValue = "已断开 · 键盘控制 Mac"
    }
    @objc func changeMode() {
        // Release both transports explicitly: the popup already contains the new selection.
        bluetooth.submit(enabled: false, modifiers: 0, keys: [])
        if let connection, !activeSecret.isEmpty {
            sequence += 1
            let state = KeyboardState(version: 1, session: session, sequence: sequence, enabled: false, modifiers: 0, keys: [])
            if let data = try? encodeState(state, secret: activeSecret) { connection.send(content: data, completion: .contentProcessed({ _ in })) }
        }
        disconnectAll()
        networkFields.isHidden = usesBluetooth; bluetoothFields.isHidden = !usesBluetooth
        UserDefaults.standard.set(mode.indexOfSelectedItem, forKey: "transportMode")
    }
    @objc func scanBluetooth() { disconnectAll(); bluetooth.scan() }
    @objc func reconnectBluetooth() { disconnectAll(); bluetooth.reconnectSaved() }
    @objc func forgetBluetooth() { stop(); bluetooth.forget() }
    @objc func connect() {
        if usesBluetooth {
            guard deviceIDs.indices.contains(devicePicker.indexOfSelectedItem) else { status.stringValue = "请先扫描并选择接收器，或重连已记住的设备"; return }
            let id = deviceIDs[devicePicker.indexOfSelectedItem]
            disconnectAll(); bluetooth.connect(id: id); return
        }
        stop()
        guard let n = UInt16(port.stringValue), n > 0, !host.stringValue.isEmpty, secret.stringValue.utf8.count >= 16 else { status.stringValue = "请输入地址、有效端口及至少 16 字符的密钥"; return }
        connection?.cancel(); ready = false
        activeSecret = secret.stringValue
        UserDefaults.standard.set(host.stringValue, forKey: "host"); UserDefaults.standard.set(port.stringValue, forKey: "port")
        session = UUID().uuidString; sequence = 0; lastSent = 0; lastAck = .distantPast
        let c = NWConnection(host: NWEndpoint.Host(host.stringValue), port: NWEndpoint.Port(rawValue: n)!, using: .udp)
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            DispatchQueue.main.async {
                guard let self, let c, self.connection === c else { return }
                switch state {
                case .ready: self.ready = true; self.status.stringValue = "等待接收器认证响应…"; self.receive(c)
                case .failed, .cancelled: self.ready = false; self.stop(); self.status.stringValue = "连接不可用 · 已返回 Mac"
                default: break
                }
            }
        }
        c.start(queue: .main)
    }
    func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            guard let self, let c, self.connection === c else { return }
            if let data, let ack = try? JSONDecoder().decode(Envelope.self, from: data), let payload = Data(base64Encoded: ack.payload), let signature = Data(base64Encoded: ack.mac) {
                if self.validMAC(payload, signature), let state = try? JSONDecoder().decode(KeyboardState.self, from: payload), state.version == 1, state.session == self.session, state.sequence > self.lastSent, state.sequence <= self.sequence {
                    self.lastSent = state.sequence; self.lastAck = Date()
                    if !self.enabled { self.status.stringValue = "接收器已响应 · 按 ⌃⌥⌘K 切到 Windows" }
                }
            }
            if error == nil { self.receive(c) }
        }
    }
    func installTap() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { status.stringValue = "请在系统设置 → 隐私与安全性 → 辅助功能中授权，然后重试"; return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ptr in
            let bridge = Unmanaged<Bridge>.fromOpaque(ptr!).takeUnretainedValue()
            return bridge.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { status.stringValue = "无法捕获键盘，请检查辅助功能权限并重新启动"; return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    @objc func toggle() {
        if enabled { stop(); return }
        guard ready, Date().timeIntervalSince(lastAck) < 0.5 else { status.stringValue = "接收器未响应，请先连接并完成配对"; show(); return }
        guard installTap() else { show(); return }
        enabled = true; keys.removeAll(); modifiers = 0
        item.button?.title = "⌨ Windows"; status.stringValue = "正在控制 Windows · ⌃⌥⌘K 返回 Mac"; send()
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { stop(); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let combo: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if code == 40, type == .keyUp, hotkeyHeld { hotkeyHeld = false; return nil }
        if code == 40, type == .keyDown, event.flags.intersection(combo) == combo {
            if !hotkeyHeld { hotkeyHeld = true; toggle() }; return nil
        }
        guard enabled else { return Unmanaged.passUnretained(event) }
        // Aggregate modifiers intentionally map either side to left modifiers in v1.
        modifiers = 0
        for (flag, bit): (CGEventFlags, UInt8) in [(.maskControl,1),(.maskShift,2),(.maskAlternate,4),(.maskCommand,8)] { if event.flags.contains(flag) { modifiers |= bit } }
        if let usage = hidKeys[code] {
            if type == .keyDown { keys.insert(usage) }
            if type == .keyUp { keys.remove(usage) }
            if code == 57, type == .flagsChanged { keys.insert(57); send(); keys.remove(57) }
        }
        send()
        return nil
    }
    func tick() {
        if usesBluetooth { bluetooth.tick() }
        if enabled && Date().timeIntervalSince(lastAck) > 0.5 { stop(); status.stringValue = "接收器响应超时 · 已返回 Mac" }
        if ready { send() }
    }
    func send() {
        guard ready else { return }
        if usesBluetooth { bluetooth.submit(enabled: enabled, modifiers: modifiers, keys: keys.sorted()); return }
        sequence += 1
        let state = KeyboardState(version: 1, session: session, sequence: sequence, enabled: enabled, modifiers: enabled ? modifiers : 0, keys: enabled ? keys.sorted() : [])
        if let data = try? encodeState(state, secret: activeSecret) { connection?.send(content: data, completion: .contentProcessed({ _ in })) }
    }
    func stop() { enabled = false; keys.removeAll(); modifiers = 0; item?.button?.title = "⌨ Mac"; status.stringValue = "未转发 · 键盘控制 Mac"; send() }
    @objc func suspend() { stop() }
    @objc func quit() { stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) } }
    func applicationWillTerminate(_ notification: Notification) { stop() }
}
import CryptoKit
extension Bridge {
    func validMAC(_ payload: Data, _ signature: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: SymmetricKey(data: Data(activeSecret.utf8)))
    }
}
let app = NSApplication.shared
let delegate = Bridge()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
