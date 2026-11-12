"""Owned loopback TLS: connect the real worker/transport/receipt/actor."""
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo


def main():
    if sys.platform != 'darwin' or len(sys.argv) != 3: raise SystemExit(64)
    probe, profile = (Path(value).resolve(strict=True) for value in sys.argv[1:])
    assert str(profile) == os.environ['DTEKMONITOR_TEST_PROFILE']
    assert profile.name == 'profile' and str(profile.parent) == os.environ['DTEKMONITOR_TEST_ROOT']
    assert os.environ['DTEKMONITOR_DISABLE_PROVIDER'] == os.environ['DTEKMONITOR_AUTOSTART_TEST_MODE'] == '1'
    assert not any(profile.iterdir())
    config=profile/'certificate.conf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
        '[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\n'
        'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\n',encoding='ascii')
    subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
        '-config',str(config),'-keyout',str(profile/'key.pem'),'-out',str(profile/'root.pem')],
        check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    os.chmod(profile/'key.pem',0o600)
    subprocess.run(['/usr/bin/openssl','x509','-in',str(profile/'root.pem'),'-outform','der','-out',str(profile/'root.der')],check=True)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version=ssl.TLSVersion.TLSv1_2; context.set_alpn_protocols(['http/1.1'])
    context.load_cert_chain(str(profile/'root.pem'),str(profile/'key.pem'))
    listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(8); listener.settimeout(0.2)
    port=listener.getsockname()[1]; requests=[]; errors=[]; stop=threading.Event()
    def serve():
        while not stop.is_set():
            try: connection,_=listener.accept()
            except socket.timeout: continue
            except OSError: break
            try:
                connection.settimeout(3)
                with context.wrap_socket(connection,server_side=True) as tls:
                    raw=b''
                    while b'\r\n\r\n' not in raw:
                        part=tls.recv(min(4096,8192-len(raw)))
                        if not part: raise ValueError('Incomplete request')
                        raw+=part
                        if len(raw)>=8192: raise ValueError('Request cap')
                    method,path,version=raw.split(b'\r\n',1)[0].decode('ascii').split(' ')
                    assert (method,version)==('GET','HTTP/1.1')
                    url=urlsplit(path); query=parse_qs(url.query); requests.append(path)
                    assert len(requests)<=5
                    if url.path.endswith('/streets'):
                        assert query['regionId']==['25'] and query['dsoId']==['902']
                        body=[{'id':101,'value':'вул. Тестова'}]
                    elif url.path.endswith('/houses'):
                        assert query['streetId']==['101'] and query['query']==['2-А']
                        body=[{'id':201,'value':'2-А'}]
                    elif url.path.endswith('/group'):
                        assert query['streetId']==['101'] and query['houseId']==['201']
                        body={'group':2,'subgroup':1}
                    else:
                        assert url.path=='/api/blackout-service/public/shutdowns/regions/25/dsos/902/planned-outages'
                        now=datetime.now(ZoneInfo('Europe/Kyiv')).replace(microsecond=0)
                        today=now.replace(hour=0,minute=0,second=0)
                        slots=[{'start':0,'end':510,'type':'NotPlanned'},
                            {'start':510,'end':720,'type':'Definite'},{'start':720,'end':1440,'type':'NotPlanned'}]
                        body={'2.1':{'updatedOn':(now-timedelta(minutes=5)).isoformat(),
                            'today':{'date':today.isoformat(),'status':'ScheduleApplies','slots':slots},
                            'tomorrow':{'date':(today+timedelta(days=1)).isoformat(),'status':'ScheduleApplies','slots':slots}}}
                    payload=json.dumps(body,ensure_ascii=False).encode('utf-8')
                    tls.sendall(('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: '
                        +str(len(payload))+'\r\n\r\n').encode('ascii')+payload)
                    # The raw transport requires an explicit TLS close_notify/EOF.
                    tls.settimeout(0.5)
                    try: tls.unwrap()
                    except (ssl.SSLError,OSError): pass
            except Exception as error: errors.append(str(error)); connection.close()
    thread=threading.Thread(target=serve,daemon=True); thread.start()
    try:
        result=subprocess.run([str(probe),'--session-probe',str(port),str(profile/'root.der')],
            capture_output=True,text=True,encoding='utf-8',timeout=60)
    finally: stop.set(); listener.close(); thread.join(timeout=4)
    (profile.parent/'session.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    report=dict(result='PASS' if result.returncode==0 and len(requests)==5 and not errors else 'FAIL',
        checks=16,accepted_connections=len(requests),resources=requests,server_errors=errors,
        scope='Real TLS loopback, synthetic provider JSON, no public provider, no Login Items')
    (profile.parent/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(result.stdout)
    assert result.returncode==0 and 'RESULT 16/16 connected session checks passed' in result.stdout,result.stderr
    assert len(requests)==5 and not errors,report
    print('PASS: exactly four lookup GETs and one suggestion GET on owned TLS loopback')


if __name__=='__main__': main()
