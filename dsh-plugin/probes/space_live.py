"""Real TCP server -> standalone Dart -> protected local contract integration.
All credentials are synthetic, temporary, and removed on exit.
"""
import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import httpx
from bb_auth_contract import space

REPO = Path(__file__).resolve().parents[2]

class Live:
    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bb-space-')
        self.root = Path(self.temp.name)
        self.children = []
        self.http = httpx.Client(trust_env=False, timeout=30)
        self.api = self.port()
        self.local = self.port()
        self.server_command = ['uv', 'run', '--project', 'server', '--locked', 'python', '-m', 'bb_server']
        self.server_env = dict(os.environ, BB_DATABASE_PATH=str(self.root/'db'),
            BB_AVATAR_DIRECTORY=str(self.root/'avatars'), BB_MEDIA_DIRECTORY=str(self.root/'media'),
            BB_HOST='127.0.0.1', BB_PORT=self.api.rsplit(':',1)[1])
        self.server = self.launch(self.server_command, self.api, self.server_env)
        self.dart_command = ['dart', '--packages='+str(REPO/'client/.dart_tool/package_config.json'),
            str(REPO/'client/bin/bb_client_api.dart'), '--port', self.local.rsplit(':',1)[1],
            '--server-url', self.api, '--session-file', str(self.root/'client/session.json')]
        self.dart = self.launch(self.dart_command, self.local)
        return self
    @staticmethod
    def port():
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            return 'http://127.0.0.1:'+str(s.getsockname()[1])
    def launch(self, command, origin, env=None):
        log = open(self.root/f'child-{len(self.children)}.log', 'w+')
        p = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=log)
        self.children.append((p,log))
        for _ in range(200):
            if p.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            try:
                self.http.get(origin+'/',timeout=.2)
                return p
            except httpx.TransportError: time.sleep(.05)
        raise AssertionError('readiness deadline')
    def stop(self,p):
        if p.poll() is not None: return
        daemon=json.loads(subprocess.check_output([os.environ['MULTICA_CLI_PATH'],'daemon','status','--output','json']))
        assert p.pid != daemon['pid']
        p.terminate()
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait(timeout=5)
    def __exit__(self,*args):
        for p, log in reversed(self.children):
            self.stop(p); log.close()
        self.http.close(); self.temp.cleanup()
    def post(self, path, body, *, api=False, headers=None, status=200):
        r=self.http.post((self.api if api else self.local)+path,json=body,headers=headers)
        assert r.status_code==status, (path,r.status_code,r.text[:500])
        return r.json()
    def register(self,name):
        return self.post('/auth/register',{'username':name,'password':'Abc123'},status=201)['account']
    def login(self,account,owner='A'*43,session='space-session'):
        self.post('/auth/login',{'account':account,'password':'Abc123'})
        auth=self.post('/v2/status',{})['auth']
        headers={'X-BB-Consumer-Key':owner}
        b=self.post('/v2/consumers/create',{'expected_auth':auth,'session_id':session},headers=headers)
        if not b['active']:
            b=self.post('/v2/consumers/bind',{'expected_auth':auth,'consumer_id':b['identity']['consumer_id'],
                'expected_binding_revision':b['identity']['binding_revision'],'session_id':session},headers=headers)
        self.identity=b['identity']; self.owner=owner
        return b
    def call(self,action,body=None,status=200, identity=None,owner=None):
        body={'expected_identity': identity or self.identity, **(body or {})}
        space.LOCAL_REQUESTS[action].model_validate(body)
        result=self.post('/v2/space/'+action,body,headers={'X-BB-Consumer-Key':owner or self.owner},status=status)
        if status==200:
            space.LOCAL_RESPONSES[action].model_validate(result)
            assert result['identity']==body['expected_identity']
            return result['result']
        return result

def run():
    with Live() as live:
        account=live.register('SpaceAgent')
        live.login(account)
        assert live.call('overview')['contract']==space.VERSION
        draft=live.call('create_draft',{'operation_id':'draft-one','text':'draft'})
        saved=live.call('get_draft',{'draft_id':draft['resource_id']})
        assert saved['text']=='draft'
        post=live.call('publish_draft',{'operation_id':'pub-one','draft_id':saved['draft_id'],'expected_version':1})
        assert live.call('get_operation',{'operation_id':'pub-one'})==post
        assert live.call('publish_draft',{'operation_id':'pub-one','draft_id':saved['draft_id'],'expected_version':1})==post
        assert len(live.call('list_posts')['items'])==1
        live.call('get_operation',{'operation_id':'pub-one'},owner='B'*43,status=409)
        print(json.dumps({'gate':'standalone-dart-tcp-schema-operation','passed':True}))

if __name__=='__main__': run()
