#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gh_push_api.py — 经 GitHub Git Data API 复刻本地提交（git push 受限环境的替代通道）。

典型场景：会话/本机代理是白名单制，github.com 的 CONNECT 隧道不通（git push 报
Connection reset / Could not connect to github.com:443 / 502），但 api.github.com
可用（curl https://api.github.com/zen 有响应）。

用法（Git Bash）:
  GITHUB_TOKEN=ghp_xxx python tools/gh_push_api.py --repo cncii/safehouse --repo-dir "C:/path/to/safehouse"

用法（PowerShell）:
  $env:GITHUB_TOKEN="ghp_xxx"
  python tools/gh_push_api.py --repo cncii/safehouse --repo-dir "C:/path/to/safehouse"

可选: --branch main（默认取仓库 default_branch）、--force-anyway（远端 head 不在本地
历史时仍然覆盖，默认拒绝——防止覆盖他人在网页端做的改动）、--proxy http://...（默认
读环境变量 http_proxy/https_proxy）。

行为:
  1. 读远端 <branch> 的 head；要求它是本地历史前缀，否则拒绝（防覆盖）
  2. 远端空仓库时用 Contents API 引导占位提交（随后被 force 顶成孤儿，不进历史）
  3. 逐提交复刻：blob（内容去重缓存）→ tree（SHA 须等于本地）→ commit（SHA 须等于本地）
  4. 将远端 ref force 到本地 head；打印 main 历史核对

实现红线（勿改，血泪教训）:
  - commit 日期必须从本地 git 对象解析「纪元秒+时区偏移」后由代码转 ISO8601，
    禁止手工换算（差 8 小时的教训）；
  - message 用 git 对象原始字节（保留结尾 \\n）；
  - tree 条目必须带 mode（100644/100755）；
  - GET /git/commits 返回的是归一化视图（日期显示 Z、消息剥尾 \\n），不能拿来反推；
  - token 只从环境变量读，禁止写入任何文件。
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

BLOB_LIMIT = 95 * 1024 * 1024  # GitHub blob 上限 100MB，留余量


def make_api(repo, token, proxy):
    base = "https://api.github.com"
    # proxy 为空串时必须传 None（禁用代理处理器），否则 ProxyHandler({"http": ""})
    # 会产生空代理条目 → urlopen 报 "no host given"（2026-10-20 W2 推送实测踩坑）
    handler = ({"http": proxy, "https": proxy} if proxy else None)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(handler))

    def api(method, path, payload=None, allow_404=False):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
        last = None
        for attempt in range(5):
            req = urllib.request.Request(base + "/repos/" + repo + path, data=data, method=method)
            req.add_header("Authorization", "Bearer " + token)
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("User-Agent", "gh-push-api")
            if data:
                req.add_header("Content-Type", "application/json")
            try:
                with opener.open(req, timeout=60) as resp:
                    body = resp.read()
                return json.loads(body) if body else {}
            except urllib.error.HTTPError as e:
                if e.code == 404 and allow_404:
                    return None
                if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                    time.sleep(min(int(e.headers.get("Retry-After", "5") or 5), 30) if e.code == 429 else 3 * (attempt + 1))
                    last = e
                    continue
                raise RuntimeError("HTTP %s %s -> %s %s" % (method, path, e.code, e.read().decode("utf-8", "replace")))
            except Exception as e:
                if attempt < 4:
                    time.sleep(3 * (attempt + 1))
                    last = e
                    continue
                raise RuntimeError("网络重试耗尽 %s %s: %s" % (method, path, last or e))
        raise RuntimeError("retries exhausted: %s %s" % (method, path))
    return api


def make_git(repo_dir):
    def git(*args, binary=False):
        out = subprocess.run(["git", "-C", repo_dir] + list(args), capture_output=True)
        if out.returncode != 0:
            raise RuntimeError("git %s 失败: %s" % (" ".join(args[:3]), out.stderr.decode("utf-8", "replace")))
        return out.stdout if binary else out.stdout.decode("utf-8", "replace")
    return git


def parse_commit(git, sha):
    """返回 (meta, message_bytes)。meta 含 tree/parent/author/committer 原始行。"""
    raw = git("cat-file", "commit", sha, binary=True)
    head, msg = raw.split(b"\n\n", 1)
    meta = {"parent": None}
    for line in head.split(b"\n"):
        line = line.decode("utf-8", "replace")
        if line.startswith("tree "):
            meta["tree"] = line[5:].strip()
        elif line.startswith("parent "):
            meta["parent"] = line[7:].strip()  # 注意：必须写回 meta，勿用局部变量
        elif line.startswith("author "):
            meta["author"] = line[7:]
        elif line.startswith("committer "):
            meta["committer"] = line[10:]
    return meta, msg


def person_to_api(line):
    """'Name <email> 1792477785 +0800' -> {'name','email','date'(ISO8601 带偏移)}"""
    m = re.match(r"^(.*) <([^>]*)> (\d+) ([+-]\d{4})$", line.strip())
    if not m:
        raise RuntimeError("无法解析提交者行: %r" % line)
    name, email, ts, off = m.group(1), m.group(2), int(m.group(3)), m.group(4)
    sign = 1 if off[0] == "+" else -1
    tz = timezone(sign * timedelta(hours=int(off[1:3]), minutes=int(off[3:5])))
    return {"name": name, "email": email, "date": datetime.fromtimestamp(ts, tz=tz).isoformat()}


def bootstrap_repo(api):
    """空仓库调用 Git Data API 会 409 "Git Repository is empty"——
    先用 Contents API 引导一个占位提交；它随后会被 force 指针顶成孤儿，不进历史。"""
    print("远端为空仓库：先引导占位提交（最终不进历史）")
    try:
        api("PUT", "/contents/README.md", {
            "message": "bootstrap placeholder",
            "content": base64.b64encode(b"placeholder\n").decode("ascii"),
        })
    except RuntimeError as e:
        if "422" not in str(e):  # README 已存在则忽略
            raise


def ls_tree_blobs(git, commit):
    out = git("ls-tree", "-r", "-z", commit, binary=True)
    entries = []
    for rec in out.split(b"\x00"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, otype, osha = meta.decode().split()
        if otype != "blob":
            raise RuntimeError("不支持的对象类型 %s（%s）——本工具仅支持普通文件" % (otype, path))
        entries.append((mode, osha, path.decode("utf-8")))
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name，如 cncii/safehouse")
    ap.add_argument("--repo-dir", required=True, help="本地 git 仓库路径")
    ap.add_argument("--branch", default=None, help="远端分支，默认仓库 default_branch")
    ap.add_argument("--proxy", default=None, help="HTTP 代理，默认读环境变量 http_proxy/https_proxy")
    ap.add_argument("--force-anyway", action="store_true", help="远端 head 不在本地历史时仍覆盖（危险）")
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("ERROR: 请设置环境变量 GITHUB_TOKEN（勿写进任何文件）")
        sys.exit(2)
    proxy = args.proxy or os.environ.get("https_proxy") or os.environ.get("http_proxy") or ""
    api = make_api(args.repo, token, proxy)
    git = make_git(args.repo_dir)

    repo_info = api("GET", "", allow_404=True) or api("GET", "")
    if repo_info is None:
        print("ERROR: 仓库 %s 不存在或无权限，请先在网页端创建空仓库" % args.repo)
        sys.exit(2)
    if not repo_info.get("permissions", {}).get("push", True):
        print("ERROR: 该 token 对 %s 无推送权限（需要 Contents: Read and write）" % args.repo)
        sys.exit(2)
    branch = args.branch or repo_info.get("default_branch", "main")
    print("仓库: %s（default=%s, size=%sKB）" % (repo_info["full_name"], branch, repo_info.get("size")))

    local_head = git("rev-parse", "HEAD").strip()
    local_branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()
    if local_branch != branch:
        print("WARN: 本地分支是 %s，将推到远端 %s" % (local_branch, branch))
    chain = git("rev-list", "--reverse", local_head).split()

    ref = api("GET", "/git/ref/heads/%s" % branch, allow_404=True)
    remote_head = ref["object"]["sha"] if ref else None
    if remote_head and remote_head in chain:
        todo = chain[chain.index(remote_head) + 1:]
        print("远端 head %s 是本地祖先，待上传 %d 个提交" % (remote_head[:7], len(todo)))
    elif remote_head:
        print("ERROR: 远端 %s = %s 不在本地历史中（可能在网页端被改过）。"
              "确认要覆盖则加 --force-anyway。" % (branch, remote_head[:7]))
        sys.exit(2)
    else:
        todo = chain
        print("远端分支 %s 不存在，将上传全部 %d 个提交" % (branch, len(todo)))

    blob_cache = {}
    done_shas = {}
    if remote_head and remote_head in chain:
        done_shas[remote_head] = remote_head  # 远端已有的祖先，复刻子提交时要作 parent
    head_sha = remote_head
    for i, c in enumerate(todo, 1):
        meta, msg = parse_commit(git, c)
        entries = ls_tree_blobs(git, c)
        print("[%d/%d] %s（%d 文件）" % (i, len(todo), c[:7], len(entries)))

        items = []
        for mode, osha, path in entries:
            if osha not in blob_cache:
                content = git("cat-file", "blob", osha, binary=True)
                if len(content) > BLOB_LIMIT:
                    print("ERROR: %s 超过 blob 上限（%d MB）" % (path, len(content) >> 20))
                    sys.exit(2)
                payload = {
                    "content": base64.b64encode(content).decode("ascii"),
                    "encoding": "base64",
                }
                for attempt in range(2):
                    try:
                        r = api("POST", "/git/blobs", payload)
                        break
                    except RuntimeError as e:
                        if attempt == 0 and "409" in str(e) and "empty" in str(e).lower():
                            bootstrap_repo(api)
                            continue
                        raise
                if r["sha"] != osha:
                    print("ERROR: blob SHA 不一致 %s: %s vs %s" % (path, r["sha"], osha))
                    sys.exit(2)
                blob_cache[osha] = r["sha"]
            items.append({"path": path, "mode": mode, "type": "blob", "sha": blob_cache[osha]})

        tr = api("POST", "/git/trees", {"tree": items})
        if tr["sha"] != meta["tree"]:
            print("ERROR: tree SHA 不一致 %s: 远端 %s vs 本地 %s" % (c[:7], tr["sha"], meta["tree"]))
            sys.exit(2)

        parents = []
        if meta["parent"]:
            if meta["parent"] not in done_shas:
                print("ERROR: 父提交 %s 尚未存在于远端映射（rev-list 链不完整）" % meta["parent"][:7])
                sys.exit(2)
            parents = [done_shas[meta["parent"]]]
        person_a = person_to_api(meta["author"])
        person_c = person_to_api(meta["committer"])
        r = api("POST", "/git/commits", {
            "message": msg.decode("utf-8"),  # 保留结尾 \n，勿 rstrip
            "tree": tr["sha"],
            "parents": parents,
            "author": person_a,
            "committer": person_c,
        })
        if r["sha"] != c:
            print("ERROR: commit SHA 不一致 %s: 远端 %s（日期格式或 parent 有误，勿手改日期）" % (c[:7], r["sha"]))
            sys.exit(2)
        done_shas[c] = r["sha"]
        head_sha = r["sha"]
        print("  复刻一致: %s" % r["sha"][:7])

    if not head_sha:
        print("无事可做：远端与本地一致")
        return

    if ref:
        api("PATCH", "/git/refs/heads/%s" % branch, {"sha": head_sha, "force": True})
    else:
        try:
            api("POST", "/git/refs", {"ref": "refs/heads/%s" % branch, "sha": head_sha})
        except RuntimeError as e:
            if "422" in str(e):
                api("PATCH", "/git/refs/heads/%s" % branch, {"sha": head_sha, "force": True})
            else:
                raise
    print("完成: 远端 %s -> %s（与本地 HEAD 一致）" % (branch, head_sha))


if __name__ == "__main__":
    main()
