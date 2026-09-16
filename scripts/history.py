#!/usr/bin/python3
"""Read local usage metadata only. Never exports prompts or assistant text."""
import datetime as dt
import json
import pathlib
import time
import re
import os
import math
import argparse

def stamp(value):
    try: return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (AttributeError, ValueError): return None

def tokens(u, provider):
    def n(k): return max(0, int(u.get(k) or 0))
    if provider == 'Codex':
        cached = n('cached_input_tokens')
        return {'input': max(0, n('input_tokens') - cached), 'cached': cached, 'output': n('output_tokens')}
    return {'input': n('input_tokens') + n('cache_creation_input_tokens'), 'cached': n('cache_read_input_tokens'), 'output': n('output_tokens')}

def read_file(path):
    try:
        with path.open() as f:
            for i, line in enumerate(f):
                try: yield i, json.loads(line)
                except (ValueError, UnicodeError): continue
    except (OSError, UnicodeError): return

def codex_events(path):
    model = '未知模型'
    records, fallback = [], []
    previous = 0
    previous_parts = {"input":0,"cached":0,"output":0}
    for i, d in read_file(path):
        p = d.get('payload') or {}
        t = stamp(d.get('timestamp'))
        if d.get('type') == 'turn_context': model = p.get('model') or '未知模型'
        if d.get('type') == 'token_usage_record':
            u = p.get('usage') or {}
            records.append({'id': 'codex:' + (p.get('response_id') or str(path) + ':' + str(i)), 'time': t, 'model': model, 'provider': 'Codex', **tokens(u, 'Codex')})
        if d.get('type') == 'event_msg' and p.get('type') == 'token_count':
            info = p.get('info') or {}
            total = (info.get('total_token_usage') or {}).get('total_tokens')
            if not isinstance(total, (int,float)): continue
            delta = total - previous if total >= previous else total
            total_parts = tokens(info.get('total_token_usage') or {}, 'Codex')
            part_delta = {k:max(0,total_parts[k]-previous_parts[k]) for k in previous_parts} if total >= previous else total_parts
            previous_parts = total_parts
            previous = total
            if delta <= 0: continue
            values = tokens(info.get('last_token_usage') or {}, 'Codex')
            # Older logs may skip intermediate reports; use cumulative category deltas.
            if sum(values.values()) != delta:
                values = part_delta
                if sum(values.values()) != delta: continue
            fallback.append({'id': 'codex-legacy:' + str(path) + ':' + str(i), 'time': t, 'model': model, 'provider': 'Codex', **values})
    return records if records else fallback

def claude_events(path):
    for i, d in read_file(path):
        if d.get('type') != 'assistant': continue
        m = d.get('message') or {}
        if m.get('model') == '<synthetic>': continue
        yield {'id': 'claude:' + (m.get('id') or str(path) + ':' + str(i)), 'time': stamp(d.get('timestamp')), 'model': m.get('model') or '未知模型', 'provider': 'Claude', **tokens(m.get('usage') or {}, 'Claude')}

def collect(home, start, end, cache=None):
    unique = {}
    sources = []
    for provider, roots in [('Codex', [home/'.codex/sessions', home/'.codex/archived_sessions']), ('Claude', [home/'.claude/projects'])]:
        present = False
        for root in roots:
            if not root.exists(): continue
            present = True
            for path in root.rglob('*.jsonl'):
                try:
                    stat = path.stat()
                    if stat.st_mtime < start: continue
                except OSError: continue
                fingerprint = [stat.st_size, stat.st_mtime_ns]
                cached = cache.get(str(path)) if cache is not None else None
                if cached and cached.get('fingerprint') == fingerprint:
                    file_events = cached['events']
                else:
                    file_events = list(codex_events(path) if provider == 'Codex' else claude_events(path))
                    if cache is not None: cache.setdefault(str(path),{}).update({'fingerprint':fingerprint, 'events':file_events})
                for e in file_events:
                    if e['time'] is None or not start <= e['time'] <= end: continue
                    if sum(e[k] for k in ('input','cached','output')) <= 0: continue
                    old = unique.get(e['id'])
                    if old is None or sum(e[k] for k in ('input','cached','output')) > sum(old[k] for k in ('input','cached','output')):
                        unique[e['id']] = e
        sources.append({'name':provider,'available':present})
    return list(unique.values()), sources

def aggregate(events, start, end, interval=900):
    count = int((end-start)//interval)+1
    buckets = [{} for _ in range(count)]
    for e in events:
        index = min(count-1, int((e['time']-start)//interval))
        key = e['provider'] + ' · ' + e['model']
        row = buckets[index].setdefault(key, {'model':e['model'],'provider':e['provider'],'input':0,'cached':0,'output':0})
        for k in ('input','cached','output'): row[k] += e[k]
    total = 0
    points = []
    for i, b in enumerate(buckets):
        rows = sorted(b.values(), key=lambda r: -(r['input']+r['cached']+r['output']))
        value = sum(r[k] for r in rows for k in ('input','cached','output'))
        total += value
        points.append({'time':min(end,start+(i+1)*interval),'start':start+i*interval,'value':value,'cumulative':total,'models':rows})
    return points

def duration_minutes(sample):
    value = sample.get('windowMinutes')
    if isinstance(value, (int, float)) and value > 0: return value
    match = re.search(r'(\d+(?:\.\d+)?)\s*(天|小时)$', sample.get('label',''))
    return float(match[1]) * (1440 if match[2] == '天' else 60) if match else None


def cycle_summaries(quotas, events, now):
    latest = {}
    for sample in quotas:
        key = sample['provider'] + ' · ' + sample['label']
        if key not in latest or sample['time'] > latest[key]['time']: latest[key] = sample
    summaries = []
    for key, sample in latest.items():
        duration = duration_minutes(sample)
        end = sample.get('reset')
        available = bool(duration and isinstance(end,(int,float)) and end > now and end-duration*60 <= now)
        start = end-duration*60 if available else None
        by_model = {}
        if available:
            for event in events:
                if event['provider'] != sample['provider'] or not start <= event['time'] <= now or event['time'] >= end: continue
                row = by_model.setdefault(event['model'], {'model':event['model'],'provider':event['provider'],'input':0,'cached':0,'output':0})
                for k in ('input','cached','output'): row[k] += event[k]
        models = sorted(by_model.values(),key=lambda r:-(r['input']+r['cached']+r['output']))
        summaries.append({'series':key,'provider':sample['provider'],'start':start,'end':end,'available':available,
                          'models':models,'total':sum(r[k] for r in models for k in ('input','cached','output'))})
    return summaries


def resolve_range(mode, now, start=None, end=None):
    today = dt.datetime.fromtimestamp(now).date()
    midnight = dt.datetime.combine(today,dt.time()).timestamp()
    if mode == 'today': return midnight, now
    if mode == 'week': return dt.datetime.combine(today-dt.timedelta(days=6),dt.time()).timestamp(), now
    if mode == 'custom':
        if start is None or end is None or not math.isfinite(start) or not math.isfinite(end) or start >= end or start >= now:
            raise ValueError('开始时间需早于结束时间，且不能晚于现在。')
        return start, min(end,now)
    if mode == 'cycle': return midnight, now
    raise ValueError('未知日期范围。')


def range_summaries(events, sources):
    result = []
    for source in sources:
        rows = {}
        for event in events:
            if event['provider'] != source['name']: continue
            row = rows.setdefault(event['model'],{'model':event['model'],'provider':event['provider'],'input':0,'cached':0,'output':0})
            for key in ('input','cached','output'): row[key] += event[key]
        models = sorted(rows.values(),key=lambda r:-(r['input']+r['cached']+r['output']))
        result.append({'provider':source['name'],'available':source['available'],'models':models,
                       'total':sum(r[k] for r in models for k in ('input','cached','output'))})
    return result


def history(home=None, now=None, mode='cycle', range_start=None, range_end=None):
    home = home or pathlib.Path.home()
    now = now or time.time()
    start, end = resolve_range(mode,now,range_start,range_end)
    cache_path = home/'Library/Application Support/UsageBar/event-cache-v1.json'
    try:
        saved = json.loads(cache_path.read_text())
        cache = saved.get('files',{}) if saved.get('version') == 1 else {}
    except (OSError, ValueError): cache = {}
    today_start, _ = resolve_range('today',now)
    current_quotas = quota_samples(home,today_start,now,cache)
    definitions = cycle_summaries(current_quotas,[],now)
    if mode == 'cycle': start = min([start]+[c['start'] for c in definitions if c['available']])
    earliest = min([start]+[c['start'] for c in definitions if c['available']])
    quotas = quota_samples(home,start,end,cache)
    events, sources = collect(home,earliest,now,cache)
    try:
        cache_path.parent.mkdir(parents=True,exist_ok=True)
        # Retain at least the recent month to avoid reparsing when switching presets.
        keep_since = min(earliest,now-31*86400)
        cache = {k:v for k,v in cache.items() if v.get('fingerprint',v.get('quotaFingerprint',[0,0]))[1] >= keep_since*1e9}
        temp = cache_path.with_name(cache_path.name + '.' + str(os.getpid()) + '.tmp')
        temp.write_text(json.dumps({'version':1,'files':cache},separators=(',',':')))
        temp.replace(cache_path)
    except OSError: pass
    selected = [e for e in events if start <= e['time'] < end]
    span = end-start
    interval = 900 if span <= 7*86400 else math.ceil(span/672/3600)*3600
    points = aggregate(selected,start,end,interval)
    return {'start':start,'rangeEnd':end,'updated':now,'mode':mode,'interval':interval,
            'rangeKey':mode+(':'+str(range_start)+':'+str(range_end) if mode=='custom' else ''),
            'points':points,'quotas':quotas,'cycles':cycle_summaries(current_quotas,events,now),
            'summaries':range_summaries(selected,sources),'sources':sources,
            'total':sum(p['value'] for p in points),'requests':len(selected)}


# Quota samples are kept separate from token accounting.
def quota_samples(home, start, end, cache=None):
    result = []
    first_direct = {}
    def sample(t, provider, label, used, reset, source, minutes=None):
        if not isinstance(t,(int,float)) or not isinstance(used,(int,float)): return None
        return {'time':t,'provider':provider,'label':label,'used':max(0,min(100,used)),'reset':reset,'source':source,'windowMinutes':minutes}
    for root in [home/'.codex/sessions', home/'.codex/archived_sessions']:
        if not root.exists(): continue
        for path in root.rglob('*.jsonl'):
            try:
                stat = path.stat()
                if stat.st_mtime < start: continue
            except OSError: continue
            fingerprint = [stat.st_size,stat.st_mtime_ns]
            saved = cache.get(str(path),{}) if cache is not None else {}
            if saved.get('quotaFingerprint') == fingerprint:
                file_samples = saved['quotaSamples']
            else:
                file_samples = []
                for _, d in read_file(path):
                    if d.get('type') != 'event_msg': continue
                    r = (d.get('payload') or {}).get('rate_limits') or {}
                    if not isinstance(r,dict): continue
                    for field in ['primary','secondary']:
                        w = r.get(field)
                        if not isinstance(w,dict): continue
                        mins = w.get('window_minutes')
                        duration = f'{mins // 1440} 天' if mins and mins >= 1440 else f'{mins / 60:g} 小时' if mins else field
                        label = (r.get('limit_name') or r.get('limit_id') or 'codex') + ' · ' + duration
                        value = sample(stamp(d.get('timestamp')),'Codex',label,w.get('used_percent'),w.get('resets_at'),'本机日志',mins)
                        if value: file_samples.append(value)
                if cache is not None: cache.setdefault(str(path),{}).update({'quotaFingerprint':fingerprint,'quotaSamples':file_samples})
            result.extend(s for s in file_samples if start <= s['time'] < end)
    state = home/'Library/Application Support/UsageBar'
    for path in state.glob('quota-*.jsonl'):
        for _, d in read_file(path):
            value = sample(d.get('time'),d.get('provider',''),d.get('label',''),d.get('used'),d.get('reset'),'自动采样',d.get('windowMinutes'))
            if not value: continue
            key = (value['provider'],value['label'])
            first_direct[key] = min(first_direct.get(key,value['time']),value['time'])
            if start <= value['time'] < end: result.append(value)
    # Session events can repeat an old quota snapshot long after another session
    # has seen a newer value. Once direct sampling starts for a series, session
    # logs are historical backfill only, including during later polling gaps.
    for sample in result:
        if sample['source'] != '自动采样': continue
        key = (sample['provider'], sample['label'])
        first_direct[key] = min(first_direct.get(key, sample['time']), sample['time'])
    groups = {}
    for sample in sorted(result, key=lambda s: s['time']):
        key = (sample['provider'], sample['label'])
        if sample['source'] == '本机日志' and sample['time'] >= first_direct.get(key, float('inf')):
            continue
        groups.setdefault(key, []).append(sample)
    compact = []
    for series in groups.values():
        kept = []
        for i, sample in enumerate(series):
            if kept:
                previous = kept[-1]
                a, b = previous['reset'], sample['reset']
                same_window = a == b or (isinstance(a, (int, float)) and isinstance(b, (int, float)) and abs(a - b) <= 60)
                if sample == previous: continue
                if (sample['used'] == previous['used'] and same_window
                        and sample['time'] - previous['time'] < 300 and i != len(series) - 1):
                    continue
            kept.append(sample)
        compact.extend(kept)
    return compact

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode',choices=['cycle','today','week','custom'],default='cycle')
    parser.add_argument('--start',type=float)
    parser.add_argument('--end',type=float)
    args = parser.parse_args()
    try: print(json.dumps(history(mode=args.mode,range_start=args.start,range_end=args.end),ensure_ascii=False))
    except ValueError as error: print(json.dumps({'error':str(error)},ensure_ascii=False))
