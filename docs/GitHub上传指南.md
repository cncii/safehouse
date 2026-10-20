# GitHub 上传指南（代理受限环境）

> 面向各组：当你需要把代码推上 GitHub 而 `git push` 失败时，按本文操作。
> 工具：`tools/gh_push_api.py`（本仓库自带，无需安装依赖，标准库实现）。
> 配套 skill：工作区 `.workbuddy/skills/github-upload/`（AI 会话可自动加载）。

## 1. 先诊断，再选通道

```bash
curl -sI --max-time 10 https://github.com | head -1          # git push 走的域名
curl -x "$https_proxy" -s --max-time 10 https://api.github.com/zen   # API 通道
```

| 结果 | 通道 |
|---|---|
| github.com 通 | 直接 `git push`（本文不需要） |
| github.com 不通、api.github.com 返回英文文案 | **用 `tools/gh_push_api.py`** |
| 都不通 | 代理/网络故障，先修网络 |

本机会话代理 `http://127.0.0.1:56625` 为白名单制：放行 `api.github.com`，
拦截 `github.com` 的 CONNECT 隧道——所以 git push 报
`Connection reset` / `Could not connect to github.com:443` 属预期现象。

## 2. 一条命令上传

```bash
GITHUB_TOKEN=ghp_xxx \
python tools/gh_push_api.py --repo cncii/safehouse --repo-dir "$(pwd)"
```

- `--repo`：GitHub 仓库名（owner/name）
- `--repo-dir`：本地仓库路径，默认当前目录可自行调整
- `--branch`：默认远端 default_branch
- token 只走环境变量，**不要**写进任何文件

脚本自动：对比远端/本地差异 → 只传领先提交 → 每层校验 SHA 与本地一致 →
force 到本地 HEAD → 打印远端历史核对。远端 head 不在本地历史时会拒绝执行
（防止覆盖网页端改动），确需覆盖加 `--force-anyway`。

## 3. 原理与保证

通过 GitHub Git Data API（blobs → trees → commits → refs）逐层复刻本地提交对象。
**提交 SHA 与本地字节级一致**（含作者、时间戳、时区偏移、完整 message），
因此将来网络直连可用时，`git push` 依然是正常的 fast-forward，无需任何清理。

## 4. 故障排查

| 报错 | 原因 | 处理 |
|---|---|---|
| `HTTP 401` | token 无效/过期 | 重建 PAT |
| `HTTP 403` 无权限 | fine-grained 未勾 Contents Write | 补权限 |
| `404` 仓库不存在 | 仓库被改名/没建 | 网页端确认实际名（旧名 301 重定向） |
| `409 Git Repository is empty` | 空仓库 | 脚本已自动引导占位提交，无需处理 |
| commit SHA 不一致 | 日期换算被手改 | 不要手改日期，脚本会从 git 对象自动换算 |
| 远端 head 不在本地历史 | 网页端有人改过 | 与改动者对齐后再 `--force-anyway` |

## 5. 安全纪律

- PAT 只在环境变量 `GITHUB_TOKEN` 中传递；聊天中明文出现过的 PAT 用完即撤销。
- 禁止把 token 写入 `remote URL`、`.git/config`、脚本常量。
- 上传脚本本身不含密钥，可放心入库。
