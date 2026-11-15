#!/usr/bin/env bash
# 把 CI 出的 APK 挂到 Gitee 发行版上 —— 发版的最后一步（`release.sh` 自动调，也可单独重跑）。
#
#   用法：bash scripts/gitee-attach.sh v1.0.14
#
# ⚠️ 为什么在本机传：runner 在境外，往 gitee.com 传 21MB 实测 1.9~20 KB/s（18~90 分钟，常以
#    curl: (56) 断在半路）；从国内宽带传只要几秒。所以 CI 只管 GitHub 发布，**Gitee 的发行版在这里建**。
#
# ⚠️ 为什么发行版要和附件一起建：Gitee 的 `/releases/latest` **不跳过预发布**（GitHub 会跳），
#    空壳发行版一建出来，App 的「检查更新」立刻看得到、点下载却是 404。这里的规矩是
#    「Gitee 上有这个版本 ⟺ 附件已经挂着」：建 → 传 → 核对字节，任一步失败就把刚建的那个删掉。
#
# 令牌：`$GITEE_TOKEN`，没有就问 `gitee auth token`；都没有会把两种配法打出来。
# 解析 Gitee 的接口返回用 python3（或 python），没有会提示怎么装。
#
# 幂等：这个版本已经挂着同样大小的附件就直接跳过上传（中断后重跑安全）。
set -euo pipefail

cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

tag="${1:-}"
[ -n "$tag" ] || die "用法：bash scripts/gitee-attach.sh v1.0.14"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag 要写成 v1.0.14 这样"

gh_repo="mos1128/findR"
api="https://gitee.com/api/v5/repos/ms6/findR"
release_page="https://gitee.com/ms6/findR/releases/tag/$tag"

# ── 前置：令牌、python ──────────────────────────────────────────────────────
token="${GITEE_TOKEN:-}"
if [ -z "$token" ] && command -v gitee >/dev/null 2>&1; then
  token="$(gitee auth token 2>/dev/null | head -1)" || true
fi
if [ -z "$token" ]; then
  die "没有 Gitee 令牌。任选一条配好再来：
      1. npm i -g @gitee/gitee-cli && gitee auth login
      2. setx GITEE_TOKEN <令牌>   （然后重开终端）
      令牌在 Gitee → 设置 → 私人令牌，权限只勾 projects。"
fi

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then
    PY="$c"
    break
  fi
done
[ -n "$PY" ] || die "解析 Gitee 的接口返回要 python3（或 python）：scoop install python / winget install Python.Python.3.13"
# 只在管道里输出中文时才需要，但 Windows 上默认是 cp936，顺手钉死成 UTF-8（日志里别出现半个字）
export PYTHONIOENCODING=utf-8

# 路径里的 tag 做百分号编码（万一以后又用回带 `+` 的版本号写法：`+` 会被当成空格）
tag_path="$("$PY" -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$tag")"
download_url="https://gitee.com/ms6/findR/releases/download/$tag_path/app-release.apk"

# ── 1. 等 CI 把包装到 GitHub 发布上 ─────────────────────────────────────────
# 构建红了就立刻退出，不陪着白等 45 分钟。
say "等 GitHub 出包：$tag（约 12~18 分钟）…"
deadline=$(($(date +%s) + 45 * 60))
while :; do
  assets="$(gh release view "$tag" --repo "$gh_repo" --json assets 2>/dev/null || true)"
  case "$assets" in
    *'"name":"app-release.apk"'*) break ;;
  esac
  concl="$(gh run list --repo "$gh_repo" --workflow flutter.yml --limit 20 \
    --json headBranch,conclusion 2>/dev/null \
    | "$PY" -c 'import json,sys
for r in json.load(sys.stdin):
    if r.get("headBranch") == sys.argv[1]:
        print(r.get("conclusion") or ""); break' "$tag" || true)"
  case "$concl" in
    failure | cancelled)
      die "GitHub 那次构建 $concl 了（gh run list --workflow=flutter.yml 看日志）。Gitee 这边没东西可补，修了下个版本重发。"
      ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || die "等了 45 分钟还没出包 —— gh run list --workflow=flutter.yml 看卡在哪。"
  sleep 20
done

# ── 2. 下载（下完就拿它当唯一尺寸基准）────────────────────────────────────────
mkdir -p build
gh release download "$tag" --repo "$gh_repo" --pattern app-release.apk --dir build --clobber \
  || die "下载 app-release.apk 失败"
apk="build/app-release.apk"
size="$(wc -c <"$apk" | tr -d ' ')"
say "已下载：$("$PY" -c 'import sys;print("%.1f MB" % (int(sys.argv[1])/1048576))' "$size")（$size 字节）"

# ── 3. Gitee 上现在是什么状态 ────────────────────────────────────────────────
# 自己读 HTTP 码：401 = 令牌不对，别的错也别混成一个。
# ⚠️ 实测：tag 不存在时 Gitee 回的是 **HTTP 200 + body `null`**，不是 404 —— 就按「没建」处理。
code="$(curl -sS -o build/gitee-rel.json -w '%{http_code}' \
  "$api/releases/tags/$tag_path?access_token=$token" || true)"
rel_id=""
has_apk=""
case "$code" in
  200 | 404) ;;
  401) die "Gitee 说令牌无效（401）：换一个令牌，或用 gitee auth login 重新登录" ;;
  *) die "读 Gitee 发行版失败（HTTP $code）：curl -sS \"$api/releases/tags/$tag?access_token=…\" 看原文" ;;
esac
if [ "$code" = 200 ]; then
  rel_id="$("$PY" -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")) or {}
print(d.get("id", ""))' build/gitee-rel.json)"
  if [ -n "$rel_id" ]; then
    has_apk="$("$PY" -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")) or {}
print("yes" if any((a or {}).get("name") == "app-release.apk" for a in (d.get("assets") or [])) else "")' build/gitee-rel.json)"
    say "Gitee 上已有该发行版（id=$rel_id），附件$([ -n "$has_apk" ] && echo '在' || echo '不在')"
  fi
fi

# ── 4. 需要的话：建发行版（正文整份抄 GitHub 那条，两边文字必须一样）────────────
created=""
cleanup() {
  if [ -n "$created" ] && [ -z "${finished:-}" ]; then
    say "回滚：删掉刚建的这个 Gitee 发行版，免得 App 看到一个点不进去的新版本 …"
    curl -sS -X DELETE "$api/releases/$rel_id?access_token=$token" -o /dev/null \
      || say "  ⚠️ 删不掉，请到 $release_page 手动删掉（否则国内用户会看到点不动的新版本）"
  fi
}
trap cleanup EXIT

if [ -z "$rel_id" ]; then
  gh release view "$tag" --repo "$gh_repo" --json name,body >build/gh-release.json
  "$PY" - "$tag" build/gh-release.json build/rel-name.txt build/rel-body.md <<'PY'
import json, sys

tag, src, name_out, body_out = sys.argv[1:5]
d = json.load(open(src, encoding='utf-8'))
open(name_out, 'w', encoding='utf-8', newline='\n').write(d.get('name') or f'Findr · {tag}')
open(body_out, 'w', encoding='utf-8', newline='\n').write(d.get('body') or '')
PY
  # CI 只镜像 main、不推 tag ⇒ tag 通常还不存在，得让 Gitee 自己建，指向**这个 tag 的那个提交**：
  # 用分支名（main 的当前头）就错位了 —— 发完版 main 上再落一个提交，Gitee 的 tag 会指到它上面，
  # 源码包跟着变。本机 tag 刚推过，`git rev-parse` 拿得到；万一没有就退回默认分支。
  sha="$(git rev-parse -q --verify "$tag^{commit}" 2>/dev/null || true)"
  if [ -z "$sha" ]; then
    branch="$(curl -sS "$api?access_token=$token" \
      | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("default_branch") or "main")')"
  fi
  say "建发行版（tag 指向 ${sha:-Gitee 的 $branch 当前头}）…"
  # 中断后重跑时 tag 可能已经在 Gitee 上了，Gitee 会拒绝带 target_commitish 的建法
  # ⇒ 去掉它再试一次（复用现有 tag）。
  create_release() {
    curl -sS --fail-with-body -X POST "$api/releases" \
      --data-urlencode "access_token=$token" \
      --data-urlencode "tag_name=$tag" \
      --data-urlencode "name@build/rel-name.txt" \
      --data-urlencode "body@build/rel-body.md" \
      --data-urlencode "prerelease=false" \
      "$@" -o build/gitee-new.json
  }
  if ! create_release --data-urlencode "target_commitish=${sha:-$branch}"; then
    say "第一次没建成（tag 可能已在 Gitee 上），去掉 target_commitish 再试一次 …"
    create_release || die "建发行版失败：$(head -c 300 build/gitee-new.json)"
  fi
  rel_id="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["id"])' build/gitee-new.json)"
  created=1
  say "发行版已建（id=$rel_id）"
fi

# ── 5. 上传附件 → 核对字节数 ────────────────────────────────────────────────
remote_size() {
  curl -sSIL "$download_url" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }'
}

if [ "${has_apk:-}" = "yes" ]; then
  now="$(remote_size)"
  if [ "$now" = "$size" ]; then
    say "Gitee 上已经挂着同样大小的附件，跳过上传"
  else
    die "Gitee 上那份附件是 $now 字节，本地是 $size 字节 —— 上次传了半截。
      到 $release_page 删掉那份 app-release.apk 再重跑这条命令。"
  fi
else
  say "上传中（国内链路，几秒）…"
  t0=$(date +%s)
  curl -sS --fail-with-body -X POST "$api/releases/$rel_id/attach_files" \
    -F "access_token=$token" -F "file=@$apk" -o build/gitee-upload.json \
    || die "上传失败：$(head -c 300 build/gitee-upload.json)"
  say "上传耗时 $(( $(date +%s) - t0 )) 秒"
  # 刚传完 CDN 可能还没刷新，给三次机会
  now=0
  for _ in 1 2 3; do
    now="$(remote_size)"
    if [ "$now" = "$size" ]; then
      break
    fi
    sleep 3
  done
  [ "$now" = "$size" ] || die "上传后核对字节数没对上（远端 $now / 本地 $size）—— 稍等再重跑一次"
  say "附件校验通过：$size 字节"
fi
finished=1

# ── 6. 收拾 Gitee 上的旧发行版 ──────────────────────────────────────────────
# 社区版硬顶（help.gitee.com/account/usage-quota）：单附件 ≤100MB、**单仓库附件总量 1G**。
# 一个包 21MB，不清理的话四十来版就传不上去了（GitHub 那边没有总量限制，历史全留）。
# 顺带删「附件里没有 app-release.apk 的空壳」：中断、回滚失败、手滑建的都算，它们会让
# App 弹一个下不动的更新。列表接口按时间**正序**返回（最旧在前），别指望它倒序。
# 删失败不判红：这一版该发的已经发完了，额度问题下次自会报错。
say "整理旧发行版（保留最新 10 个，顺手清掉空壳）…"
"$PY" - "$api" "$token" "$rel_id" <<'PY' || say "整理没成功（不影响这一版）"
import json, subprocess, sys

api, token, cur = sys.argv[1], sys.argv[2], sys.argv[3]
keep = 10


def call(*args):
    return subprocess.run(['curl', '-sS', '-f', *args], capture_output=True, text=True)


out = call(f'{api}/releases?per_page=100&access_token={token}').stdout
try:
    releases = json.loads(out)
except Exception:
    releases = None
if not isinstance(releases, list):
    print('读不到发行版列表，跳过这次整理')
    raise SystemExit(0)

releases.sort(key=lambda r: r['created_at'], reverse=True)


def has_apk(r):
    return any((a or {}).get('name') == 'app-release.apk' for a in (r.get('assets') or []))


def delete(r, what):
    # 别加 -o /dev/null：Windows 版 curl 认不出这个路径，会先报错再返回非零（请求其实已经发了）
    ok = call('-X', 'DELETE', f'{api}/releases/{r["id"]}?access_token={token}').returncode == 0
    print(('删掉' + what + ' ' if ok else what + '没删掉（不影响这一版） ') + r['tag_name'])
    return ok


ghosts = [r for r in releases if str(r['id']) != cur and not has_apk(r)]
for r in ghosts:
    delete(r, '空壳发行版')
rest = [r for r in releases if r not in ghosts]
for r in rest[keep:]:
    delete(r, '旧发行版')
print(f'Gitee 发行版共 {len(rest)} 个，保留最新 {min(len(rest), keep)} 个')
PY

say ""
say "完成：$release_page"
say "  App 的「检查更新」现在能看到 $tag 了。"
