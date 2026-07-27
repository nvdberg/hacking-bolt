#!/usr/bin/env python3
"""Check Working-Bolt's TestFlight Beta App Review status via the App Store Connect API."""
import json, time, urllib.request, pathlib, sys, ssl, certifi
import jwt  # PyJWT

SSL_CTX = ssl.create_default_context(cafile=certifi.where())

KEY_ID = "VHUC7XW3Y6"
ISSUER = "b24cf15b-dcb0-41de-9d02-774b4886a091"
APP_ID = "6792563972"
KEY_PATH = pathlib.Path.home() / ".appstoreconnect/private_keys/AuthKey_VHUC7XW3Y6.p8"

def token():
    priv = KEY_PATH.read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
        priv, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"},
    )

def get(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(req, timeout=30, context=SSL_CTX) as r:
        return json.load(r)

def main():
    url = (f"https://api.appstoreconnect.apple.com/v1/builds"
           f"?filter[app]={APP_ID}&limit=10&include=betaAppReviewSubmission"
           f"&fields[builds]=version,betaAppReviewSubmission"
           f"&fields[betaAppReviewSubmissions]=betaReviewState")
    data = get(url)
    subs = {s["id"]: s["attributes"].get("betaReviewState")
            for s in data.get("included", []) if s["type"] == "betaAppReviewSubmissions"}
    rows = []
    for b in data.get("data", []):
        v = b["attributes"].get("version")
        rel = b.get("relationships", {}).get("betaAppReviewSubmission", {}).get("data")
        state = subs.get(rel["id"]) if rel else None
        rows.append((v, state))
    rows.sort(key=lambda r: int(r[0]) if r[0] and r[0].isdigit() else 0, reverse=True)
    # Focus on the latest build (highest build number)
    latest_v, latest_state = rows[0] if rows else (None, None)
    print(json.dumps({"latest_build": latest_v, "state": latest_state, "all": rows}))
    # exit 0 if APPROVED, 2 if rejected, 1 otherwise (still pending)
    if latest_state == "APPROVED": sys.exit(0)
    if latest_state == "REJECTED": sys.exit(2)
    sys.exit(1)

if __name__ == "__main__":
    main()
