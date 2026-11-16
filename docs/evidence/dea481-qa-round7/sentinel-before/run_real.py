import json, os, socket, subprocess, sys, time, urllib.request, urllib.error
from pathlib import Path
root=Path.cwd()
qa=root.parent/"qa4"
mode=sys.argv[1]
assert mode in ("known", "adjacent", "controls")
state=qa/("server-"+mode)
state.mkdir(exist_ok=True)
with socket.socket() as sock:
 sock.bind(("127.0.0.1",0));port=sock.getsockname()[1]
env=dict(os.environ,BB_DATABASE_PATH=str(state/"test.db"),BB_MEDIA_DIRECTORY=str(state/"media"),BB_AVATAR_DIRECTORY=str(state/"avatars"),BB_HOST="127.0.0.1",BB_PORT=str(port))
base=f"http://127.0.0.1:{port}"
with (state/"server.log").open("w") as log:
 p=subprocess.Popen([str(root/"server/.venv/bin/python"),"-m","bb_server"],cwd=root/"server",env=env,stdout=log,stderr=subprocess.STDOUT)
 try:
  for _ in range(150):
   assert p.poll() is None
   try:
    urllib.request.urlopen(base+"/auth/session",timeout=1)
   except urllib.error.HTTPError as e:
    if e.code==401:break
   except OSError: pass
   time.sleep(.1)
  else: raise RuntimeError("readiness failed")
  command=[sys.executable,"scripts/ci/qa_evidence.py","run","--cwd","client","--out","../qa4/"+mode,"--flutter-json","--","flutter","test","--no-pub",*([".qa-artifacts/probes/"+n for n in ["space_defect_probe_test.dart","adjacent_draft_probe_test.dart","upload_conflict_probe_test.dart","sentinel_round2_test.dart","sentinel_round2_controls_test.dart","rollback_tombstone_probe_test.dart","sentinel_round3_test.dart"]] if mode == "known" else [".qa-artifacts/probes/sentinel_round4_controls_test.dart"] if mode == "controls" else [".qa-artifacts/probes/sentinel_round4_test.dart"]),"--reporter=json"]
  result=subprocess.run(command,cwd=root,env=dict(os.environ,BB_SPACE_API_BASE=base))
 finally:
  daemon=json.loads(subprocess.check_output([os.environ["MULTICA_CLI_PATH"],"daemon","status","--output","json"],text=True))
  assert str(p.pid) not in json.dumps(daemon), "child PID overlaps daemon report"
  p.terminate();p.wait(timeout=15)
sys.exit(result.returncode)
