import hashlib, json, shutil, subprocess, sys
from pathlib import Path
root = Path.cwd()
qa = root.parent / 'qa7'
sys.path.insert(0, str(root / 'scripts/ci'))
from qa_evidence import read_run
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
for mode in ['known', 'adjacent']:
    run, cases, counts = read_run(qa / mode / 'run.json')
    (qa / (mode + '-counts.json')).write_text(json.dumps(counts))
    rules = [dict(id=mode+str(i), rule=c.identity[1], entry='SpaceController deletion entry to SpaceImageLoader cache and viewer', status='tested', run=mode+'/run.json', testcase=dict(classname=c.identity[0], name=c.identity[1])) for i,c in enumerate(cases)]
    report = qa / (mode + '-report.json')
    report.write_text(json.dumps(dict(candidate_sha=head, rules=rules), indent=2))
    cmd = [sys.executable, 'scripts/ci/qa_evidence.py', 'check', str(report), '--candidate', head]
    for r in rules: cmd += ['--require', r['id']]
    result = subprocess.run(cmd, capture_output=True, text=True)
    (qa / (mode+'-check.json')).write_text(result.stdout)
    (qa / (mode+'-check.stderr')).write_text(result.stderr)
    (qa / (mode+'-check.exit')).write_text(str(result.returncode))
    print(mode, counts, 'checker', result.returncode)
    state = qa / ('server-'+mode)
    shutil.copyfile(state/'server.log', qa/('server-'+mode+'.log'))
    shutil.rmtree(state)
for name in ['sentinel_round5_test.dart','sentinel_round5_widget_test.dart','sentinel_round6_test.dart','space_defect_probe_test.dart','adjacent_draft_probe_test.dart','detail_reference_image_probe_test.dart','closed_detail_image_probe_test.dart','sentinel_round7_test.dart','sentinel_round7_viewer_test.dart']:
    shutil.copyfile(root/'client/.qa-artifacts/probes'/name, qa/name)
paths=['client/lib/ui/space/space_controller.dart','client/lib/ui/space/space_detail_controller.dart','client/lib/ui/space/space_compose_controller.dart','client/pubspec.lock','server','dsh-plugin']
comparison={}
for p in paths:
    comparison[p]={sha:subprocess.check_output(['git','rev-parse',sha+':'+p],text=True).strip() for sha in ['ec65ac4',head]}
(qa/'reuse-boundaries.json').write_text(json.dumps(comparison,indent=2))
(qa/'production-diff.patch').write_bytes(subprocess.check_output(['git','diff','ec65ac4',head,'--','client/lib']))
(qa/'git-status.txt').write_bytes(subprocess.check_output(['git','status','--porcelain']))
