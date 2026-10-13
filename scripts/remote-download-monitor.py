#!/usr/bin/env python3
"""A private, macmon-style terminal dashboard for MyCloudDriver on a remote Mac."""
import argparse
import base64
import collections
import curses
import datetime as dt
import fcntl
import gzip
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid

HERE=Path(__file__).resolve().parent
def module(name, file):
    spec=importlib.util.spec_from_file_location(name,HERE/file)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
COLLECT=module('remote_download_collector','remote-download-collector.py')
SPEED=module('remote_download_speed','monitor-download-speed.py')
LOG_NAME=re.compile(r'monitor-\d{8}T\d{6}Z-[a-f0-9]{12}\.jsonl(?:\.gz)?\Z')


def amount(value, decimal=False):
    if value is None: return '--'
    units=['B','KB','MB','GB','TB'] if decimal else ['B','KiB','MiB','GiB','TiB']
    base=1000 if decimal else 1024
    for unit in units:
        if abs(value)<base or unit==units[-1]: return ('%.1f %s' % (value,unit)) if unit!='B' else '%d B'%value
        value/=base

def duration(value):
    if value is None: return '--'
    value=int(max(0,value))
    if value<60: return '%ds'%value
    if value<3600: return '%dm %02ds'%divmod(value,60)
    return '%dh %02dm'%(value//3600,value//60%60)

def number(value): return '--' if value is None else format(int(value),',')
def completion(at, seconds):
    if seconds is None: return '--'
    try:return dt.datetime.fromtimestamp(at+seconds).strftime('%b %d %H:%M')
    except (ValueError,OverflowError,OSError):return '--'
def rate(value, disk=False):
    return '--' if value is None else '%.2f %s/s'%(value/(1048576 if disk else 1e6),'MiB' if disk else 'MB')
def gauge(value, limit, width):
    if value is None or not limit: return '['+'?'*max(1,width-2)+']'
    count=round(max(0,min(1,value/limit))*max(1,width-2))
    return '['+'='*count+' '*(max(1,width-2)-count)+']'


class CounterRate:
    def __init__(self): self.old=None
    def sample(self, disk, at):
        if not disk or set(disk)!={'identity','read_bytes','written_bytes'}:
            self.old=None;return None,None
        old=self.old;self.old=(disk,at)
        if not old or disk['identity']!=old[0]['identity'] or not 0<at-old[1]<=10: return None,None
        delta=[disk[k]-old[0][k] for k in ('read_bytes','written_bytes')]
        if min(delta)<0: return None,None
        return tuple(v/(at-old[1]) for v in delta)


class Dashboard:
    def __init__(self):
        self.rates=SPEED.LiveRates();self.disk=CounterRate();self.history=collections.deque(maxlen=3600)
        self.latest=None;self.received=0;self.last_pid=None;self.latest_at=0
        self.total_delta=0;self.total_seconds=0;self.low_seconds=0;self.restart_count=0
        self.average=None

    def update(self, packet):
        row=COLLECT.sanitize_packet(packet)
        if row is None: return None
        now=row['sent_at']; live=row['live'];self.received=time.monotonic()
        rates=self.rates.sample(live,now)
        current=average=None
        if rates:
            current=rates[0];average=rates[1] if self.rates.window_ready else None
        state=row['state'];window=row['window'];waits=row['waits']
        valid_live=live and -1<=now-live['updated_at']<=5
        pid=live['helper_pid'] if valid_live else None
        restarted=pid is not None and self.last_pid is not None and pid!=self.last_pid
        if restarted: self.restart_count+=1
        if pid: self.last_pid=pid
        values={};source_age=None
        if window and -1<=now-window['updated_at']<=30:
            values.update(window['values']);source_age=now-window['updated_at']
        if state and state['helper_pid']==pid and -1<=now-state['updated_at']<=5:
            values.update(state['values']);source_age=now-state['updated_at']
        else: state=None
        if not waits or waits['helper_pid']!=pid or not -1<=now-waits['updated_at']<=5: waits=None
        read,write=self.disk.sample(row['disk'],row['collector_uptime'])
        if not valid_live: current=average=None;values={};source_age=None;waits=None
        if self.latest and valid_live and self.latest.get('helper_pid')==pid and not restarted:
            old=self.latest.get('live');elapsed=live['sampled_uptime']-old['sampled_uptime'] if old else 0
            if old and 0<elapsed<=5 and live['received_bytes']>=old['received_bytes']:
                self.total_delta+=live['received_bytes']-old['received_bytes'];self.total_seconds+=elapsed
                if average is not None and average<10e6: self.low_seconds+=elapsed
        self.average=self.total_delta/self.total_seconds if self.total_seconds else None
        result={**row,'helper_pid':pid,'current_bytes_per_second':current,'five_second_bytes_per_second':average,
                'disk_read_bytes_per_second':read,'disk_write_bytes_per_second':write,'values':values,
                'metric_age_seconds':source_age,'progress_available':state is not None,
                'waits':waits,'monitor_average_bytes_per_second':self.average,
                'low_speed_seconds':self.low_seconds,'helper_restarts':self.restart_count,
                'status':'live' if valid_live else 'app_unavailable'}
        self.history.append((now,average,read,write));self.latest=result;self.latest_at=time.monotonic()
        return result

    def view(self, force=False):
        row=self.latest
        if row is None: return None
        if not force and time.monotonic()-self.latest_at>6:
            return {**row,'status':'disconnected','values':{},'waits':None,
                    'current_bytes_per_second':None,'five_second_bytes_per_second':None,
                    'disk_read_bytes_per_second':None,'disk_write_bytes_per_second':None}
        return row


class HistoryLog:
    """8 MiB active JSONL; compressed archives, eight days / 512 MiB by default."""
    def __init__(self, directory, cap=512*1024**2, days=8, segment=8*1024**2):
        self.directory=Path(directory);self.cap=cap;self.days=days;self.segment=segment
        self.directory.mkdir(parents=True,exist_ok=True,mode=0o700)
        if self.directory.is_symlink(): raise OSError('Log directory must not be a symlink')
        self.directory.chmod(0o700);self.handle=None;self.path=None;self.size=0;self.error=False
        self.lock_fd=os.open(self.directory/'.monitor.lock',os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
        try: fcntl.flock(self.lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock_fd);raise OSError('A monitor is already logging here; use --no-log or a different --log-dir')
        # Finish archives left by a previous interrupted monitor, using only our private log names.
        for path in self.files():
            if path.suffix=='.jsonl': self.compress(path)
        self.prune()

    def files(self):
        return sorted((p for p in self.directory.iterdir() if LOG_NAME.fullmatch(p.name)
                       and p.is_file() and not p.is_symlink()),key=lambda p:p.name)

    def compress(self, path):
        target=path.with_suffix(path.suffix+'.gz');temporary=target.with_suffix('.gz.tmp')
        fd=os.open(temporary,os.O_CREAT|os.O_WRONLY|os.O_TRUNC|getattr(os,'O_NOFOLLOW',0),0o600)
        try:
            with os.fdopen(fd,'wb') as out, path.open('rb') as source:
                with gzip.GzipFile(filename='',mode='wb',fileobj=out,mtime=0) as zipped:
                    shutil.copyfileobj(source,zipped,1024*1024)
            temporary.replace(target);path.unlink()
        except BaseException:
            temporary.unlink(missing_ok=True);raise

    def prune(self):
        files=self.files();cutoff=time.time()-self.days*86400
        for path in files:
            stamped=dt.datetime.strptime(path.name[8:24],'%Y%m%dT%H%M%SZ').replace(tzinfo=dt.timezone.utc).timestamp()
            if path!=self.path and stamped<cutoff: path.unlink()
        files=self.files();total=sum(p.stat().st_size for p in files)
        budget=self.cap-self.segment if self.handle is not None else self.cap
        for path in files:
            if total<=budget: break
            if path==self.path: continue
            size=path.stat().st_size;path.unlink();total-=size

    def write(self, packet):
        # Sanitize again at the persistence boundary; never save arbitrary remote text.
        clean=COLLECT.sanitize_packet(packet)
        if clean is None: return
        data=(json.dumps(clean,separators=(',',':'),allow_nan=False)+'\n').encode()
        if len(data)>65536: raise OSError('Numeric sample exceeds the log record cap')
        if self.handle is None or self.size+len(data)>self.segment:
            if self.handle:
                self.handle.close();self.handle=None;self.compress(self.path)
            self.path=self.directory/('monitor-'+dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:12]+'.jsonl')
            self.handle=os.fdopen(os.open(self.path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'wb')
            self.size=0;self.prune()
        self.handle.write(data);self.handle.flush();self.size+=len(data)

    def close(self):
        try:
            if self.handle:
                self.handle.close();self.handle=None;self.compress(self.path);self.path=None;self.prune()
        finally: os.close(self.lock_fd)


class Stream:
    def __init__(self,args):
        source=(HERE/'remote-download-collector.py').read_bytes()
        encoded=base64.b64encode(source).decode()
        code="import base64;exec(compile(base64.b64decode(%r),'remote-download-collector','exec'))"%encoded
        remote=['/usr/bin/python3','-u','-c',code,'--interval',str(args.interval),'--destination',args.destination]
        command=remote if args.local else ['ssh','-T','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3',
                  '-o','ConnectTimeout=10','-o','NumberOfPasswordPrompts=1',args.host,shlex.join(remote)]
        self.process=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE)
        self.pending=collections.deque(maxlen=4);self.lock=threading.Lock()
        self.thread=threading.Thread(target=self.read,daemon=True);self.thread.start()

    def read(self):
        while True:
            line=self.process.stdout.readline(131073)
            if not line: return
            if len(line)>131072: continue
            try: row=COLLECT.sanitize_packet(json.loads(line))
            except (ValueError,UnicodeError): continue
            if row:
                with self.lock: self.pending.append(row)

    def next(self):
        with self.lock:
            if not self.pending: return None
            return self.pending.popleft()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired: self.process.kill();self.process.wait()
        self.process.stdout.close()


def demo_packet(index, started):
    now=started+index*2;uptime=index*2;speed=55e6+12e6*math.sin(index/5)
    used=(0.25+0.48*(1+math.sin(index/12))/2)*8*1024**3;reading=index%45<25
    values={k:0 for k in COLLECT.PROGRESS_KEYS}
    values.update(build=268,downloaded_bytes=210e9+index*110e6,total_bytes=6.46e12,
                  remaining_bytes=6.25e12-index*110e6,fraction=0.033,estimated=1,total_files=19336,
                  completed_files=423,active_files=480,queued_downloads=15000,totals_incomplete=1,is_downloading=1,
                  app_bytes_per_second=speed,overall_bytes_per_second=50e6,eta_seconds=6.25e12/speed,
                  chart_eta_seconds=6.25e12/50e6,ram_buffered_bytes=used,
                  ram_peak_bytes=6.9*1024**3,ram_limit_bytes=8*1024**3,ram_memory_pressure=1,
                  pending_read_bytes=154.1*1024**3,reading_bytes=3.4*1024**3 if reading else 0,
                  pending_read_tasks=331,reading_tasks=7 if reading else 0,read_drives=int(reading),write_drives=int(not reading),
                  oldest_pending_read_ms=119000,pending_write_bytes=used if reading else used*.3,
                  writing_bytes=0 if reading else used*.7,writing_tasks=0 if reading else 12,
                  active_read_tasks=int(reading),active_write_tasks=int(not reading),turn_elapsed_ms=(index%25)*2000,
                  read_write_threshold_percent=80,receiving_tasks=15,file_network_workers=15,file_worker_limit=16,
                  read_tasks_finished=200+index,ready_read_tasks=4)
    return {'version':1,'sent_at':now,'collector_uptime':uptime,'live':{'version':1,'helper_pid':42,
            'received_bytes':int(index*2*55e6),'sampled_uptime':uptime,'updated_at':now},
            'state':{'version':1,'helper_pid':42,'updated_at':now,'values':values},'window':None,
            'waits':{'version':1,'helper_pid':42,'updated_at':now,'stages':{'guest_headers':{'count':55,
            'active':2,'oldest_ms':250,'total_ms':4500,'max_ms':600}},'responses':{'guest_success':1000}},
            'system':{'cpu_percent':24,'ram_total_bytes':16*1024**3,'ram_used_bytes':11*1024**3,'load_1m':2.3},
            'disk':{'identity':22,'read_bytes':int(index*2*125e6),'written_bytes':int(index*2*80e6)}}


def text_line(row):
    v=row['values'];when=dt.datetime.fromtimestamp(row['sent_at']).strftime('%H:%M:%S')
    return ('%s %-15s DL5s %s | disk R %s W %s | RAM %s/%s | %s turn | read pending %s, selected %s | '
            'write pending %s, selected %s | I/O %sR %sW | oldest %s') % (
        when,row['status'],rate(row['five_second_bytes_per_second']),rate(row['disk_read_bytes_per_second'],True),
        rate(row['disk_write_bytes_per_second'],True),amount(v.get('ram_buffered_bytes')),amount(v.get('ram_limit_bytes')),
        'read' if v.get('read_drives',0)>0 else 'write' if v.get('write_drives',0)>0 else '--',amount(v.get('pending_read_bytes')),amount(v.get('reading_bytes')),
        amount(v.get('pending_write_bytes')),amount(v.get('writing_bytes')),number(v.get('active_read_tasks')),
        number(v.get('active_write_tasks')),duration(v.get('oldest_pending_read_ms',0)/1000) if v else '--')


def graph_points(history, key, width, height, maximum, seconds):
    points=[None]*width
    if not history: return points
    end=history[-1][0];begin=end-seconds
    for row in history:
        if row[0]<begin: continue
        col=min(width-1,max(0,int((row[0]-begin)/seconds*(width-1))))
        value=row[key]
        points[col]=None if value is None else min(height-1,max(0,round(value/maximum*(height-1))))
    return points


def paint(screen, model, args, logger, logging_failed=False, replay=False):
    screen.erase();height,width=screen.getmaxyx();row=model.view(force=replay);v=row['values'] if row else {}
    def put(y,x,text,color=0):
        if 0<=y<height and 0<=x<width:
            try: screen.addnstr(y,x,str(text),max(0,width-x-1),curses.color_pair(color))
            except curses.error: pass
    def panel(y,x,w,h,title,lines,color=0):
        put(y,x,'+'+'-'*(w-2)+'+',color);put(y,x+2,' '+title+' ',color)
        for line in range(1,h-1):
            put(y+line,x,'|',color);put(y+line,x+w-1,'|',color)
            if line-1<len(lines):put(y+line,x+2,lines[line-1][:w-4])
        put(y+h-1,x,'+'+'-'*(w-2)+'+',color)
    def graphs(top,graphh):
        left=1;graphw=width-9;spark='▁▂▃▄▅▆▇█'
        for title,key,field,maximum,color in [
                ('DOWNLOAD',1,'current_bytes_per_second',100e6,1),
                ('READ',2,'disk_read_bytes_per_second',260*1048576,3),
                ('WRITE',3,'disk_write_bytes_per_second',260*1048576,2)]:
            live=row.get(field) if row else None
            history=duration(args.history)+' history'+(' (5s average)' if key==1 else '')
            put(top,left,title+' '+rate(live,key!=1)+' | '+history,color)
            graphy=top+1;levels=len(spark) if graphh==1 else graphh
            points=graph_points(model.history,key,graphw,levels,maximum,args.history)
            for y in range(graphh):
                scale=100 if key==1 else 260
                axis='%3d |'%round(scale*(graphh-1-y)/(graphh-1)) if graphh>1 else '    |'
                put(graphy+y,left,axis)
                for x,value in enumerate(points):
                    if value is not None:
                        if graphh==1:put(graphy,left+x+6,spark[value],color)
                        elif value>=graphh-1-y:put(graphy+y,left+x+6,'|' if value==graphh-1-y else '.',color)
            if model.history:
                end=model.history[-1][0]
                for sample in model.history:
                    at,value=sample[0],sample[key]
                    if at>=end-args.history and value is not None and value>maximum:
                        pos=min(graphw-1,max(0,int((at-(end-args.history))/args.history*(graphw-1))))
                        put(graphy,left+pos+6,'^',4)
            top=graphy+graphh
        return top
    status=row['status'] if row else 'connecting'
    clock=dt.datetime.fromtimestamp(row['sent_at']).strftime('%Y-%m-%d %H:%M:%S') if row else ''
    put(0,1,'MyCloudDriver  |  '+('DEMO (synthetic)' if args.demo else args.host)+'  |  '+status.upper(),1)
    put(0,max(1,width-22),clock,1)
    if 24<=height<30 and width>=70 or height>=24 and 70<=width<88:
        speed=row.get('five_second_bytes_per_second') if row else None
        percentage=('~' if v.get('estimated') else '')+('%.1f%%'%(v['fraction']*100) if 'fraction' in v else '--')
        put(2,1,'DL '+rate(speed)+' 5s | Progress '+percentage+' | App avg '+rate(v.get('overall_bytes_per_second')),1)
        put(3,1,amount(v.get('downloaded_bytes'),True)+' / '+amount(v.get('total_bytes'),True)+' | Left '+amount(v.get('remaining_bytes'),True)+' | ETA '+duration(v.get('eta_seconds')))
        put(4,1,'Files '+number(v.get('completed_files'))+'/'+number(v.get('total_files'))+' skip '+number(v.get('skipped_files'))+' | Active '+number(v.get('active_files'))+' queue '+number(v.get('queued_downloads'))+' retry '+number(v.get('retrying_files')))
        system=row.get('system',{}) if row else {}
        put(5,1,'RAM '+amount(v.get('ram_buffered_bytes'))+'/'+amount(v.get('ram_limit_bytes'))+' peak '+amount(v.get('ram_peak_bytes'))+' | System '+amount(system.get('ram_used_bytes'))+'/'+amount(system.get('ram_total_bytes')),2)
        put(6,1,gauge(v.get('ram_buffered_bytes'),v.get('ram_limit_bytes'),width-3),2)
        turn='READ' if v.get('read_drives',0) else 'WRITE' if v.get('write_drives',0) else '--'
        put(7,1,turn+' TURN '+duration(v.get('turn_elapsed_ms',0)/1000)+' | I/O '+number(v.get('active_read_tasks'))+'R/'+number(v.get('active_write_tasks'))+'W | oldest read '+duration(v.get('oldest_pending_read_ms',0)/1000))
        pw=(width-5)//4
        for i,(label,key,count) in enumerate([('PENDING READ','pending_read_bytes','pending_read_tasks'),('READING','reading_bytes','reading_tasks'),('PENDING WRITE','pending_write_bytes',None),('WRITING','writing_bytes','writing_tasks')]):
            detail=number(v.get(count))+(' waiting' if i==0 else ' selected') if count else 'Received in RAM'
            panel(8,1+i*(pw+1),pw,5,label,[amount(v.get(key)),detail,''],3 if i<2 else 1)
        put(13,1,'Disk R '+rate(row.get('disk_read_bytes_per_second') if row else None,True)+' W '+rate(row.get('disk_write_bytes_per_second') if row else None,True)+' | RAM wait '+number(v.get('ram_waiting_receivers')))
        bottom=graphs(14,max(1,min(9,(height-18)//3-1)))
        waits=(row.get('waits') or {}).get('stages',{}) if row else {}
        busy=sorted(((k,val) for k,val in waits.items() if val.get('active',0)),key=lambda x:x[1].get('oldest_ms',0),reverse=True)
        trace=' | '.join('%s %s (%s)'%(k,number(val.get('active')),duration(val.get('oldest_ms',0)/1000)) for k,val in busy[:2]) or 'none / unavailable'
        put(bottom,1,'Waits '+trace)
        put(bottom+1,1,'Monitor avg '+rate(model.average)+' | <10 MB/s '+duration(model.low_seconds)+' | workers '+number(v.get('file_network_workers'))+'/'+number(v.get('file_worker_limit')))
        if bottom+1<height-3:put(height-3,1,'Larger window shows full details | '+status+' | unknown --, graph gaps unavailable')
        put(height-2,1,'Logs '+('ERROR' if logging_failed else str(logger.directory) if logger else 'OFF'))
        put(height-1,1,'q quit | Ctrl-C exits | graphs '+duration(args.history)+' | physical disk includes all apps')
        screen.refresh();return
    if height<30 or width<88:
        put(2,1,'Enlarge Terminal to 80 x 24 (compact), or 140 x 36 (full details).')
        if row:
            for i,line in enumerate(text_line(row).split(' | ')):put(4+i,1,line)
        put(height-1,1,'q quit | log '+('OFF' if not logger else 'ON'));screen.refresh();return
    speed=row['five_second_bytes_per_second'] if row else None
    total=v.get('total_bytes');progress=v.get('fraction')
    estimated='~' if v.get('estimated') else ''
    progress_text='Progress: '+(estimated+'%.1f%%'%(progress*100) if progress is not None else '-- (not exported)')
    end_time=''
    if row and v.get('eta_seconds') is not None:
        end_time='  End '+completion(row['sent_at'],v['eta_seconds'])
    download=[rate(speed)+'  5s average   |   latest '+rate(row.get('current_bytes_per_second') if row else None),
              progress_text+'   '+amount(v.get('downloaded_bytes'),True)+' / '+estimated+amount(total,True),
              'Files: '+number(v.get('completed_files'))+' done / '+number(v.get('total_files'))+' discovered; '+number(v.get('skipped_files'))+' skipped',
              'Left: '+estimated+amount(v.get('remaining_bytes'),True)+'   ETA '+duration(v.get('eta_seconds'))+end_time,
              'Active '+number(v.get('active_files'))+'  Queue '+number(v.get('queued_downloads'))+'  Retry '+number(v.get('retrying_files'))+'  Failed '+number(v.get('failed_files'))]
    ramused=v.get('ram_buffered_bytes');ramlimit=v.get('ram_limit_bytes')
    ram_status=('reception paused' if v.get('reception_paused') else 'memory pressure' if v.get('ram_memory_pressure',0)>=2
                else 'ahead of disk' if ramused else 'ready' if ramused is not None else '--')
    sysvalues=row.get('system',{}) if row else {}
    ram=[amount(ramused)+' / '+amount(ramlimit)+'    Peak '+amount(v.get('ram_peak_bytes')),
         gauge(ramused,ramlimit,max(10,(width-4)//2-5)),
         'RAM-blocked receivers '+number(v.get('ram_waiting_receivers'))+'  |  receiving '+number(v.get('receiving_tasks')),
         'System RAM (est): '+amount(sysvalues.get('ram_used_bytes'))+' / '+amount(sysvalues.get('ram_total_bytes')),
         'CPU '+('%.1f%%'%sysvalues['cpu_percent'] if 'cpu_percent' in sysvalues else '--')+'   Load '+('%.2f'%sysvalues['load_1m'] if 'load_1m' in sysvalues else '--')]
    w1=(width-3)//2;w2=width-w1-3
    panel(2,1,w1,7,' DOWNLOAD ',download,1);panel(2,w1+2,w2,7,' RAM BUFFER | '+ram_status,ram,4 if v.get('ram_memory_pressure',0)>=2 else 2)
    read=v.get('read_drives',0)>0;write=v.get('write_drives',0)>0
    phase='READ + WRITE' if read and write else 'READ' if read else 'WRITE' if write else '--'
    policy=('switch above '+number(v.get('read_write_threshold_percent'))+'% pending writes' if read else 'drain selected writes')
    put(9,2,'DISK '+phase+' TURN   '+duration(v.get('turn_elapsed_ms',0)/1000)+'   |   '+policy,3 if read else 1)
    put(9,max(2,width-34),'Handover wait '+duration(v.get('switch_wait_ms',0)/1000))
    poolw=(width-5)//4
    pools=[('PENDING READ','pending_read_bytes',number(v.get('pending_read_tasks'))+' checks waiting',3),
           ('READING','reading_bytes',number(v.get('reading_tasks'))+' checks selected',3),
           ('PENDING WRITE','pending_write_bytes','Received, waiting for disk',1),
           ('WRITING','writing_bytes',number(v.get('writing_tasks'))+' transfers selected',1)]
    for i,(title,key,subtitle,color) in enumerate(pools):
        panel(10,1+i*(poolw+1),poolw,5,title,[amount(v.get(key)),subtitle,''],color)
    put(15,2,'Physical disk read '+rate(row.get('disk_read_bytes_per_second') if row else None,True)+'   write '+rate(row.get('disk_write_bytes_per_second') if row else None,True))
    put(16,2,'Disk I/O '+number(v.get('active_read_tasks'))+' reading / '+number(v.get('active_write_tasks'))+' writing  |  oldest read '+duration(v.get('oldest_pending_read_ms',0)/1000)+'  |  ready '+number(v.get('ready_read_tasks'))+'  |  finished '+number(v.get('read_tasks_finished')))
    bottom=graphs(17,max(1,min(9,(height-24)//3-1)))
    waits=row.get('waits') if row else None
    busy=sorted(((name,m) for name,m in (waits or {}).get('stages',{}).items() if m.get('active',0)),key=lambda x:x[1].get('oldest_ms',0),reverse=True)
    desc=' | '.join('%s %s (%s)'%(name,number(m.get('active')),duration(m.get('oldest_ms',0)/1000)) for name,m in busy[:3]) or ('No active setup waits' if waits else 'Setup diagnostics unavailable')
    put(bottom+1,2,'WAIT TRACE  '+desc,4 if speed is not None and speed<10e6 else 0)
    if row:put(bottom+2,2,'App avg '+rate(v.get('overall_bytes_per_second'))+'  |  monitor avg '+rate(model.average)+'  |  <10 MB/s '+duration(model.low_seconds)+'  |  workers '+number(v.get('file_network_workers'))+'/'+number(v.get('file_worker_limit')))
    if row and height>=31 and v.get('chart_eta_seconds') is not None:
        end=completion(row['sent_at'],v['chart_eta_seconds'])
        put(height-4,2,'App chart ETA '+duration(v['chart_eta_seconds'])+'  |  estimated completion '+end+'  |  metrics age '+duration(row.get('metric_age_seconds')))
    note='Selected pools include queued work; Disk I/O counts show actual active operations.'
    if status=='disconnected':note='SSH data is stale. Rates are unavailable; no false zero is recorded. Press q and rerun to reconnect.'
    elif status=='app_unavailable':note='Waiting for a fresh app snapshot. The app may be stopped; this is not a measured zero download rate.'
    elif row and not row['progress_available']:note='Progress/ETA need the numeric monitor snapshot; existing buffer/queue diagnostics update about every 10s.'
    put(height-3,2,note,4 if status!='live' else 0)
    put(height-2,2,'q quit  |  '+('LOG ERROR (downloads continue)' if logging_failed else 'logs: '+str(logger.directory) if logger else 'logging OFF'),4 if logging_failed else 0)
    put(height-1,2,'Cloud MB/s | disk MiB/s (all apps) | -- unknown, graph gaps unavailable, ^ clipped | Ctrl-C exits')
    screen.refresh()


def replay_rows(paths):
    for path in paths:
        path=Path(path).expanduser()
        opener=gzip.open if path.suffix=='.gz' else open
        with opener(path,'rb') as source:
            while True:
                line=source.readline(131073)
                if not line: break
                if len(line)>131072: raise ValueError('Log line exceeds the numeric record limit')
                try: packet=COLLECT.sanitize_packet(json.loads(line))
                except (ValueError,UnicodeError): continue
                if packet: yield packet


def summary(paths):
    model=Dashboard();valid=0;minimum=None;maximum=None;lows=[];first=last=None
    for packet in replay_rows(paths):
        row=model.update(packet);at=row['sent_at'];first=at if first is None else first;last=at
        speed=row['five_second_bytes_per_second']
        if speed is not None:
            valid+=1;minimum=speed if minimum is None else min(minimum,speed);maximum=speed if maximum is None else max(maximum,speed)
            if speed<10e6:
                waits=(row.get('waits') or {}).get('stages',{})
                busy=sorted((k for k,v in waits.items() if v.get('active',0)),key=lambda k:waits[k].get('oldest_ms',0),reverse=True)
                v=row['values'];phase='read' if v.get('read_drives',0) else 'write' if v.get('write_drives',0) else 'unknown'
                line='%s %s turn=%s ram_waiters=%s disk_R=%s disk_W=%s waits=%s' % (
                    dt.datetime.fromtimestamp(at).isoformat(timespec='seconds'),rate(speed),phase,number(v.get('ram_waiting_receivers')),
                    rate(row['disk_read_bytes_per_second'],True),rate(row['disk_write_bytes_per_second'],True),','.join(busy[:3]) or 'none')
                lows.append(line)
                if len(lows)>20:lows.pop(0)
    print('Duration %s | valid 5s rate samples %d | helper restarts %d'%(duration(last-first if last is not None else 0),valid,model.restart_count))
    print('Time-weighted observed download avg %s | min %s | max %s'%(rate(model.average),rate(minimum),rate(maximum)))
    print('Observed time below 10 MB/s: '+duration(model.low_seconds)+' (excludes missing data and warm-up)')
    if lows:print('Last 20 low-rate observations (evidence, not automatic cause attribution):\n'+'\n'.join(lows))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',default='fubao@192.168.50.228',help='SSH user@host; credentials are never saved')
    parser.add_argument('--destination',default='/Volumes/G-DRIVE',help='remote mount point; queries its device only')
    parser.add_argument('--interval',type=float,default=2,help='sampling seconds (1..4, default 2; preserves the 5s rate)')
    parser.add_argument('--duration',type=float,default=0,help='stop after N seconds (default: until q/Ctrl-C)')
    parser.add_argument('--history',type=int,default=300,help='graph seconds (default 300)')
    parser.add_argument('--log-dir',type=Path,help='private local log directory')
    parser.add_argument('--max-log-mib',type=int,default=512)
    parser.add_argument('--retention-days',type=int,default=8)
    parser.add_argument('--no-log',action='store_true')
    parser.add_argument('--plain',action='store_true',help='timestamped rows instead of the interactive dashboard')
    parser.add_argument('--demo',action='store_true',help='synthetic preview; does not connect or log')
    parser.add_argument('--local',action='store_true',help='monitor this Mac instead of SSH')
    parser.add_argument('--replay',nargs='+',metavar='LOG',help='replay local JSONL/gzip logs; no SSH')
    parser.add_argument('--summary',nargs='+',metavar='LOG',help='summarize local logs and low-speed evidence')
    args=parser.parse_args()
    if not 1<=args.interval<=4 or args.duration<0 or not 30<=args.history<=3600:parser.error('interval 1..4, duration >=0, history 30..3600 required')
    if args.max_log_mib<16 or args.retention_days<1:parser.error('log cap >=16 MiB and retention >=1 day required')
    if not re.fullmatch(r'(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9_.:-]*',args.host):parser.error('invalid SSH host')
    if args.summary:summary(args.summary);return 0
    os.umask(0o077)
    logger=None;stream=None;logging_failed=False
    directory=args.log_dir or Path.home()/'Library/Logs/MyCloudDriver/RemoteMonitor'/('local' if args.local else args.host.replace('@','_'))
    try:
        if not args.no_log and not args.demo and not args.replay:
            logger=HistoryLog(directory,cap=args.max_log_mib*1024**2,days=args.retention_days)
        if not args.demo and not args.replay:
            print('Connecting to '+('this Mac' if args.local else args.host)+'. Enter the SSH password if prompted.',file=sys.stderr,flush=True)
            stream=Stream(args)
            # Authenticate before entering curses so SSH prompts stay readable.
            first=None;deadline=time.monotonic()+90
            while first is None and stream.process.poll() is None and time.monotonic()<deadline:
                first=stream.next()
                if first is None:time.sleep(.1)
            if first is None:raise RuntimeError('SSH collector did not start; check authentication and remote Python 3')
        model=Dashboard();started=time.monotonic();demo_start=time.time();index=0
        replays=iter(replay_rows(args.replay)) if args.replay else None
        def run(screen=None):
            nonlocal index,logging_failed,first
            if screen is not None:
                curses.curs_set(0);screen.nodelay(True)
                if curses.has_colors():
                    curses.start_color();curses.use_default_colors()
                    for i,color in enumerate([curses.COLOR_CYAN,curses.COLOR_GREEN,curses.COLOR_MAGENTA,curses.COLOR_YELLOW],1):curses.init_pair(i,color,-1)
            next_demo=0;last_printed=None
            while not args.duration or time.monotonic()-started<args.duration:
                packet=None
                if args.demo and time.monotonic()>=next_demo:
                    packet=demo_packet(index,demo_start);index+=1;next_demo=time.monotonic()+.15
                elif replays and time.monotonic()>=next_demo:
                    packet=next(replays,None);next_demo=time.monotonic()+.15
                    if packet is None:break
                elif stream:
                    packet=first or stream.next();first=None
                if packet:
                    row=model.update(packet)
                    if logger and not logging_failed:
                        try:logger.write(packet)
                        except OSError:logging_failed=True
                    if screen is None and row and row['sent_at']!=last_printed:
                        print(text_line(row),flush=True);last_printed=row['sent_at']
                if screen is not None:
                    paint(screen,model,args,logger,logging_failed,replay=bool(replays) or args.demo)
                    if screen.getch() in (ord('q'),ord('Q'),3):break
                if stream and stream.process.poll() is not None and not stream.pending:
                    raise RuntimeError('SSH disconnected; collected history is saved. Rerun to reconnect')
                time.sleep(.1)
        first=first if stream else None
        if args.plain or not sys.stdout.isatty():run()
        else:curses.wrapper(run)
        if logger:print('Saved numeric history: '+str(directory),file=sys.stderr)
        return 0
    except KeyboardInterrupt:return 0
    except (OSError,RuntimeError,ValueError,EOFError) as error:
        print('Monitor: '+str(error),file=sys.stderr);return 1
    finally:
        if stream:stream.close()
        if logger:
            try:logger.close()
            except OSError:print('Monitor: log archive failed; the raw numeric JSONL remains available',file=sys.stderr)


if __name__=='__main__':sys.exit(main())
