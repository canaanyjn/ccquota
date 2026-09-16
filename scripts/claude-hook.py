#!/usr/bin/python3
import json, pathlib, subprocess, sys, time, os
state = pathlib.Path.home() / 'Library/Application Support/UsageBar'
raw = sys.stdin.read()
try:
    data = json.loads(raw)
    limits = data.get('rate_limits') or {}
    windows = []
    for key, label in [('five_hour','5 小时'), ('seven_day','7 天')]:
        w = limits.get(key)
        if isinstance(w, dict) and isinstance(w.get('used_percentage'), (float,int)):
            windows.append({'label':label,'used':max(0,min(100,w['used_percentage'])),'reset':w.get('resets_at'),'windowMinutes':300 if key == 'five_hour' else 10080})
    if windows:
        state.mkdir(parents=True,exist_ok=True)
        tmp = state / ('claude.' + str(os.getpid()) + '.tmp')
        tmp.write_text(json.dumps({'name':'Claude','plan':'Claude Code','windows':windows,'updated':time.time(),'message':''}))
        tmp.replace(state / 'claude.json')
        import datetime
        with (state / ('quota-' + datetime.date.today().isoformat() + '.jsonl')).open('a') as f:
            for w in windows:
                f.write(json.dumps({'time':time.time(),'provider':'Claude',**w}) + '\n')
except (ValueError,OSError): pass
try:
    old = json.loads((state / 'previous-statusline.json').read_text())
    if old and old.get('type') == 'command':
        subprocess.run(old['command'],shell=True,input=raw,text=True,timeout=5)
    else: print('UsageBar · 额度已同步',end='')
except (OSError,ValueError,subprocess.TimeoutExpired): pass
