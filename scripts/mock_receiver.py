#!/usr/bin/env python3
"""Local-only simulator. Never injects keys. Echoes authenticated states as ACKs."""
import argparse, base64, hashlib, hmac, json, socket, time, getpass
p = argparse.ArgumentParser()
p.add_argument('--port', type=int, default=45832)
a = p.parse_args()
secret = getpass.getpass('Pairing key (same as Mac app, >=16 chars): ').encode()
if len(secret) < 16:
    raise SystemExit('Key must be at least 16 UTF-8 bytes')
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('127.0.0.1', a.port)); sock.settimeout(.1)
last_seen = 0; current = None; session = None; sequence = -1
print(f'Listening on 127.0.0.1:{a.port}. Ctrl+C to stop.', flush=True)
try:
    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            if current is not None and time.monotonic() - last_seen > .3:
                print('WATCHDOG: release all keys', flush=True); current = None
            continue
        try:
            envelope = json.loads(data)
            payload = base64.b64decode(envelope['payload'], validate=True)
            signature = base64.b64decode(envelope['mac'], validate=True)
            if not hmac.compare_digest(signature, hmac.digest(secret, payload, 'sha256')):
                continue
            state = json.loads(payload)
            if state['version'] != 1: continue
            if state['session'] != session:
                if time.monotonic() - last_seen < .3: continue
                session = state['session']; sequence = -1
            if state['sequence'] <= sequence: continue
            sequence = state['sequence']; last_seen = time.monotonic()
            new = (state['enabled'], state['modifiers'], state['keys'])
            if new != current:
                print(f'enabled={new[0]} modifiers={new[1]:02x} HID keys={new[2]}', flush=True)
                current = new
            sock.sendto(data, addr)
        except (ValueError, KeyError, TypeError):
            continue
except KeyboardInterrupt:
    print('\nRelease all keys; stopped.')
