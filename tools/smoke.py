#!/usr/bin/env python3
"""Real HTTP/OCR smoke test. Creates a clearly labelled validation batch."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request
import uuid
import zipfile

parser=argparse.ArgumentParser()
parser.add_argument('--base-url',default='http://127.0.0.1:8788')
parser.add_argument('--image',type=Path,required=True)
parser.add_argument('--expected',default='世界书')
parser.add_argument('--output',type=Path)
args=parser.parse_args()
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def request(path,method='GET',data=None,content_type='application/json',raw=False):
    if data is not None and not isinstance(data,bytes):data=json.dumps(data,ensure_ascii=False).encode()
    req=urllib.request.Request(args.base_url.rstrip('/')+path,data=data,method=method,headers={'Content-Type':content_type})
    with opener.open(req,timeout=30) as response:
        result=response.read()
        return result if raw else json.loads(result)

original=args.image.read_bytes()
run=request('/api/runs','POST',{'title':'功能验证样例 · 图片识别闭环'})
boundary='screen-'+uuid.uuid4().hex
body=(f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="sample.png"\r\nContent-Type: image/png\r\n\r\n'.encode()
      +original+f'\r\n--{boundary}--\r\n'.encode())
frame=request(f'/api/runs/{run["id"]}/frames','POST',body,'multipart/form-data; boundary='+boundary)
for _ in range(120):
    frame=request('/api/frames/'+frame['id'])
    if frame['ocrState'] in ('failed','succeeded'):break
    time.sleep(.25)
assert frame['ocrState']=='succeeded',frame
assert args.expected in frame['ocrText'],frame['ocrText']
assert frame['sha256']==hashlib.sha256(original).hexdigest()
assert request('/api/images/'+frame['id'],raw=True)==original
assert request('/api/search?q='+urllib.parse.quote(args.expected))
print('PASS real OCR, original image hash and keyword search')
text=frame['ocrText']+'\n人工校对验证标记'
request('/api/frames/'+frame['id']+'/text','PATCH',{'text':text})
assert len(request('/api/frames/'+frame['id']+'/revisions'))==2
assert request('/api/search?q='+urllib.parse.quote('校对验证'))
archive=request('/api/runs/'+run['id']+'/export',raw=True)
with zipfile.ZipFile(io.BytesIO(archive)) as z:
    assert '人工校对验证标记' in z.read('scan.md').decode()
    assert z.read('images/'+frame['id']+'.png')==original
    assert json.loads(z.read('manifest.json'))['run']['Id']==run['id']
request('/api/runs/'+run['id']+'/close','POST')
assert request('/api/runs/'+run['id'])['run']['state']=='closed'
print('PASS correction history, rebuilt index, Markdown/image export and archived batch')
report={'runId':run['id'],'frameId':frame['id'],'ocrText':frame['ocrText'],'sha256':frame['sha256'],'checks':'passed'}
if args.output:
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
