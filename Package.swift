// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "KeyboardBridge", platforms: [.macOS(.v13)], products: [.executable(name: "KeyboardBridge", targets: ["KeyboardBridge"])], targets: [.executableTarget(name: "KeyboardBridge")], swiftLanguageModes: [.v5])
