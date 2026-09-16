import datetime as dt
import json
import pathlib
import tempfile
import unittest
import os
import time
from unittest.mock import patch
from history import collect, aggregate, quota_samples, codex_events, cycle_summaries, duration_minutes, resolve_range, history

class HistoryTests(unittest.TestCase):
    def write(self,root,relative,rows):
        p=root/relative;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text('\n'.join(json.dumps(r) for r in rows));return p
    def test_request_dedup_and_model_switch(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t)
            def request(i,u): return {'type':'token_usage_record','timestamp':'2026-09-16T01:01:00Z','payload':{'response_id':i,'usage':u}}
            rows=[{'type':'turn_context','payload':{'model':'model-a'}},request('one',{'input_tokens':100,'cached_input_tokens':80,'output_tokens':20}),{'type':'turn_context','payload':{'model':'model-b'}},request('two',{'input_tokens':50,'output_tokens':10})]
            self.write(root,'.codex/sessions/a.jsonl',rows)
            self.write(root,'.codex/archived_sessions/a.jsonl',rows)
            start=dt.datetime(2026,9,16,tzinfo=dt.timezone.utc).timestamp()
            events,_=collect(root,start,start+7200)
            self.assertEqual(len(events),2)
            self.assertEqual(sum(e['input']+e['cached']+e['output'] for e in events),180)
            points=aggregate(events,start,start+7200)
            active=[p for p in points if p['value']]
            self.assertEqual(len(active),1)
            self.assertEqual({r['model'] for r in active[0]['models']},{'model-a','model-b'})
    def test_claude_streaming_and_day_boundary(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t)
            def row(date,out):return {'type':'assistant','timestamp':date,'message':{'id':'one','model':'claude-model','usage':{'input_tokens':10,'cache_read_input_tokens':30,'cache_creation_input_tokens':5,'output_tokens':out}}}
            self.write(root,'.claude/projects/p/a.jsonl',[row('2026-09-15T23:59:00Z',1),row('2026-09-16T00:01:00Z',2),row('2026-09-16T00:01:01Z',8)])
            start=dt.datetime(2026,9,16,tzinfo=dt.timezone.utc).timestamp()
            events,_=collect(root,start,start+3600)
            self.assertEqual(len(events),1)
            self.assertEqual(events[0]['input']+events[0]['cached']+events[0]['output'],53)
    def test_quota_reset_and_missing_baseline(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t)
            self.write(root,'Library/Application Support/UsageBar/quota-test.jsonl',[
                {'time':1000,'provider':'Codex','label':'week','used':80,'reset':2000},
                {'time':1100,'provider':'Codex','label':'week','used':80,'reset':2000},
                {'time':2001,'provider':'Codex','label':'week','used':1,'reset':3000}])
            samples=quota_samples(root,0,4000)
            self.assertEqual(len(samples),2)
            self.assertEqual(samples[0]['time'],1000)
            self.assertEqual([s['used'] for s in samples],[80,1])
    def test_legacy_duplicate_events_not_double_counted(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t)
            event={'type':'event_msg','timestamp':'2026-09-16T01:00:00Z','payload':{'type':'token_count','info':{'total_token_usage':{'total_tokens':120},'last_token_usage':{'input_tokens':100,'output_tokens':20}}}}
            path=self.write(root,'x.jsonl',[event,event])
            self.assertEqual(len(codex_events(path)),1)
    def test_direct_sampling_excludes_late_session_snapshots(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            def log(at, used, bucket='codex'):
                return {'type':'event_msg','timestamp':dt.datetime.fromtimestamp(at,dt.timezone.utc).isoformat(),
                        'payload':{'type':'token_count','rate_limits':{'limit_id':bucket,'primary':{'used_percent':used,'window_minutes':10080,'resets_at':9000}}}}
            self.write(root,'.codex/sessions/a.jsonl',[log(100,70),log(210,70),log(310,71),log(320,2,'spark')])
            self.write(root,'Library/Application Support/UsageBar/quota-test.jsonl',[
                {'time':200,'provider':'Codex','label':'codex · 7 天','used':71,'reset':9000},
                {'time':300,'provider':'Codex','label':'codex · 7 天','used':72,'reset':9000}])
            samples = quota_samples(root,0,400)
            main = [s for s in samples if s['label']=='codex · 7 天']
            self.assertEqual([(s['time'],s['used']) for s in main],[(100,70),(200,71),(300,72)])
            self.assertEqual(len([s for s in samples if s['label']=='spark · 7 天']),1)

    def test_confirmed_quota_recovery_is_preserved(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            self.write(root,'Library/Application Support/UsageBar/quota-test.jsonl',[
                {'time':100,'provider':'Codex','label':'week','used':79,'reset':9000},
                {'time':200,'provider':'Codex','label':'week','used':78,'reset':9000},
                {'time':9001,'provider':'Codex','label':'week','used':1,'reset':18000}])
            self.assertEqual([s['used'] for s in quota_samples(root,0,10000)],[79,78,1])

    def test_reset_rounding_does_not_flood_flat_history(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            self.write(root,'Library/Application Support/UsageBar/quota-test.jsonl',[
                {'time':100+i,'provider':'Codex','label':'week','used':78,'reset':9000+i%2} for i in range(10)])
            samples = quota_samples(root,0,400)
            self.assertEqual([s['time'] for s in samples],[100,109])

    def test_cycle_uses_reset_boundary_and_all_days(self):
        now = 1_000_000
        end = now + 3600
        week_start = end - 10080*60
        quotas = [
            {'provider':'Codex','label':'week','time':now,'reset':end,'windowMinutes':10080},
            {'provider':'Codex','label':'short','time':now,'reset':end,'windowMinutes':300}]
        def event(t,model='a',provider='Codex'):
            return {'time':t,'provider':provider,'model':model,'input':100,'cached':20,'output':10}
        events = [event(week_start-1),event(week_start),event(now-25000,'b'),event(now-100),event(now-100,provider='Claude'),event(now+1)]
        result = {c['series']:c for c in cycle_summaries(quotas,events,now)}
        week = result['Codex · week']
        self.assertEqual(week['start'],week_start)
        self.assertEqual(week['total'],390)
        self.assertEqual({r['model'] for r in week['models']},{'a','b'})
        self.assertEqual(result['Codex · short']['total'],130)

    def test_unknown_and_expired_cycle_not_replaced_with_today(self):
        quotas = [{'provider':'Codex','label':'unknown','time':100,'reset':1000},
                  {'provider':'Codex','label':'7 天','time':100,'reset':200}]
        self.assertTrue(all(not c['available'] and c['start'] is None for c in cycle_summaries(quotas,[],300)))
        self.assertEqual(duration_minutes({'label':'codex · 7 天'}),10080)
        self.assertEqual(duration_minutes({'label':'5 小时'}),300)

    def test_usage_cache_reuses_files_and_invalidates_on_change(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            def event(identifier):
                return {'type':'token_usage_record','timestamp':'1970-01-01T00:01:40Z','payload':{'response_id':identifier,'usage':{'input_tokens':100,'output_tokens':10}}}
            path = self.write(root,'.codex/sessions/a.jsonl',[event('one')])
            cache = {}
            with patch('history.codex_events',wraps=codex_events) as parser:
                a,_ = collect(root,0,200,cache)
                b,_ = collect(root,0,200,cache)
                self.assertEqual(a,b)
                self.assertEqual(parser.call_count,1)
                path.write_text(path.read_text()+'\n'+json.dumps(event('two')))
                c,_ = collect(root,0,200,cache)
                self.assertEqual(parser.call_count,2)
                self.assertEqual(len(c),2)

    def test_presets_and_custom_validation(self):
        now = dt.datetime(2026,9,16,12).timestamp()
        self.assertEqual(resolve_range('today',now),(dt.datetime(2026,9,16).timestamp(),now))
        self.assertEqual(resolve_range('week',now),(dt.datetime(2026,9,10).timestamp(),now))
        self.assertEqual(resolve_range('custom',now,100,now+100),(100,now))
        for a,b in [(200,100),(100,100),(now+1,now+2),(float('nan'),now)]:
            with self.assertRaises(ValueError): resolve_range('custom',now,a,b)

    def test_custom_history_end_exclusive_without_quota_data(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            def event(at,identifier):
                return {'type':'token_usage_record','timestamp':dt.datetime.fromtimestamp(at,dt.timezone.utc).isoformat(),'payload':{'response_id':identifier,'usage':{'input_tokens':100,'output_tokens':10}}}
            self.write(root,'.codex/sessions/a.jsonl',[event(99,'before'),event(100,'start'),event(199,'inside'),event(200,'end')])
            result = history(root,now=1000,mode='custom',range_start=100,range_end=200)
            self.assertEqual((result['start'],result['rangeEnd']),(100,200))
            self.assertEqual(result['total'],220)
            self.assertEqual(result['requests'],2)
            self.assertEqual(result['quotas'],[])
            self.assertEqual(result['summaries'][0]['total'],220)
            self.assertEqual(sum(p['value'] for p in result['points']),220)

    def test_narrow_range_keeps_global_direct_source_cutoff(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            self.write(root,'Library/Application Support/UsageBar/quota-test.jsonl',[{'time':100,'provider':'Codex','label':'codex · 7 天','used':79,'reset':9000}])
            self.write(root,'.codex/sessions/a.jsonl',[{'type':'event_msg','timestamp':dt.datetime.fromtimestamp(210,dt.timezone.utc).isoformat(),'payload':{'rate_limits':{'limit_id':'codex','primary':{'used_percent':78,'window_minutes':10080,'resets_at':9000}}}}])
            self.assertEqual(quota_samples(root,200,300),[])

    def test_historical_quota_cache_reuses_file_parse(self):
        with tempfile.TemporaryDirectory() as t:
            root = pathlib.Path(t)
            self.write(root,'.codex/sessions/a.jsonl',[{'type':'event_msg','timestamp':'1970-01-01T00:01:40Z','payload':{'rate_limits':{'primary':{'used_percent':10,'window_minutes':10080,'resets_at':9000}}}}])
            import history as module
            cache = {}
            with patch('history.read_file',wraps=module.read_file) as reader:
                a = quota_samples(root,0,200,cache)
                b = quota_samples(root,50,200,cache)
                self.assertEqual(a,b)
                self.assertEqual(reader.call_count,1)

    def test_week_preset_uses_local_midnight_across_dst(self):
        previous = os.environ.get('TZ')
        try:
            os.environ['TZ'] = 'America/New_York'; time.tzset()
            now = dt.datetime(2026,11,2,12).timestamp()
            start,_ = resolve_range('week',now)
            expected = dt.datetime(2026,10,27,4,tzinfo=dt.timezone.utc).timestamp()
            self.assertEqual(start,expected)
        finally:
            if previous is None: os.environ.pop('TZ',None)
            else: os.environ['TZ'] = previous
            time.tzset()

if __name__ == '__main__':unittest.main()
