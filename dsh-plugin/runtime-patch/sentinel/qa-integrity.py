import importlib.util,json,subprocess,sys,hashlib,shutil
from pathlib import Path
root=Path.cwd(); script=root/'BB/dsh-plugin/runtime-patch/install.py'
spec=importlib.util.spec_from_file_location('installer',script);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
source=Path('/home/iiishop/.local/lib/node_modules/@deepseek-ai/dsh')
dest=root/'BB/dsh-plugin/.runtime/sentinel-rc5'
results=[]
def run(label,args,expected):
 p=subprocess.run(['uv','run','--no-project','python',str(script),*map(str,args)],capture_output=True,text=True)
 results.append(dict(label=label,command=p.args,exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 assert p.returncode==expected,(label,p.stderr)
def verify():return ['--verify','--destination',dest]
for rel in [mod.LOCK['target'],mod.HELPER]:
 p=dest/rel;data=p.read_bytes()
 try:
  p.write_bytes(data+b'\n// QA hash rejection\n');run('installed tamper '+rel,verify(),1)
 finally:p.write_bytes(data)
run('restored verify',verify(),0)
fake=root/'qa-evidence/fake-source';fake.mkdir(exist_ok=True)
for version in ['wrong','0.2.1-rc.5']:
 (fake/'package.json').write_text(json.dumps({'version':version}))
 target=root/'BB/dsh-plugin/.runtime/rejected-source'
 run('wrong source '+version,['--source',fake,'--destination',target],1)
 assert not target.exists()
original=mod.tree(source)
assert original==(mod.LOCK['tree_sha256'],mod.LOCK['files']),original
results.append(dict(label='original tree after testing',sha256=original[0],files=original[1],unchanged=True))
(root/'qa-evidence/integrity.json').write_text(json.dumps(results,indent=2))
print(json.dumps([{k:v for k,v in r.items() if k not in ('stdout','stderr','command')} for r in results],indent=2))
