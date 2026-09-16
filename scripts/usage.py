#!/usr/bin/python3
import json, os, pathlib, select, shutil, subprocess, sys, time
HOME = pathlib.Path.home()
STATE = HOME / 'Library/Application Support/UsageBar'

def window(value, label, used='usedPercent', reset='resetsAt'):
    if not isinstance(value, dict) or not isinstance(value.get(used), (int, float)):
        return None
    mins = value.get('windowDurationMins')
    if mins:
        label = f'{mins // 1440} 天' if mins >= 1440 else f'{mins / 60:g} 小时'
    return {'label': label, 'used': max(0, min(100, value[used])), 'reset': value.get(reset), 'windowMinutes': value.get('windowDurationMins')}

def codex():
    paths = [shutil.which('codex'), '/opt/homebrew/bin/codex', '/usr/local/bin/codex']
    paths += [str(p) for p in sorted((HOME / '.nvm/versions/node').glob('*/bin/codex'), reverse=True)]
    exe = next((p for p in paths if p and os.access(p, os.X_OK)), None)
    if not exe:
        raise RuntimeError('未找到 Codex CLI，请先安装并运行 codex login。')
    env = dict(os.environ)
    env['PATH'] = str(pathlib.Path(exe).parent) + ':' + env.get('PATH', '/usr/bin:/bin')
    p = subprocess.Popen([exe, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    buffer = b''
    def send(obj):
        p.stdin.write((json.dumps(obj) + '\n').encode()); p.stdin.flush()
    def receive(target):
        nonlocal buffer
        end = time.monotonic() + 18
        while time.monotonic() < end:
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                try: msg = json.loads(line)
                except ValueError: continue
                if msg.get('id') == target:
                    if 'error' in msg: raise RuntimeError('额度读取失败，请检查 Codex 登录与网络。')
                    return msg.get('result', {})
            ready, _, _ = select.select([p.stdout], [], [], max(0, end-time.monotonic()))
            if ready:
                chunk = os.read(p.stdout.fileno(), 65536)
                if not chunk: break
                buffer += chunk
        raise RuntimeError('Codex 连接超时，请检查网络后刷新。')
    try:
        send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'ccquota','version':'0.1.0'}}})
        receive(1); send({'method':'initialized'})
        send({'id':2,'method':'account/rateLimits/read'})
        r = receive(2)
        buckets = r.get('rateLimitsByLimitId')
        if buckets:
            entries = list(buckets.items())
        else: entries = [('codex', r.get('rateLimits') or {})]
        windows = []
        plan = ''
        for key, bucket in entries:
            if not bucket: continue
            plan = bucket.get('planType') or plan
            for field, label in [('primary','当前周期'),('secondary','每周')]:
                w = window(bucket.get(field), label)
                if w:
                    w['label'] = (bucket.get('limitName') or key) + ' · ' + w['label']
                    windows.append(w)
        return {'name':'Codex','plan':plan,'windows':windows,'updated':time.time(),'message':'' if windows else '此账户未提供订阅额度。'}
    finally:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill(); p.wait()

def claude():
    try:
        raw = json.loads((STATE / 'claude.json').read_text())
        return raw
    except (OSError, ValueError):
        return {'name':'Claude','plan':'Claude Code','windows':[],'message':'连接状态栏后，在 Claude Code 对话中自动更新。'}

if __name__ == '__main__':
    if '--claude' in sys.argv: print(json.dumps(claude())); sys.exit()
    try: result = codex()
    except Exception as e: result = {'name':'Codex','plan':'','windows':[],'message':str(e)}
    if result.get('windows'):
        try:
            STATE.mkdir(parents=True,exist_ok=True)
            import datetime
            with (STATE / ('quota-' + datetime.date.today().isoformat() + '.jsonl')).open('a') as f:
                for w in result['windows']:
                    f.write(json.dumps({'time':result['updated'],'provider':'Codex',**w}) + '\n')
        except OSError: pass
    print(json.dumps(result))
