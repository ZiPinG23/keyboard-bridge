#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/KeyboardBridge/Protocol.swift Tests/KeyboardBridgeTests/ProtocolTests.swift -o .build/protocol-tests
.build/protocol-tests
python3 -m py_compile scripts/mock_receiver.py

python3 scripts/test_mock.py
swiftc Sources/KeyboardBridge/BLEProtocol.swift Tests/KeyboardBridgeTests/BLETests.swift -o .build/ble-tests
.build/ble-tests
