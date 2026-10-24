"""Minimal App Store Connect API client (key from ~/.appstoreconnect/private_keys)."""
import jwt, time, requests, os
KID = "6Q63F35BB6"
ISS = open(os.path.expanduser("~/pult/scripts/ios/asc.py")).read().split('ISS = "')[1].split('"')[0]
API = "https://api.appstoreconnect.apple.com/v1"
_key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KID}.p8")).read()

def H():
    t = jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
                   _key, algorithm="ES256", headers={"kid": KID})
    return {"Authorization": f"Bearer {t}", "Content-Type": "application/json"}

def _ok(r):
    if r.status_code >= 400: raise RuntimeError(f"{r.status_code} {r.text[:800]}")
    return r.json() if r.text else {}

def get(path, **params): return _ok(requests.get(API + path, params=params, headers=H()))
def post(path, body): return _ok(requests.post(API + path, json=body, headers=H()))
def patch(path, body): return _ok(requests.patch(API + path, json=body, headers=H()))
