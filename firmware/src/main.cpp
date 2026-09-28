#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <USB.h>
#include <USBHID.h>
#include <atomic>
#include "frame.h"

static const char* SERVICE = "77E10001-4B42-4D41-8B52-494447453031";
static const char* INPUT_UUID = "77E10002-4B42-4D41-8B52-494447453031";
static const char* ACK = "77E10003-4B42-4D41-8B52-494447453031";
static constexpr uint16_t NONE = 0xffff;
USBHID hid;
class KeyboardDescriptor : public USBHIDDevice {
public:
    KeyboardDescriptor() { USBHID::addDevice(this, sizeof(descriptor)); }
    uint16_t _onGetDescriptor(uint8_t* out) override { memcpy(out, descriptor, sizeof(descriptor)); return sizeof(descriptor); }
private:
    static constexpr uint8_t descriptor[] = { TUD_HID_REPORT_DESC_KEYBOARD(HID_REPORT_ID(1)) };
} keyboard;
constexpr uint8_t KeyboardDescriptor::descriptor[];
NimBLEServer* server;
NimBLECharacteristic* ack;
Preferences prefs;
std::string owner;
std::atomic<bool> ownerSet{false};
uint32_t passkey;
std::atomic<uint16_t> connection{NONE};
std::atomic<bool> secured{false}, mustRelease{true};
std::atomic<uint32_t> pairUntil{0}, connectedAt{0};
struct Packet { uint16_t handle; uint8_t bytes[20]; };
QueueHandle_t packets;
uint32_t session = 0, sequence = 0, lastInput = 0;
bool hasSession = false;
bool pendingRelease = true;

bool pairOpen() { return pairUntil.load() != 0 && int32_t(pairUntil.load() - millis()) > 0; }
bool report(const uint8_t* p) {
    uint8_t keys[8] = {};
    if (p && p[10]) { keys[0] = p[11]; memcpy(keys+2, p+12, 6); }
    return hid.ready() && hid.SendReport(1, keys, sizeof(keys), 20);
}
void drop(uint16_t handle) { secured = false; mustRelease = true; if (handle != NONE) server->disconnect(handle); }

class ServerEvents : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
        if (connection.load() != NONE || (owner.empty() && !pairOpen())) { s->disconnect(info.getConnHandle()); return; }
        connection = info.getConnHandle(); connectedAt = millis(); secured = false; mustRelease = true;
        s->updateConnParams(info.getConnHandle(), 12, 24, 0, 100);
        Serial.println("BLE connected; waiting for authenticated encryption");
    }
    void onDisconnect(NimBLEServer*, NimBLEConnInfo& info, int) override {
        if (connection.load() == info.getConnHandle()) { connection = NONE; secured = false; mustRelease = true; }
        NimBLEDevice::startAdvertising();
        Serial.println("BLE disconnected; releasing keys");
    }
    uint32_t onPassKeyDisplay() override { Serial.printf("PAIRING CODE: %06lu\n", (unsigned long)passkey); return passkey; }
    void onAuthenticationComplete(NimBLEConnInfo& info) override {
        const auto identity = info.getIdAddress().toString();
        if (connection.load() != info.getConnHandle() || !info.isEncrypted() || !info.isAuthenticated() || !info.isBonded() ||
            (!owner.empty() && owner != identity) || (owner.empty() && !pairOpen())) {
            server->disconnect(info.getConnHandle()); return;
        }
        if (owner.empty()) { owner = identity; ownerSet = true; prefs.putString("owner", owner.c_str()); pairUntil = 0; }
        secured = true;
        Serial.println("BLE authenticated and bonded");
    }
} serverEvents;
class InputEvents : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo& info) override {
        if (!secured.load() || connection.load() != info.getConnHandle() || !info.isEncrypted() || !info.isAuthenticated()) return;
        auto value = chr->getValue();
        if (value.size() != 20) { drop(info.getConnHandle()); return; }
        Packet p{}; p.handle = info.getConnHandle(); memcpy(p.bytes, value.data(), 20);
        if (xQueueSend(packets, &p, 0) != pdTRUE) drop(p.handle);
    }
} inputEvents;
void setup() {
    Serial.begin(115200); pinMode(0, INPUT_PULLUP);
    prefs.begin("keyboardbridge", false);
    owner = prefs.getString("owner", "").c_str();
    ownerSet = !owner.empty();
    passkey = prefs.getUInt("passkey", 0);
    if (!passkey) { passkey = 100000 + esp_random()%900000; prefs.putUInt("passkey", passkey); }
    packets = xQueueCreate(8, sizeof(Packet));
    USB.productName("Keyboard Bridge Receiver");
    USB.manufacturerName("Keyboard Bridge");
    hid.begin(); USB.begin();
    NimBLEDevice::init("KeyboardBridge-S3");
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
    NimBLEDevice::setSecurityAuth(true, true, true);
    NimBLEDevice::setSecurityPasskey(passkey);
    server = NimBLEDevice::createServer(); server->setCallbacks(&serverEvents);
    auto service = server->createService(SERVICE);
    auto input = service->createCharacteristic(INPUT_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN, 20);
    input->setCallbacks(&inputEvents);
    ack = service->createCharacteristic(ACK, NIMBLE_PROPERTY::NOTIFY, 20);
    service->start();
    auto adv = NimBLEDevice::getAdvertising(); adv->setName("KeyboardBridge-S3"); adv->addServiceUUID(SERVICE); adv->enableScanResponse(true); adv->start();
    Serial.println("Keyboard Bridge BLE v1 ready. Native USB port provides HID.");
    Serial.println("Tap BOOT to open pairing for 120s; hold BOOT 5s to erase binding.");
    Serial.printf("Bond owner present: %s\n", owner.empty() ? "no" : "yes");
}
void loop() {
    // Local USB serial provisioning, equivalent to pressing BOOT.
    if (Serial.available() && Serial.read() == 'p' && !ownerSet.load()) {
        pairUntil = millis() + 120000;
        Serial.printf("Pairing open 120s. PAIRING CODE: %06lu\n", (unsigned long)passkey);
    }
    static uint32_t pressed = 0;
    if (!digitalRead(0)) {
        if (!pressed) pressed = millis();
        if (millis() - pressed > 5000) {
            drop(connection.load()); report(nullptr);
            NimBLEDevice::deleteAllBonds(); prefs.clear(); Serial.println("Binding erased; restarting"); delay(100); ESP.restart();
        }
    } else if (pressed) {
        if (millis() - pressed >= 30 && !ownerSet.load()) {
            pairUntil = millis() + 120000;
            Serial.printf("Pairing open 120s. PAIRING CODE: %06lu\n", (unsigned long)passkey);
        }
        pressed = 0;
    }
    if (mustRelease.exchange(false)) {
        pendingRelease = true; hasSession = false; session = sequence = 0; xQueueReset(packets);
    }
    if (pendingRelease && report(nullptr)) pendingRelease = false;
    if (hasSession && millis() - lastInput > 300) { drop(connection.load()); hasSession = false; pendingRelease = true; }
    if (connection.load() != NONE && !hasSession && millis() - connectedAt.load() > 30000) drop(connection.load());
    Packet packet;
    if (xQueueReceive(packets, &packet, 0) == pdTRUE && secured.load() && connection.load() == packet.handle) {
        auto p = packet.bytes;
        const uint32_t sid = bridge::read32(p+2), seq = bridge::read32(p+6);
        bool valid = bridge::validFrame(p, 20, hasSession, session, sequence);
        if (!valid) { drop(packet.handle); }
        else {
            bool applied = report(p);
            // Disabled handshake can succeed before native USB is plugged in.
            if (!p[10] && !applied) pendingRelease = true;
            if (p[10] && !applied) drop(packet.handle);
            else if (secured.load() && connection.load() == packet.handle) {
                hasSession = true; session = sid; sequence = seq; lastInput = millis();
                p[1] = 2; ack->setValue(p, 20); ack->notify(packet.handle);
            }
        }
    }
    delay(1);
}
