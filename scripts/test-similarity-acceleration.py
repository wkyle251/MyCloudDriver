#!/usr/bin/env python3
"""Synthetic CPU/CoreML throughput, profile isolation and memory-queue checks."""
import argparse, importlib.util, json, os, sqlite3, subprocess, tempfile, time
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('resources', type=Path); p.add_argument('--output', type=Path); a=p.parse_args()
resources=a.resources.resolve()
spec=importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('test-similarity-native.py'))
f=importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
results=[]
with tempfile.TemporaryDirectory(prefix='mycloud-acceleration-') as d:
 root=Path(d).resolve(); inputs=root/'inputs'; inputs.mkdir()
 for i in range(12):
  path=inputs/f'image-{i}.png'; f.png(path,phase=(i//2)*35)
  # Change the encoded file hash without changing decoded pixels. This tests
  # model inference for every original, not exact-file duplicate short cuts.
  with path.open('ab') as out: out.write(bytes([i]))
 models=resources/'FileTwinModels'
 for mode in ['cpu','automatic','automatic']:
  n=len(results); data=root/('index-'+mode)
  # Retain model compilation between accelerated runs; remove vector reuse.
  for cache in data.glob('filetwin-vector*'): cache.unlink()
  request=dict(source='local',local_paths=[str(inputs)],cloud_items=[],families=['image'],threshold=.9,exact_duplicates=True,
   data_dir=str(data),model_dir=str(models),temp_dir=str(root/f'tmp-{n}'),report_path=str(root/f'report-{n}.json'),
   resources=dict(memory_scheduling=True,workers=1,memory_bytes=8*1024**3,download_memory_bytes=1024**3,acceleration=mode),
   runtime=dict(worker_path=str(resources/'filetwin-worker'),onnxruntime_path=str(models/'runtime/libonnxruntime.dylib')))
  q=root/'request.json'; q.write_text(json.dumps(request)); started=time.monotonic()
  r=subprocess.run([str(resources/'pikpak'),'similarity-scan','--request-file',str(q)],capture_output=True,text=True,timeout=180,
   env={k:v for k,v in os.environ.items() if not k.startswith('PIKPAK_')})
  assert r.returncode==0,r.stderr
  events=[json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]
  report=json.loads(Path(request['report_path']).read_text()); assert report['analysed_files']==12,report['issues']
  choice=[e for e in events if e.get('event')=='acceleration'][-1]
  with sqlite3.connect(data/'runs'/(report['run_id']+'.sqlite3')) as db:
   summary=json.loads(db.execute('SELECT summary FROM run').fetchone()[0])
   extraction=[json.loads(row[0]) for row in db.execute('SELECT extraction FROM files')]
   scores=[row[0] for row in db.execute('SELECT score FROM scores ORDER BY a,b')]
  work=[e['work'] for e in events if e.get('event')=='progress' and 'work' in e]
  assert work and all(w['memory_scheduling'] for w in work)
  assert all(w['analysis_memory_bytes']<=w['analysis_memory_limit'] for w in work)
  assert all(w.get('accelerator_active',0)<=w.get('accelerator_limit',0) and w['memory_in_use']<=w['memory_limit'] for w in work)
  if choice['backend']=='coreml':
   assert choice['accelerator_limit'] > 2, 'CoreML capacity must derive from RAM, not the old two-job setting'
   assert max(w.get('accelerator_active',0) for w in work) > 2, 'Ready visual files must use the available RAM'
  assert all(e['input_storage']=='memory' for e in extraction)
  assert all(-1<=score<=1 for score in scores)
  assert len(scores)==66
  if mode=="cpu": reference=scores
  delta=max(abs(x-y) for x,y in zip(reference,scores))
  assert delta < .02, ("CPU/CoreML score difference",delta)
  assert all(e["inference"]["backend"]==choice["backend"] for e in extraction)
  if mode=='cpu': assert choice['backend']=='cpu'
  results.append(dict(mode=mode,backend=choice['backend'],wall_seconds=round(time.monotonic()-started,3),
   peak_accelerated=max([w.get('accelerator_active',0) for w in work] or [0]),
   extraction_backend=sorted(set(e['inference']['backend'] for e in extraction)),
   comparisons=len(scores),maximum_score_delta=delta,summary=summary))
print(json.dumps(results,indent=2))
if a.output: a.output.write_text(json.dumps(results,indent=2))
