#!/usr/bin/env python3
"""Check which WARP+ licence keys are still worth anything.

Usage:
    ./warp-license-check.py KEY [KEY ...]
    ./warp-license-check.py -f keys.txt          # one key per line, # comments ok

For each key it registers a THROWAWAY device with Cloudflare, applies the key,
reads back the account type, and then DELETES that device again.

The delete is the part that matters. A WARP+ licence admits a limited number of
devices (5), and every check spends one — so a tester that skips the cleanup
burns the quota of exactly the keys that turned out to be good. That is why this
exists rather than a two-line curl.

Output per key:
    UNLIMITED  the key is live WARP+            <- use this one
    FREE       accepted, but the account stays limited: the key is spent,
               expired, or was never WARP+
    REJECTED   Cloudflare refused the key outright
    ERROR      could not be checked (network, or the API moved)

Nothing here touches this machine's own WARP install: every check happens on a
device that exists for a second and is then removed.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = "https://api.cloudflareclient.com/v0a2158"
HEADERS = {
    "Content-Type": "application/json; charset=UTF-8",
    "User-Agent": "okhttp/3.12.1",
    "CF-Client-Version": "a-6.30-3596",
}


def call(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    for k, v in HEADERS.items():
        req.add_header(k, v)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode() or "{}"
    return json.loads(raw)


def register():
    """Create a throwaway device and return (id, token, account)."""
    # The registration only needs a well-formed 32-byte public key; this device is
    # deleted before it is ever used to carry traffic.
    pub = base64.b64encode(os.urandom(32)).decode()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    r = call("POST", "/reg", body={
        "key": pub, "install_id": "", "fcm_token": "", "tos": now,
        "model": "PC", "serial_number": "", "locale": "en_US",
    })
    return r["id"], r["token"], r.get("account", {})


def check(key):
    dev_id = token = None
    try:
        dev_id, token, _ = register()
        try:
            acct = call("PUT", f"/reg/{dev_id}/account", token=token, body={"license": key})
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:120].replace("\n", " ")
            return "REJECTED", detail
        kind = str(acct.get("account_type", "")).lower()
        quota = acct.get("premium_data") or acct.get("quota")
        if kind and kind != "limited" and kind != "free":
            extra = f"{kind}"
            if quota:
                extra += f", quota {int(quota) // (1024**3)} GB"
            return "UNLIMITED", extra
        return "FREE", kind or "limited"
    except Exception as e:  # network, API change, anything
        return "ERROR", str(e)[:120]
    finally:
        # ALWAYS give the device slot back, including on failure.
        if dev_id and token:
            try:
                call("DELETE", f"/reg/{dev_id}", token=token)
            except Exception:
                pass


def main():
    ap = argparse.ArgumentParser(description="Check WARP+ licence keys.")
    ap.add_argument("keys", nargs="*", help="licence keys")
    ap.add_argument("-f", "--file", help="file with one key per line")
    args = ap.parse_args()

    keys = list(args.keys)
    if args.file:
        with open(args.file) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if line:
                    keys.append(line)
    if not keys:
        ap.error("give at least one key, or -f keys.txt")

    good = []
    for i, key in enumerate(keys):
        verdict, detail = check(key)
        print(f"{verdict:<10} {key}  {detail}")
        sys.stdout.flush()
        if verdict == "UNLIMITED":
            good.append(key)
        # Cloudflare rate-limits a burst of registrations; a short gap keeps a long
        # list from turning into a page of ERRORs that say nothing about the keys.
        if i + 1 < len(keys):
            time.sleep(2)

    print(f"\n{len(good)} of {len(keys)} still WARP+")
    for key in good:
        print("  " + key)


if __name__ == "__main__":
    main()
