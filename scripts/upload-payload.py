#!/usr/bin/env python3
"""把 recovery 资产上传到本仓库的 release，供 CI 组装完整刷机盘。

走 uploads.github.com（github.com:443 在这台机器上不稳，api/uploads 稳定）。
token 从 macOS Keychain 经 git credential fill 取。

用法：
    ./scripts/upload-payload.py                     # 自动打包并上传
    ./scripts/upload-payload.py --tag payload-k6.18.18-trim
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "xulawyer1982/easepi-r2-uefi"
API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"
DEFAULT_TAG = "payload-k6.18.18-trim"
ASSET = "recovery-payload.tar.gz"


def token():
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    sys.exit("✘ 取不到 GitHub token（git credential fill 失败）")


def api(method, url, data=None, ctype="application/json"):
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def ensure_release(tag):
    code, r = api("GET", "%s/repos/%s/releases/tags/%s" % (API, REPO, tag))
    if code == 200:
        print("  已有 release：%s (id=%s)" % (tag, r["id"]))
        return r["id"]
    code, r = api("POST", "%s/repos/%s/releases" % (API, REPO),
                  json.dumps({
                      "tag_name": tag,
                      "name": "recovery payload (%s)" % tag,
                      "body": (
                          "CI 组装完整刷机盘所需的 recovery 资产。\n\n"
                          "内容：Kernel 6.18.18-trim (opHUB)、busybox-static arm64、"
                          "网卡模块、RTL8125 firmware、fxrecovery (Go 静态二进制)。\n\n"
                          "这些文件来自上一代 U-Boot 方案（easypi-r2-recovery），"
                          "现在由 UEFI 方案复用。"
                      ),
                      "draft": False,
                      "prerelease": True,
                  }).encode())
    if code not in (200, 201):
        sys.exit("✘ 创建 release 失败：%s %s" % (code, r))
    print("  已创建 release：%s (id=%s)" % (tag, r["id"]))
    return r["id"]


def delete_existing_asset(rel_id, name):
    code, r = api("GET", "%s/repos/%s/releases/%d/assets" % (API, REPO, rel_id))
    if code != 200:
        return
    for a in r:
        if a["name"] == name:
            api("DELETE", "%s/repos/%s/releases/assets/%d" % (API, REPO, a["id"]))
            print("  已删除同名旧资产")


def upload(rel_id, path):
    name = os.path.basename(path)
    delete_existing_asset(rel_id, name)
    size = os.path.getsize(path)
    print("  上传 %s (%d bytes / %.1f MiB) ..." % (name, size, size / 1048576))
    with open(path, "rb") as f:
        data = f.read()
    url = "%s/repos/%s/releases/%d/assets?name=%s" % (UPLOADS, REPO, rel_id, name)
    req = urllib.request.Request(url, method="POST", data=data)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/gzip")
    req.add_header("Content-Length", str(size))
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            print("  ✔ 已上传：%s" % json.loads(r.read()).get("browser_download_url"))
    except urllib.error.HTTPError as e:
        sys.exit("✘ 上传失败：%s %s" % (e.code, e.read()[:400]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default=DEFAULT_TAG)
    ap.add_argument("--file", default=ASSET)
    a = ap.parse_args()
    if not os.path.isfile(a.file):
        sys.exit("✘ 找不到 %s（先打包）" % a.file)
    rel_id = ensure_release(a.tag)
    upload(rel_id, a.file)


if __name__ == "__main__":
    main()
