import json, time, urllib.request, urllib.error, pathlib, ssl, certifi, jwt, sys
SSL=ssl.create_default_context(cafile=certifi.where())
KEY_ID="VHUC7XW3Y6"; ISSUER="b24cf15b-dcb0-41de-9d02-774b4886a091"; APP="6792563972"
KP=pathlib.Path.home()/".appstoreconnect/private_keys/AuthKey_VHUC7XW3Y6.p8"; BASE="https://api.appstoreconnect.apple.com"
GROUPS={"Colleagues":"c37c1e17-2142-4b87-9bae-400dd799bc45","Push Test":"f4f12591-a0fa-4186-92d6-512c58070d56"}
FALLBACK={"nicolaasenadele@gmail.com","matthew.butz@usask.ca","hughesy306@gmail.com","reineckecj@yahoo.com"}
TARGET="79"
NOTES="Smoother: faster crew history, give-away + pick-up fixes, sign-out stays signed out."
def tok():
    n=int(time.time()); return jwt.encode({"iss":ISSUER,"iat":n,"exp":n+1000,"aud":"appstoreconnect-v1"},KP.read_text(),algorithm="ES256",headers={"kid":KEY_ID,"typ":"JWT"})
def req(m,u,b=None):
    d=json.dumps(b).encode() if b is not None else None
    r=urllib.request.Request(u,data=d,method=m,headers={"Authorization":f"Bearer {tok()}","Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(r,timeout=30,context=SSL) as x: return x.status,(json.load(x) if x.status!=204 else {})
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"{}")
_,d=req("GET",f"{BASE}/v1/builds?filter[app]={APP}&filter[version]={TARGET}&fields[builds]=version&limit=1")
if not d.get("data"): print(f"build {TARGET} not found"); sys.exit(1)
bid=d["data"][0]["id"]
_,loc=req("GET",f"{BASE}/v1/builds/{bid}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale,whatsNew")
ex=next((l for l in loc.get("data",[]) if l["attributes"]["locale"]=="en-US"),None)
if ex: req("PATCH",f"{BASE}/v1/betaBuildLocalizations/{ex['id']}",{"data":{"type":"betaBuildLocalizations","id":ex["id"],"attributes":{"whatsNew":NOTES}}})
else:  req("POST",f"{BASE}/v1/betaBuildLocalizations",{"data":{"type":"betaBuildLocalizations","attributes":{"locale":"en-US","whatsNew":NOTES},"relationships":{"build":{"data":{"type":"builds","id":bid}}}}})
print("crew notes set",flush=True)
_,t=req("GET",f"{BASE}/v1/betaTesters?limit=200&fields[betaTesters]=email")
tid=[x["id"] for x in t.get("data",[]) if (x["attributes"].get("email") or "").lower() in FALLBACK]
done=set()
for i in range(40):
    if len(done)==len(GROUPS): break
    for name,gid in GROUPS.items():
        if name in done: continue
        s,_=req("POST",f"{BASE}/v1/betaGroups/{gid}/relationships/builds",{"data":[{"type":"builds","id":bid}]})
        if s in (200,201,204): print(f"ATTACHED to {name}",flush=True); done.add(name)
        else: print(f"try {i+1} {name}: {s}",flush=True)
    if tid: req("POST",f"{BASE}/v1/builds/{bid}/relationships/individualTesters",{"data":[{"type":"betaTesters","id":x} for x in tid]})
    if len(done)==len(GROUPS): break
    time.sleep(900)
s,_=req("POST",f"{BASE}/v1/betaAppReviewSubmissions",{"data":{"type":"betaAppReviewSubmissions","relationships":{"build":{"data":{"type":"builds","id":bid}}}}})
print("beta review:", "SUBMITTED" if s in (200,201) else s)
print("RESULT: attached to", sorted(done) or "nothing")
