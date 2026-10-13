#!/usr/bin/env python3
"""Read bounded numeric app snapshots and macOS kernel counters; never download files."""
import argparse
import ctypes as C
import datetime as dt
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import time

PROGRESS_KEYS = set('''build downloaded_bytes total_bytes remaining_bytes fraction estimated lower_bound
total_files completed_files skipped_files failed_files active_files retrying_files queued_downloads
totals_incomplete reception_paused is_downloading app_bytes_per_second overall_bytes_per_second eta_seconds chart_eta_seconds
ram_buffered_bytes ram_peak_bytes ram_limit_bytes ram_configured_bytes ram_reserve_bytes ram_memory_pressure
pending_read_bytes reading_bytes pending_read_tasks reading_tasks read_drives write_drives
oldest_pending_read_ms pending_write_bytes writing_bytes writing_tasks active_read_tasks active_write_tasks
ready_read_tasks ready_read_bytes turn_elapsed_ms switch_wait_ms read_write_threshold_percent
read_tasks_started read_tasks_finished read_turns write_turns receiving_tasks ram_waiting_receivers
ram_wait_count ram_wait_total_ms file_network_workers file_worker_limit admitted_read_tasks deferred_read_tasks
download_has_ready waiting_writers eligible_waiting_writers checkpoint_batch_pending'''.split())
PROGRESS_KEYS |= set('prefetch_bytes prefetch_tasks prefetch_discarded_bytes prefetch_active_slots prefetch_contexts prefetch_receiver_limit prefetch_context_limit prefetch_finished prefetch_failed prefetch_empty_ends'.split())
RECEIVE_WAITS = 'ram_body_limit ram_shared_limit ram_pressure connection_budget connection_cooldown connection_endpoint_capacity connection_shared_slots'.split()
RECEIVE_COUNTERS = set('''payload_timeout payload_connection payload_range_validation payload_io payload_interrupted
payload_unavailable payload_streaming_fallback payload_early_empty_retry payload_deferred_rearm payload_http_success
payload_http_429 payload_http_5xx payload_http_auth payload_http_416 payload_http_other connection_budget_blocked_polls
connection_cooldown_blocked_polls connection_endpoint_blocked_polls connection_shared_blocked_polls
connection_cooldown_events connection_known_cooldown_remaining_ms'''.split())
RECEIVE_KEYS = RECEIVE_COUNTERS | {kind+'_'+suffix for kind in RECEIVE_WAITS for suffix in ('count','active','total_ms','max_ms','oldest_ms')}
PROGRESS_KEYS |= RECEIVE_KEYS
WINDOW_KEYS = PROGRESS_KEYS | set('''received_bytes seconds bytes_per_second min_bytes_per_second
max_bytes_per_second samples verifying_files ram_reserved_bytes read_batch_remaining_bytes
admitted_read_bytes deferred_read_bytes read_admission_deferrals ram_draining_tasks disk_only_tasks
active_write_bytes active_read_bytes file_task_capacity file_task_capacity_reached receiving_admission_waiters
read_turn_timeouts read_turn_finishes read_turn_pressure_handoffs read_turn_control_handoffs
last_read_handover_sequence last_read_handover_reason last_read_turn_ms last_read_remaining_bytes
read_turn_write_handoffs read_write_threshold_bytes last_read_pending_write_bytes last_read_buffer_limit_bytes
write_dispatch_polls turn_target_ms backlog_drives ram_wait_max_ms checkpoint_batches checkpoint_batched_files
checkpoint_barriers checkpoint_batch_total_ms'''.split())
KINDS = '''resume_read final_read checkpoint retry_cache_hit retry_cache_miss checkpoint_wait checkpoint_sync
payload_write read_preparation read_queue_wait read_gate_wait read_turn_wait read_io read_hash scheduler_pass'''.split()
WINDOW_KEYS |= {kind+'_'+suffix for kind in KINDS for suffix in ('count','bytes','total_ms','max_ms','failed','active')}
STAGES = set('''download_url account_metadata account_token account_captcha account_headers account_body
account_backoff guest_metadata guest_captcha guest_headers guest_body guest_refresh_lock guest_refresh_headers
guest_refresh_body share_lock share_cache share_process_lock share_inventory share_inventory_wait
share_inventory_page share_create cache_open setup_permit receiving_slot content_permit content_headers
range_probe fs_open fs_metadata output_lease account_captcha_lock account_captcha_headers account_captcha_body
auth_lock auth_file_lock auth_headers auth_body'''.split())
STAGES |= set(RECEIVE_WAITS)
RESPONSES = {role+'_'+category for role in ('account','guest') for category in ('success','429','5xx','auth','other')}
RESPONSES |= RECEIVE_COUNTERS - {'connection_known_cooldown_remaining_ms'}
STAGE_KEYS = {'count','total_ms','max_ms','active','oldest_ms'}
SYSTEM_KEYS = {'cpu_percent','ram_total_bytes','ram_used_bytes','ram_available_bytes','load_1m','load_5m','load_15m'}
DISK_KEYS = {'identity','read_bytes','written_bytes'}
LOG_NAME = re.compile(r'downloads-\d{4}-\d{2}-\d{2}-\d{9}-[A-Fa-f0-9-]{36}\.jsonl\Z')


def numeric(values, allowed):
    if not isinstance(values, dict): return {}
    return {k:v for k,v in values.items() if k in allowed and type(v) in (int,float)
            and math.isfinite(v) and 0 <= v < 2**65}


def read_bounded(path, limit, tail=False):
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os,'O_NOFOLLOW',0))
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or (not tail and info.st_size > limit): return None
        if tail: os.lseek(fd, max(0, info.st_size-limit), os.SEEK_SET)
        raw = os.read(fd,limit+1)
        return raw if len(raw)<=limit else None
    except OSError: return None
    finally:
        if fd is not None: os.close(fd)


def read_json(path, limit):
    try: return json.loads(read_bounded(path,limit) or b'null')
    except (ValueError,UnicodeError): return None


def valid_snapshot(row):
    return (isinstance(row,dict) and type(row.get('version')) is int and row['version']==1
            and type(row.get('helper_pid')) is int and row['helper_pid']>0
            and type(row.get('updated_at')) in (int,float) and math.isfinite(row['updated_at']))


def clean_live(row):
    keys = {'version','helper_pid','received_bytes','sampled_uptime','updated_at'}
    if not valid_snapshot(row) or set(row)!=keys: return None
    if type(row['received_bytes']) is not int or not 0<=row['received_bytes']<2**64: return None
    if type(row['sampled_uptime']) not in (int,float) or not math.isfinite(row['sampled_uptime']) or row['sampled_uptime']<0: return None
    return row


def clean_state(row):
    if not valid_snapshot(row): return None
    return {'version':1,'helper_pid':row['helper_pid'],'updated_at':row['updated_at'],
            'values':numeric(row.get('values'),PROGRESS_KEYS)}


def clean_waits(row):
    if not valid_snapshot(row): return None
    waits=row.get('waits',{})
    if not isinstance(waits,dict): return None
    stages=waits.get('stages',{})
    if not isinstance(stages,dict): stages={}
    return {'version':1,'helper_pid':row['helper_pid'],'updated_at':row['updated_at'],
            'stages':{k:numeric(v,STAGE_KEYS) for k,v in stages.items() if k in STAGES},
            'responses':numeric(waits.get('responses'),RESPONSES)}


def timestamp(value):
    try:
        if not isinstance(value,str) or len(value)>40: return None
        return dt.datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
    except (ValueError,OverflowError): return None


class WindowTail:
    """At most two 192 KiB tails every ten seconds, independent of queue size."""
    def __init__(self): self.latest=None; self.next_read=0
    def read(self, directory, now):
        if now < self.next_read: return self.latest
        self.next_read=now+10
        try:
            files=[]
            for entry in os.scandir(directory):
                if LOG_NAME.fullmatch(entry.name) and entry.is_file(follow_symlinks=False):
                    files.append((entry.stat(follow_symlinks=False).st_mtime,entry.path))
            for _,path in sorted(files)[-2:]:
                for line in (read_bounded(path,196608,tail=True) or b'').splitlines():
                    try: row=json.loads(line)
                    except (ValueError,UnicodeError): continue
                    if not isinstance(row,dict) or row.get('event')!='download_window': continue
                    at=timestamp(row.get('timestamp'))
                    if at is not None and (self.latest is None or at>self.latest['updated_at']):
                        self.latest={'updated_at':at,'values':numeric(row.get('values'),WINDOW_KEYS)}
        except OSError: pass
        return self.latest


class MacCounters:
    """Physical destination-disk IOKit statistics and host CPU/VM counters."""
    def __init__(self, destination):
        self.destination=destination; self.previous_cpu=None; self.system={}; self.system_at=0
        self.io=C.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
        self.cf=C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.lib=C.CDLL('/usr/lib/libSystem.B.dylib')
        def bind(lib,name,restype,args):
            f=getattr(lib,name);f.restype=restype;f.argtypes=args;return f
        u=C.c_uint32; p=C.c_void_p
        bind(self.io,'IOServiceMatching',p,[C.c_char_p])
        bind(self.io,'IOBSDNameMatching',p,[u,u,C.c_char_p])
        bind(self.io,'IOServiceGetMatchingService',u,[u,p])
        bind(self.io,'IOServiceGetMatchingServices',C.c_int,[u,p,C.POINTER(u)])
        bind(self.io,'IOIteratorNext',u,[u]);bind(self.io,'IOObjectRelease',C.c_int,[u])
        bind(self.io,'IOObjectConformsTo',C.c_ubyte,[u,C.c_char_p])
        bind(self.io,'IORegistryEntryGetParentEntry',C.c_int,[u,C.c_char_p,C.POINTER(u)])
        bind(self.io,'IORegistryEntryGetRegistryEntryID',C.c_int,[u,C.POINTER(C.c_uint64)])
        bind(self.io,'IORegistryEntryCreateCFProperty',p,[u,p,p,u])
        bind(self.cf,'CFStringCreateWithCString',p,[p,C.c_char_p,u])
        bind(self.cf,'CFPropertyListCreateData',p,[p,p,C.c_long,C.c_ulong,p])
        bind(self.cf,'CFDataGetLength',C.c_long,[p]);bind(self.cf,'CFDataGetBytePtr',p,[p])
        bind(self.cf,'CFRelease',None,[p])
        bind(self.lib,'mach_host_self',u,[])
        bind(self.lib,'host_statistics',C.c_int,[u,C.c_int,C.POINTER(u),C.POINTER(u)])
        bind(self.lib,'mach_port_deallocate',C.c_int,[u,u])
        bind(self.lib,'sysctlbyname',C.c_int,[C.c_char_p,p,C.POINTER(C.c_size_t),p,C.c_size_t])
        self.total=C.c_uint64(); n=C.c_size_t(8)
        self.lib.sysctlbyname(b'hw.memsize',C.byref(self.total),C.byref(n),None,0)

    def identity(self, entry):
        value=C.c_uint64()
        return value.value if self.io.IORegistryEntryGetRegistryEntryID(entry,C.byref(value))==0 else None

    def destination_id(self):
        # stat/df only query the mount; never enumerate the destination's children.
        if not os.path.isdir(self.destination): return None
        try:
            result=subprocess.run(['/bin/df','-P',self.destination],capture_output=True,timeout=2)
            device=result.stdout.splitlines()[-1].split()[0].decode('ascii')
        except (OSError,subprocess.SubprocessError,IndexError,UnicodeError): return None
        if not re.fullmatch(r'/dev/disk[0-9]+(?:s[0-9]+)*',device): return None
        entry=self.io.IOServiceGetMatchingService(0,self.io.IOBSDNameMatching(0,0,device[5:].encode()))
        try:
            for _ in range(64):
                if not entry: return None
                if self.io.IOObjectConformsTo(entry,b'IOBlockStorageDevice'): return self.identity(entry)
                parent=C.c_uint32()
                if self.io.IORegistryEntryGetParentEntry(entry,b'IOService',C.byref(parent))!=0: return None
                self.io.IOObjectRelease(entry);entry=parent.value
        finally:
            if entry: self.io.IOObjectRelease(entry)

    def statistics(self, entry):
        key=self.cf.CFStringCreateWithCString(None,b'Statistics',0x08000100)
        prop=self.io.IORegistryEntryCreateCFProperty(entry,key,None,0); self.cf.CFRelease(key)
        if not prop: return {}
        data=None
        try:
            data=self.cf.CFPropertyListCreateData(None,prop,100,0,None)
            if not data: return {}
            length=self.cf.CFDataGetLength(data)
            return plistlib.loads(C.string_at(self.cf.CFDataGetBytePtr(data),length)) if 0<length<65536 else {}
        finally:
            if data: self.cf.CFRelease(data)
            self.cf.CFRelease(prop)

    def disk(self):
        destination=self.destination_id()
        if destination is None: return None
        iterator=C.c_uint32()
        if self.io.IOServiceGetMatchingServices(0,self.io.IOServiceMatching(b'IOBlockStorageDriver'),C.byref(iterator))!=0: return None
        try:
            while True:
                driver=self.io.IOIteratorNext(iterator.value)
                if not driver: return None
                parent=C.c_uint32()
                try:
                    if self.io.IORegistryEntryGetParentEntry(driver,b'IOService',C.byref(parent))!=0: continue
                    if self.identity(parent.value)!=destination: continue
                    values=self.statistics(driver)
                    return numeric({'identity':self.identity(driver),'read_bytes':values.get('Bytes (Read)'),
                                    'written_bytes':values.get('Bytes (Write)')},DISK_KEYS)
                finally:
                    if parent.value: self.io.IOObjectRelease(parent.value)
                    self.io.IOObjectRelease(driver)
        finally: self.io.IOObjectRelease(iterator.value)

    def host(self, now):
        if now-self.system_at<4: return self.system
        self.system_at=now
        ticks=(C.c_uint32*4)(); count=C.c_uint32(4); host=self.lib.mach_host_self()
        if self.lib.host_statistics(host,3,ticks,C.byref(count))==0:
            current=list(ticks)
            if self.previous_cpu:
                delta=[(a-b) % 2**32 for a,b in zip(current,self.previous_cpu)]
                if sum(delta): self.system['cpu_percent']=100*(sum(delta)-delta[2])/sum(delta)
            self.previous_cpu=current
        self.lib.mach_port_deallocate(C.c_uint32.in_dll(self.lib,'mach_task_self_').value,host)
        try:
            output=subprocess.run(['/usr/bin/vm_stat'],capture_output=True,text=True,timeout=2).stdout
            page=int(re.search(r'page size of (\d+) bytes',output)[1])
            values={k:int(v) for k,v in re.findall(r'^([^:\n]+):\s+(\d+)\.',output,re.M)}
            available=sum(values.get(k,0) for k in ['Pages free','Pages inactive','Pages speculative'])*page
            self.system.update(ram_total_bytes=self.total.value,ram_available_bytes=available,
                               ram_used_bytes=max(0,self.total.value-available))
        except (OSError,subprocess.SubprocessError,TypeError,ValueError): pass
        self.system.update(zip(['load_1m','load_5m','load_15m'],os.getloadavg()))
        return numeric(self.system,SYSTEM_KEYS)


def sanitize_packet(row):
    if not isinstance(row,dict) or type(row.get('version')) is not int or row['version']!=1: return None
    basic=numeric(row,{'sent_at','collector_uptime'})
    if len(basic)!=2: return None
    result={'version':1,**basic,'live':clean_live(row.get('live')),'state':clean_state(row.get('state')),
            'system':numeric(row.get('system'),SYSTEM_KEYS),'disk':numeric(row.get('disk'),DISK_KEYS)}
    waits=row.get('waits')
    # Collector packets already have flattened waits; reconstruct their fixed schema.
    if isinstance(waits,dict):
        waits={**waits,'waits':{'stages':waits.get('stages'),'responses':waits.get('responses')}}
    result['waits']=clean_waits(waits)
    window=row.get('window')
    result['window']=None
    if isinstance(window,dict):
        at=numeric(window,{'updated_at'})
        if at: result['window']={**at,'values':numeric(window.get('values'),WINDOW_KEYS)}
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interval',type=float,default=2)
    parser.add_argument('--destination',default='/Volumes/G-DRIVE')
    args=parser.parse_args()
    if not 1<=args.interval<=60: parser.error('interval must be between 1 and 60 seconds')
    logs=Path.home()/'Library/Logs/MyCloudDriver/Downloads'; tail=WindowTail()
    try: counters=MacCounters(args.destination)
    except (OSError,AttributeError): counters=None
    try:
        while True:
            started=time.monotonic()
            row={'version':1,'sent_at':time.time(),'collector_uptime':started,
                 'live':clean_live(read_json(logs/'live-speed-v1.json',512)),
                 'state':clean_state(read_json(logs/'monitor-state-v1.json',16384)),
                 'waits':clean_waits(read_json(logs/'setup-waits-v1.json',65536)),
                 'window':tail.read(logs,started),'system':{},'disk':None}
            if counters:
                try: row['system']=counters.host(started);row['disk']=counters.disk()
                except (OSError,ValueError,AttributeError): pass
            print(json.dumps(row,separators=(',',':'),allow_nan=False),flush=True)
            time.sleep(max(0,args.interval-(time.monotonic()-started)))
    except (KeyboardInterrupt,BrokenPipeError): pass


if __name__=='__main__': main()
