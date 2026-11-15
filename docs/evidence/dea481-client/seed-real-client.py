import json, time, urllib.request
BASE='http://127.0.0.1:8765'
def call(path, payload, token=None):
    req=urllib.request.Request(BASE+path, data=json.dumps(payload).encode(), method='POST',
        headers={'Content-Type':'application/json', **({'Authorization':'Bearer '+token} if token else {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())
session=json.load(open('real-client-data/run/session.json'))
at=session['token']
ts=str(int(time.time()*1000))[-8:]
d=call('/space/create_draft', {'operation_id':'ui2-draft-'+ts,'text':''}, at)
draft=d['resource_id']; ver=d['resource_version']
p1=open('real-client-data/photo1.b64').read().strip()
p2=open('real-client-data/photo2.b64').read().strip()
for i,p in enumerate([p1,p2]):
    r=call('/space/add_image', {'operation_id':f'ui2-img-{ts}-{i}','draft_id':draft,'expected_version':ver,'filename':f'ui2-{i}.png','base64':p}, at)
    ver=r['resource_version']
gd=call('/space/get_draft', {'draft_id':draft}, at)
ids=[im['image_id'] for im in gd['images']]
print('ids', ids)
r=call('/space/update_draft', {'operation_id':'ui2-order-'+ts,'draft_id':draft,'expected_version':gd['version'],'text':'今天沿着海岸走了很久。风把云推得很低，海面一层一层地亮起来。这是最近最喜欢的一段路，想留在这里。','reference_id':None,'image_ids':list(reversed(ids))}, at)
pub=call('/space/publish_draft', {'operation_id':'ui2-pub-'+ts,'draft_id':draft,'expected_version':r['resource_version']}, at)
post=pub['resource_id']
print('photo post', post)
l=call('/auth/login', {'account':'20434856','password':'SpaceUI1pass'})
bt=l['token']
call('/space/create_comment', {'operation_id':'ui2-c1-'+ts,'post_id':post,'text':'第九张的浪花好看，是哪一段海岸？','reply_to_id':None}, bt)
call('/space/set_like', {'operation_id':'ui2-l1-'+ts,'post_id':post,'liked':True}, bt)
call('/space/get_post', {'post_id':post,'visit_id':'ui2-visit-'+ts}, bt)
print('done')
