import json,time,urllib.request,urllib.error,pathlib,ssl,certifi,jwt,subprocess,sys
SSL=ssl.create_default_context(cafile=certifi.where())
KEY_ID="VHUC7XW3Y6";ISSUER="b24cf15b-dcb0-41de-9d02-774b4886a091";APP="6792563972"
KP=pathlib.Path.home()/".appstoreconnect/private_keys/AuthKey_VHUC7XW3Y6.p8";BASE="https://api.appstoreconnect.apple.com"
def tok():
    n=int(time.time());return jwt.encode({"iss":ISSUER,"iat":n,"exp":n+900,"aud":"appstoreconnect-v1"},KP.read_text(),algorithm="ES256",headers={"kid":KEY_ID,"typ":"JWT"})
def req(m,u):
    r=urllib.request.Request(u,method=m,headers={"Authorization":f"Bearer {tok()}"})
    try:
        with urllib.request.urlopen(r,timeout=30,context=SSL) as x: return x.status,json.load(x)
    except urllib.error.HTTPError as e: return e.code,{}
    except (urllib.error.URLError,OSError) as e: return 0,{"net":str(e)}
# wait for build 83 to appear + finish processing (VALID)
for i in range(60):   # ~30 min @ 30s
    s,d=req("GET",f"{BASE}/v1/builds?filter[app]={APP}&filter[version]=83&fields[builds]=processingState&limit=1")
    st=(d.get("data") or [{}])[0].get("attributes",{}).get("processingState") if s==200 else f"http{s}"
    print(f"[{i}] build 83: {st or '(not visible)'}",flush=True)
    if st=="VALID": break
    if st in ("INVALID","FAILED"): print("processing failed, stopping"); sys.exit(1)
    time.sleep(30)
else:
    print("timed out waiting for processing"); sys.exit(1)
print("=== VALID — running crew attach ===",flush=True)
here=pathlib.Path(__file__).parent
subprocess.run([sys.executable,str(here/"ship83-crew.py")],check=False)
