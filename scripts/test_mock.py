#!/usr/bin/env python3
import base64, hashlib, hmac, json, socket, subprocess, sys, time
key = b'local-test-secret-123'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
p = subprocess.Popen([sys.executable, 'scripts/mock_receiver.py', '--port', str(port)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    p.stdin.write(key.decode() + '\n'); p.stdin.flush()
    assert 'Listening' in p.stdout.readline()
    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(.15)
    def packet(seq, secret=key):
        payload = json.dumps(dict(version=1,session='test',sequence=seq,enabled=True,modifiers=2,keys=[26])).encode()
        return json.dumps(dict(payload=base64.b64encode(payload).decode(),mac=base64.b64encode(hmac.digest(secret,payload,'sha256')).decode())).encode()
    good = packet(1); c.sendto(good, ('127.0.0.1',port)); assert c.recv(4096) == good
    assert 'HID keys=[26]' in p.stdout.readline()
    for bad in [packet(2,b'wrong'),packet(1)]:
        c.sendto(bad, ('127.0.0.1',port))
        try: c.recv(4096); raise AssertionError('Accepted invalid/replayed packet')
        except socket.timeout: pass
    assert 'WATCHDOG' in p.stdout.readline()
    print('PASS: simulator ACK, wrong-key rejection, replay rejection, watchdog release')
finally:
    p.terminate(); p.communicate(timeout=3)
