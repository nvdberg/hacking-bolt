"""TestFlight release steps for Working-Bolt (test-first flow, 2026-10-06).

  python3 tools/asc.py me NN     wait for build NN to finish processing -> it lands in My Devices
                                 (internal, Nicolaas only, every build automatically, no review).
                                 Sets notes from notes-NN.txt if present. Nobody else is notified.
  python3 tools/asc.py crew NN   Nicolaas said "send it to the crew": notes from notes-NN.txt
                                 (one combined set since the crew's last build), attach to
                                 Colleagues + fallback testers, submit beta review.
  python3 tools/asc.py last      the last build the crew got (to know what the combined notes cover)
"""
import json, time, urllib.request, urllib.error, pathlib, ssl, certifi, jwt, sys
SSL=ssl.create_default_context(cafile=certifi.where())
KEY_ID="VHUC7XW3Y6"; ISSUER="b24cf15b-dcb0-41de-9d02-774b4886a091"; APP="6792563972"
KP=pathlib.Path.home()/".appstoreconnect/private_keys/AuthKey_VHUC7XW3Y6.p8"; BASE="https://api.appstoreconnect.apple.com"
CREW={"Colleagues":"c37c1e17-2142-4b87-9bae-400dd799bc45"}
# testers who sometimes missed group builds -> also attached individually.
# Emails live outside the repo (public): one per line, # comments ok.
_FB=pathlib.Path.home()/".appstoreconnect/wb-fallback-testers.txt"
FALLBACK={l.strip().lower() for l in (_FB.read_text().splitlines() if _FB.exists() else []) if l.strip() and not l.startswith("#")}
HERE=pathlib.Path(__file__).parent

def tok():
    n=int(time.time()); return jwt.encode({"iss":ISSUER,"iat":n,"exp":n+1000,"aud":"appstoreconnect-v1"},KP.read_text(),algorithm="ES256",headers={"kid":KEY_ID,"typ":"JWT"})
def req(m,u,b=None):
    d=json.dumps(b).encode() if b is not None else None
    r=urllib.request.Request(u,data=d,method=m,headers={"Authorization":f"Bearer {tok()}","Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(r,timeout=30,context=SSL) as x: return x.status,(json.load(x) if x.status!=204 else {})
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"{}")
    except (urllib.error.URLError,OSError) as e: return 0,{"net":str(e)}

def build(nn):
    s,d=req("GET",f"{BASE}/v1/builds?filter[app]={APP}&filter[version]={nn}&fields[builds]=processingState&limit=1")
    return (d.get("data") or [None])[0] if s==200 else None

def set_notes(bid,nn):
    f=HERE/f"notes-{nn}.txt"
    if not f.exists(): print(f"no notes-{nn}.txt, notes left as is"); return
    notes=f.read_text().strip()
    _,loc=req("GET",f"{BASE}/v1/builds/{bid}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale,whatsNew")
    ex=next((l for l in loc.get("data",[]) if l["attributes"]["locale"]=="en-US"),None)
    if ex: req("PATCH",f"{BASE}/v1/betaBuildLocalizations/{ex['id']}",{"data":{"type":"betaBuildLocalizations","id":ex["id"],"attributes":{"whatsNew":notes}}})
    else:  req("POST",f"{BASE}/v1/betaBuildLocalizations",{"data":{"type":"betaBuildLocalizations","attributes":{"locale":"en-US","whatsNew":notes},"relationships":{"build":{"data":{"type":"builds","id":bid}}}}})
    print("notes set",flush=True)

def me(nn):
    for i in range(60):   # ~30 min @ 30s
        b=build(nn); st=b["attributes"]["processingState"] if b else None
        print(f"[{i}] build {nn}: {st or '(not visible)'}",flush=True)
        if st=="VALID": break
        if st in ("INVALID","FAILED"): print("processing failed, stopping"); sys.exit(1)
        time.sleep(30)
    else: print("timed out waiting for processing"); sys.exit(1)
    set_notes(b["id"],nn)
    print(f"RESULT: build {nn} is in My Devices (only Nicolaas). Crew not touched.")

def crew(nn):
    b=build(nn)
    if not b or b["attributes"]["processingState"]!="VALID": print(f"build {nn} not ready"); sys.exit(1)
    bid=b["id"]; set_notes(bid,nn)
    _,t=req("GET",f"{BASE}/v1/betaTesters?limit=200&fields[betaTesters]=email")
    tid=[x["id"] for x in t.get("data",[]) if (x["attributes"].get("email") or "").lower() in FALLBACK]
    done=set()
    for i in range(40):
        for name,gid in CREW.items():
            if name in done: continue
            s,_=req("POST",f"{BASE}/v1/betaGroups/{gid}/relationships/builds",{"data":[{"type":"builds","id":bid}]})
            if s in (200,201,204): print(f"ATTACHED to {name}",flush=True); done.add(name)
            else: print(f"try {i+1} {name}: {s}",flush=True)
        if tid: req("POST",f"{BASE}/v1/builds/{bid}/relationships/individualTesters",{"data":[{"type":"betaTesters","id":x} for x in tid]})
        if len(done)==len(CREW): break
        time.sleep(900)
    s,_=req("POST",f"{BASE}/v1/betaAppReviewSubmissions",{"data":{"type":"betaAppReviewSubmissions","relationships":{"build":{"data":{"type":"builds","id":bid}}}}})
    print("beta review:", "SUBMITTED" if s in (200,201) else s)
    print("RESULT: crew build", nn, "attached to", sorted(done) or "nothing")

def last():
    _,d=req("GET",f"{BASE}/v1/betaGroups/{CREW['Colleagues']}/builds?fields[builds]=version,uploadedDate&limit=200")
    v=sorted(d.get("data",[]),key=lambda x:int(x["attributes"]["version"]))
    print("crew's last build:", v[-1]["attributes"]["version"] if v else "none")

if __name__=="__main__":
    a=sys.argv[1:]
    if a[:1]==["me"] and len(a)==2: me(a[1])
    elif a[:1]==["crew"] and len(a)==2: crew(a[1])
    elif a[:1]==["last"]: last()
    else: print(__doc__)
