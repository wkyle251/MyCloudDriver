#!/usr/bin/env python3
"""Synthetic fixtures only: monitor privacy, rates, storage bounds, and terminal layout."""
import copy
import datetime as dt
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('dashboard',Path(__file__).with_name('remote-download-monitor.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
c=m.COLLECT


class DashboardTests(unittest.TestCase):
    def test_range_channels_and_header_metrics_are_numeric_at_both_boundaries(self):
        packet=m.demo_packet(0,1000)
        counters={'range_active_channels':3,'range_admission_limit':4,'range_header_active':1,
                  'range_header_count':10,'range_header_total_ms':200,'range_header_max_ms':80,
                  'range_header_failed':2,'range_trial_accepted':1,'range_trial_rejected':2,'range_startup_reused':5}
        packet['state']['values'].update(counters)
        packet['window']={'updated_at':1000,'values':dict(counters)}
        clean=c.sanitize_packet(packet)
        for location in ('state','window'):
            for key,value in counters.items(): self.assertEqual(clean[location]['values'][key],value)
        packet['state']['values']['range_active_channels']='https://generated.invalid/private'
        packet['window']['values']['range_header_max_ms']=True
        clean=c.sanitize_packet(packet)
        self.assertNotIn('range_active_channels',clean['state']['values'])
        self.assertNotIn('range_header_max_ms',clean['window']['values'])

    def test_waiting_check_counters_remain_numeric_at_both_boundaries(self):
        packet=m.demo_packet(0,1000)
        counters={'waiting_read_bytes':100,'waiting_read_tasks':99,'oldest_waiting_read_ms':90_000,
                  'read_turn_latency_handoffs':3}
        packet['state']['values'].update(counters)
        packet['window']={'updated_at':1000,'values':dict(counters)}
        clean=c.sanitize_packet(packet)
        for location in ('state','window'):
            for key,value in counters.items(): self.assertEqual(clean[location]['values'][key],value)
        packet['state']['values']['waiting_read_tasks']='generated-private.bin'
        self.assertNotIn('waiting_read_tasks',c.sanitize_packet(packet)['state']['values'])

    def test_receive_wait_and_payload_counters_survive_privacy_filtering(self):
        packet=m.demo_packet(0,1000)
        values={'ram_body_limit_active':2,'ram_shared_limit_max_ms':123,'ram_pressure_count':1,
                'connection_known_cooldown_remaining_ms':20_000,'payload_http_429':3,
                'payload_streaming_fallback':4,'payload_early_empty_retry':5,'payload_deferred_rearm':6}
        packet['state']['values'].update(values)
        packet['waits']['stages']['ram_body_limit']={'active':2,'oldest_ms':123,'count':1,'total_ms':50,'max_ms':50}
        packet['waits']['responses']['payload_timeout']=7
        packet['waits']['responses']['private_payload_error']=99
        clean=c.sanitize_packet(packet)
        for key,value in values.items():self.assertEqual(clean['state']['values'][key],value)
        self.assertEqual(clean['waits']['stages']['ram_body_limit']['active'],2)
        self.assertEqual(clean['waits']['responses']['payload_timeout'],7)
        self.assertNotIn('private_payload_error',clean['waits']['responses'])

    def test_real_five_second_rate_duplicates_and_restart(self):
        dashboard=m.Dashboard()
        for i in range(6): row=dashboard.update(m.demo_packet(i,1000))
        self.assertEqual(row['five_second_bytes_per_second'],55e6)
        self.assertEqual(row['monitor_average_bytes_per_second'],55e6)
        self.assertEqual(dashboard.update(m.demo_packet(5,1000))['monitor_average_bytes_per_second'],55e6)
        restart=m.demo_packet(6,1000);restart['live']['helper_pid']=43;restart['live']['received_bytes']=0
        row=dashboard.update(restart)
        self.assertIsNone(row['five_second_bytes_per_second'])
        self.assertEqual(row['helper_restarts'],1)
        self.assertFalse(row['progress_available'])

    def test_stale_data_is_missing_instead_of_zero(self):
        dashboard=m.Dashboard()
        for i in range(5):dashboard.update(m.demo_packet(i,1000))
        stale=m.demo_packet(5,1000);stale['live']['updated_at']-=20
        row=dashboard.update(stale)
        self.assertIsNone(row['five_second_bytes_per_second'])
        self.assertEqual(row['values'],{})
        self.assertEqual(row['status'],'app_unavailable')
        dashboard.latest_at=time.monotonic()-10
        self.assertEqual(dashboard.view()['status'],'disconnected')
        self.assertIsNone(dashboard.view()['disk_read_bytes_per_second'])

    def test_metadata_has_its_own_age_and_pid_checks(self):
        packet=m.demo_packet(1,1000);packet['state']['updated_at']-=7
        packet['window']={'updated_at':1001,'values':{'ram_buffered_bytes':50,'pending_read_bytes':100}}
        row=m.Dashboard().update(packet)
        self.assertFalse(row['progress_available']);self.assertEqual(row['values']['ram_buffered_bytes'],50)
        packet['window']['updated_at']-=60
        self.assertEqual(m.Dashboard().update(packet)['values'],{})
        packet=m.demo_packet(1,1000);packet['waits']['helper_pid']=99
        self.assertIsNone(m.Dashboard().update(packet)['waits'])

    def test_disk_rates_reset_on_device_reconnect_gap_or_rollback(self):
        rate=m.CounterRate();a={'identity':1,'read_bytes':10,'written_bytes':20}
        self.assertEqual(rate.sample(a,1),(None,None))
        self.assertEqual(rate.sample({**a,'read_bytes':30,'written_bytes':60},3),(10,20))
        self.assertEqual(rate.sample({**a,'identity':2},4),(None,None))
        self.assertEqual(rate.sample(a,30),(None,None))
        self.assertEqual(rate.sample({**a,'read_bytes':1},31),(None,None))

    def test_privacy_allowlist_at_both_boundaries(self):
        packet=m.demo_packet(0,1000)
        secret='generated-private-name.bin';packet['filename']=secret
        packet['state']['values'].update(filename=secret,generated_private_name=25,ram_wait_count=True,ram_peak_bytes=float('inf'))
        packet['waits']['stages']['private_stage']={'active':1}
        packet['system']['name']=secret;packet['disk']['path']=secret
        clean=c.sanitize_packet(packet);text=json.dumps(clean)
        self.assertNotIn(secret,text);self.assertNotIn('private_stage',text);self.assertNotIn('generated_private_name',text)
        self.assertNotIn('ram_wait_count',clean['state']['values'])
        self.assertNotIn('ram_peak_bytes',clean['state']['values'])
        self.assertEqual(c.sanitize_packet(clean),clean)

    def test_live_speed_strict_schema(self):
        live=m.demo_packet(0,1000)['live']
        self.assertIsNotNone(c.clean_live(live))
        for change in ({'filename':'generated.bin'},{'received_bytes':True},{'sampled_uptime':float('nan')},{'helper_pid':0}):
            self.assertIsNone(c.clean_live({**live,**change}))

    def test_extreme_eta_does_not_crash_dashboard(self):
        self.assertEqual(m.completion(1000,None),'--')
        self.assertEqual(m.completion(1000,1e19),'--')
        self.assertNotEqual(m.completion(1000,3600),'--')

    def test_bounded_reader_skips_symlinks_fifos_and_oversize(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);file=root/'generated.json';file.write_text('{"count":1}')
            self.assertEqual(c.read_json(file,50),{'count':1})
            link=root/'link';link.symlink_to(file);self.assertIsNone(c.read_bounded(link,50))
            fifo=root/'fifo';os.mkfifo(fifo);self.assertIsNone(c.read_bounded(fifo,50))
            self.assertIsNone(c.read_bounded(file,2))
            self.assertEqual(c.read_bounded(file,2,tail=True),b'1}')

    def test_tailer_reads_numeric_events_only_and_skips_partial_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);file=root/'downloads-2026-10-10-123456789-00000000-0000-0000-0000-000000000000.jsonl'
            rows=[{'timestamp':'2026-10-10T12:00:00Z','event':'retry','values':{'received_bytes':10}},
                  {'timestamp':'2026-10-10T12:01:00Z','event':'download_window','filename':'generated.bin',
                   'values':{'received_bytes':20,'pending_read_bytes':50,'private':123}}]
            file.write_text('{partial\n'+'\n'.join(json.dumps(row) for row in rows)+'\n')
            result=c.WindowTail().read(root,10)
            self.assertEqual(result['values'],{'received_bytes':20,'pending_read_bytes':50})
            self.assertNotIn('generated.bin',json.dumps(result))

    def test_rotation_compression_privacy_and_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);old=root/'monitor-20200101T000000Z-000000000000.jsonl.gz'
            with gzip.open(old,'wb') as out:out.write(b'{}\n')
            logger=m.HistoryLog(root,cap=30000,segment=8000)
            self.assertFalse(old.exists())
            packet=m.demo_packet(0,1000);packet['filename']='generated-private.bin'
            for i in range(20):logger.write(packet)
            self.assertEqual(root.stat().st_mode&0o777,0o700)
            for path in logger.files():self.assertEqual(path.stat().st_mode&0o777,0o600)
            self.assertLessEqual(sum(p.stat().st_size for p in logger.files()),30000)
            logger.close();files=sorted(root.glob('*.jsonl.gz'))
            self.assertGreater(len(files),1)
            rows=list(m.replay_rows(files));self.assertGreater(len(rows),0)
            self.assertNotIn('generated-private.bin',json.dumps(rows))

    def test_restart_archives_crash_tail_and_reuses_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);name='monitor-'+dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-000000000001.jsonl'
            file=root/name;packet=m.demo_packet(0,1000)
            file.write_text(json.dumps(packet)+'\n{partial')
            logger=m.HistoryLog(root)
            self.assertFalse(file.exists());self.assertEqual(len(list(m.replay_rows(root.glob('*.gz')))),1)
            with self.assertRaises(OSError):m.HistoryLog(root)
            logger.close();second=m.HistoryLog(root);second.close()

    def test_summary_retains_low_speed_evidence_and_skips_missing_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'generated.jsonl'
            packets=[]
            for i in range(10):
                row=m.demo_packet(i,1000);row['live']['received_bytes']=i*2*1_000_000;packets.append(row)
            path.write_text('\n'.join(json.dumps(row) for row in packets)+'\n')
            out=io.StringIO()
            with patch('sys.stdout',out):m.summary([path])
            text=out.getvalue();self.assertIn('1.00 MB/s',text);self.assertIn('ram_waiters=',text)
            self.assertNotIn('generated-private',text)

    def test_dashboard_layout_across_terminal_sizes(self):
        class Screen:
            def __init__(self,h,w):self.h=h;self.w=w;self.lines=[' '*w for _ in range(h)]
            def erase(self):pass
            def getmaxyx(self):return self.h,self.w
            def addnstr(self,y,x,text,n,color):
                self.lines[y]=self.lines[y][:x]+text[:n]+self.lines[y][x+min(n,len(text)):]
            def refresh(self):pass
        args=type('Args',(),{'demo':True,'host':'generated@192.0.2.1','history':300})()
        model=m.Dashboard()
        for i in range(20):
            packet=m.demo_packet(i,1000)
            if i==19:packet['live']['received_bytes']+=40_000_000
            model.update(packet)
        with patch.object(m.curses,'color_pair',return_value=0):
            for height,width in [(24,80),(26,140),(28,88),(30,88),(31,140),(32,140),(33,140),(36,140),(42,190),(60,80),(8,30)]:
                screen=Screen(height,width);m.paint(screen,model,args,None,replay=True)
                if height>=30 and width>=88:
                    self.assertIn('PENDING READ','\n'.join(screen.lines));self.assertIn('WAIT TRACE','\n'.join(screen.lines))
                if height>=24 and width>=70:
                    self.assertIn('q quit','\n'.join(screen.lines))
                    headings=[]
                    for title,field,disk in [('DOWNLOAD','current_bytes_per_second',False),('READ','disk_read_bytes_per_second',True),('WRITE','disk_write_bytes_per_second',True)]:
                        heading=title+' '+m.rate(model.latest[field],disk)+' |'
                        matches=[(y,line) for y,line in enumerate(screen.lines) if line.startswith(' '+heading)]
                        self.assertEqual(len(matches),1,(height,width,title))
                        y,line=matches[0];headings.append(y)
                    self.assertLess(headings[0],headings[1]);self.assertLess(headings[1],headings[2])
            screen=Screen(36,140);m.paint(screen,model,args,None,replay=True)
            Path('/private/tmp/mycloud-monitor-synthetic-preview.txt').write_text('\n'.join(screen.lines)+'\n')
            model.latest_at=time.monotonic()-10
            screen=Screen(24,80);m.paint(screen,model,args,None)
            for title in ('DOWNLOAD','READ','WRITE'):
                self.assertIn(title+' -- |','\n'.join(screen.lines))


if __name__=='__main__':unittest.main()
