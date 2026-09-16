#!/usr/bin/python3
import json, pathlib, shutil, shlex, time
home = pathlib.Path.home()
state = home / 'Library/Application Support/UsageBar'
settings = home / '.claude/settings.json'
try:
    state.mkdir(parents=True,exist_ok=True)
    data = json.loads(settings.read_text()) if settings.exists() else {}
    old = data.get('statusLine')
    command = '/usr/bin/python3 ' + shlex.quote(str(state / 'claude-hook.py'))
    if old != {'type':'command','command':command}:
        if old and old.get('type') != 'command': raise ValueError('当前状态栏格式无法安全合并，请手动配置。')
        if settings.exists(): shutil.copy2(settings, state / ('settings-backup-' + str(time.time_ns()) + '.json'))
        (state / 'previous-statusline.json').write_text(json.dumps(old))
        shutil.copy2(pathlib.Path(__file__).with_name('claude-hook.py'), state / 'claude-hook.py')
        data['statusLine'] = {'type':'command','command':command}
        settings.parent.mkdir(parents=True,exist_ok=True)
        temp = settings.with_suffix('.ccquota.tmp')
        temp.write_text(json.dumps(data,indent=2,ensure_ascii=False)); temp.replace(settings)
    shutil.copy2(pathlib.Path(__file__).with_name('claude-hook.py'), state / 'claude-hook.py')
    print('已连接。请重启 Claude Code，发送消息后同步额度。')
except Exception as e: print('连接失败：' + str(e))
