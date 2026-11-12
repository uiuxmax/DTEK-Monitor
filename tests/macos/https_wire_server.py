"""Owned IPv4 loopback/TLS acceptance measurements; never changes a trust store."""
import base64
import gzip
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time


def main():
    if sys.platform != 'darwin' or len(sys.argv) != 3:
        raise SystemExit(64)
    probe = Path(sys.argv[1]).resolve(strict=True)
    profile = Path(sys.argv[2]).resolve(strict=True)
    assert str(profile) == os.environ['DTEKMONITOR_TEST_PROFILE']
    assert profile.name == 'profile' and str(profile.parent) == os.environ['DTEKMONITOR_TEST_ROOT']
    assert os.environ['DTEKMONITOR_DISABLE_PROVIDER'] == os.environ['DTEKMONITOR_AUTOSTART_TEST_MODE'] == '1'
    assert not any(profile.iterdir()), 'New empty owned profile required'
    config = profile / 'certificate.conf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
                      '[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\n'
                      'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n'
                      'extendedKeyUsage=serverAuth\n', encoding='ascii')
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                    '-config', str(config), '-keyout', str(profile/'key.pem'), '-out', str(profile/'root.pem')],
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    os.chmod(profile/'key.pem', 0o600)
    subprocess.run(['/usr/bin/openssl', 'x509', '-in', str(profile/'root.pem'), '-outform', 'der',
                    '-out', str(profile/'root.der')], check=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(['http/1.1'])
    context.load_cert_chain(str(profile/'root.pem'), str(profile/'key.pem'))
    body = b'{"synthetic":true}'

    def response(fields='', payload=body, framing=None, status='200 OK'):
        headers = 'HTTP/1.1 ' + status + '\r\nContent-Type: application/json\r\nConnection: close\r\n'
        headers += ('Content-Length: ' + str(len(payload)) + '\r\n') if framing is None else framing
        return (headers + fields + '\r\n').encode('ascii') + payload

    cases = [
        ('trusted', response(), 'trusted', 'none', 2000),
        ('untrusted', response(), 'untrusted', 'tls', 2000),
        ('hostname', response(), 'mismatch', 'tls', 2000),
        ('redirect', response('Location: /second\r\n', b'', status='302 Found'), 'trusted', 'http', 2000),
        ('auth', response('WWW-Authenticate: Basic realm="synthetic"\r\n', b'', status='401 Unauthorized'), 'trusted', 'http', 2000),
        ('forbidden', response(status='403 Forbidden'), 'trusted', 'http', 2000),
        ('rate-limit', response(status='429 Too Many Requests'), 'trusted', 'http', 2000),
        ('mime', response().replace(b'application/json', b'text/html'), 'trusted', 'invalid_response', 2000),
        ('encoding', response('Content-Encoding: gzip\r\n', gzip.compress(body)), 'trusted', 'invalid_response', 2000),
        ('oversized-length', response(payload=b'', framing='Content-Length: 2000001\r\n'), 'trusted', 'body_too_large', 2000),
        ('stream-overflow', response(payload=b'1e8481\r\n'+b'x'*2_000_001+b'\r\n0\r\n\r\n', framing='Transfer-Encoding: chunked\r\n'), 'trusted', 'body_too_large', 4000),
        ('truncated', response(payload=b'{}', framing='Content-Length: 20\r\n'), 'trusted', 'failure', 2000),
        ('unknown-length', response(framing=''), 'trusted', 'none', 2000),
        ('chunked', response(payload=f'{len(body):x}\r\n'.encode()+body+b'\r\n0\r\n\r\n', framing='Transfer-Encoding: chunked\r\n'), 'trusted', 'none', 2000),
        ('duplicate-field', response('X-Synthetic: first\r\nX-Synthetic: second\r\n'), 'trusted', 'measure', 2000),
        ('duplicate-type', response('Content-Type: application/json\r\n'), 'trusted', 'measure', 2000),
        ('huge-header', response('X-Synthetic: ' + 'h'*70_000 + '\r\n'), 'trusted', 'measure', 2000),
        ('conflicting-framing', response(framing='Content-Length: 17\r\nTransfer-Encoding: chunked\r\n'), 'trusted', 'failure', 2000),
        ('deadline', None, 'trusted', 'timeout', 250),
        ('cancel', None, 'cancel', 'cancelled', 2000),
        ('pre-certificate-close', b'', 'raw-close', 'failure', 1000),
    ]
    results = []
    for name, wire, mode, expected, budget in cases:
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0)); listener.listen(8); listener.settimeout(0.05)
        port = listener.getsockname()[1]
        stopping = threading.Event()
        stats = {'connections': 0, 'requests': [], 'tlsErrors': 0}
        children = []

        def serve(connection):
            connection.settimeout(3)
            try:
                if mode == 'raw-close':
                    connection.recv(4096)
                    return
                with context.wrap_socket(connection, server_side=True) as secure:
                    request = b''
                    while b'\r\n\r\n' not in request and len(request) <= 16_384:
                        data = secure.recv(4096)
                        if not data:
                            return
                        request += data
                    stats['requests'].append(request.decode('ascii'))
                    if wire is not None:
                        secure.sendall(wire)
                        # Explicit TLS close_notify makes close-delimited EOF well framed.
                        secure.settimeout(0.5)
                        try:
                            secure.unwrap()
                        except (ssl.SSLError, OSError):
                            pass
                    else:
                        while not stopping.is_set():
                            try:
                                if not secure.recv(4096):
                                    break
                            except socket.timeout:
                                continue
            except (ssl.SSLError, OSError):
                stats['tlsErrors'] += 1
            finally:
                connection.close()

        def accept():
            while not stopping.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                stats['connections'] += 1
                child = threading.Thread(target=serve, args=(connection,))
                children.append(child); child.start()

        thread = threading.Thread(target=accept); thread.start()
        destination = profile/(name+'.json')
        try:
            run = subprocess.run([str(probe), str(port), 'trusted' if mode == 'raw-close' else mode,
                                  str(budget), str(destination)], capture_output=True, text=True, timeout=38)
            assert run.returncode == 0, (name, run.returncode, run.stderr)
            result = json.loads(destination.read_bytes())
        finally:
            stopping.set(); listener.close(); thread.join(5)
            for child in children:
                child.join(5)
            assert not thread.is_alive() and not any(child.is_alive() for child in children)
        assert result['deliveries'] == 1 and result['token'] == 1
        assert result['address'] == 'synthetic-address' and not result['proxy']
        if expected == 'failure':
            assert result['error'] != 'none', (name, result)
        elif expected != 'measure':
            assert result['error'] == expected, (name, result)
        if result['error'] != 'none':
            assert result['bodyBytes'] == 0 and result['received'] is False
        else:
            assert base64.b64decode(result['bodyBase64']) == body and result['received'] is True
        for request in stats['requests']:
            lowered = request.lower()
            assert request.startswith('GET /probe HTTP/1.1\r\n'), request
            assert 'accept-encoding: identity\r\n' in lowered
            assert 'cookie:' not in lowered and 'authorization:' not in lowered
            assert 'if-none-match:' not in lowered and 'if-modified-since:' not in lowered
        if name in ('deadline', 'cancel'):
            assert result['elapsedMs'] < 3000, (name, result)
        result.pop('bodyBase64')
        result['headers'] = {key: value if len(value) < 300 else f'<{len(value)} characters>'
                             for key, value in result['headers'].items()}
        results.append(dict(case=name, expected=expected, **result, **stats))
        print(json.dumps(results[-1], ensure_ascii=False), flush=True)
    # Readiness is deliberately independent of whether the measurements executed correctly.
    report = dict(result='PASS', readiness='PARTIAL', cases=results,
                  open=['URLSession raw header allocation cap is not exposed',
                        'Raw duplicate-header multiplicity is not available in allHeaderFields',
                        'Review observed native retries/normalization before production integration',
                        'DNS, expired certificate, session generations and four-resource orchestration remain open'],
                  scope='Owned loopback TLS only; no provider request or trust-store mutation')
    (profile.parent/'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()
