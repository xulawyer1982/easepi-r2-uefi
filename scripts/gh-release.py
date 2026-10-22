#!/usr/bin/env python3
"""创建 Release 并上传资产。

用法: scripts/gh-release.py <tag> <notes.md> <asset> [asset...]

token 从 macOS Keychain 经 `git credential fill` 取，不写进仓库。
上传走 uploads.github.com（github.com 直连经常 502）。
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "xulawyer1982/easepi-r2-uefi"
API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"


def token():
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    sys.exit("取不到 GitHub token（git credential fill 没有返回 password）")


TOK = token()


def call(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {TOK}")
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} {method} {url}\n{e.read().decode(errors='replace')[:600]}")


def upload(release_id, path):
    name = os.path.basename(path)
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        body = f.read()
    url = f"{UPLOADS}/repos/{REPO}/releases/{release_id}/assets?name={urllib.parse.quote(name)}"
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", f"token {TOK}")
    req.add_header("Content-Type", "application/octet-stream")
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            d = json.loads(r.read())
            print(f"  ok  {name}  {size / 1048576:.1f} MB")
            print(f"      {d['browser_download_url']}")
    except urllib.error.HTTPError as e:
        print(f"  FAIL {name}: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")


if len(sys.argv) < 4:
    sys.exit(__doc__)

TAG, NOTES = sys.argv[1], sys.argv[2]
ASSETS = sys.argv[3:]
notes = open(NOTES, encoding="utf-8").read()

try:
    rel = call("GET", f"{API}/repos/{REPO}/releases/tags/{TAG}")
    print(f"release {TAG} 已存在 id={rel['id']}")
except SystemExit:
    rel = call("POST", f"{API}/repos/{REPO}/releases", {
        "tag_name": TAG,
        "target_commitish": "main",
        "name": f"EasePi R2 UEFI {TAG}",
        "body": notes,
        "draft": False,
        "prerelease": False,
    })
    print(f"release {TAG} 已创建 id={rel['id']}")

for p in ASSETS:
    upload(rel["id"], p)

print(f"done https://github.com/{REPO}/release/tag/{TAG}")
