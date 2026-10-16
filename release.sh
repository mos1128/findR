#!/usr/bin/env bash
# findR 的发布脚本（仓库根手动跑）—— 把「改版本号 → 写更新说明 → 提交 → 打 tag → 推 GitHub」收成一条命令。
#
#   用法：bash release.sh                # 正常发布（先跑本地验收网）
#         SKIP_TESTS=1 bash release.sh   # 跳过本地验收网（赶时间时用）
#
# 推完 GitHub Actions 会自动：构建 APK → 发 GitHub 发布 → 镜像代码到 Gitee → 在 Gitee 建发行版
# （同一个 tag、同一个包，见 .github/workflows/flutter.yml）。**本地不需要配 Gitee 凭据。**
#
# ⚠️ 与 App 的「检查更新」绑死的约定：**一版一 tag**，tag = `v` + pubspec 的版本号
#    （`0.1.0+2` → `v0.1.0+2`）。所以每次发布**版本号必须变大**（只动 `+` 后面那半也算）——
#    本脚本会挡「同版本重发」与「版本反而变小」，这两种都会让用户那边根本看不到更新。
#
# 更新说明（你在本脚本里手写的那段）会写进 **tag 的注释**；CI 把它读出来当发布页正文
# （Gitee 与 GitHub 用同一份），App 的「发现新版本」弹窗显示的也是它。
#
# ⚠️ CI 里那一步「镜像代码到 Gitee」等于**把代码放到公开的 Gitee 仓库**（开源）。不想要就删掉
#    workflow 里的那一步（口径见《开发指南》5.6）。
set -euo pipefail

cd "$(dirname "$0")"

MAIN_BRANCH="main"
FLUTTER_BIN_DIR="/d/my-software/scoop/apps/flutter/current/bin"

say() { printf '%s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

say "========================================"
say "  findR 发布"
say "========================================"
say ""

# ── 1/5 前置：工作区干净、在 main 上 ─────────────────────────────────────────
git diff --quiet && git diff --cached --quiet \
  || die "工作区有未提交的改动，先提交或 stash（发布提交只该包含版本号那一行）"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "$MAIN_BRANCH" ] || die "当前在 $branch 分支上；发布只在 $MAIN_BRANCH 上做"
say "[1/5] 工作区干净，在 $MAIN_BRANCH 上；远端 origin=$(git remote get-url origin)"

# ── 2/5 版本号：给建议值、验格式、要求变大、挡住重发 ─────────────────────────
current="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"
[ -n "$current" ] || die "pubspec.yaml 里读不到 version 行"
suggested="$(awk -F'+' '{ printf "%s+%d", $1, ($2 == "" ? 1 : $2 + 1) }' <<<"$current")"

say ""
say "当前版本：$current    建议下一个：$suggested"
read -rp "新版本号（回车用建议值，格式 X.Y.Z+N）：" input
version="${input:-$suggested}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] \
  || die "版本号格式不对：$version —— 要 X.Y.Z+N（例如 0.1.0+2）"

# 版本比较：把 `0.1.0+2` 折成定宽数字串再按数值比（段长超过 4 位时按原样保留，够我们用）
version_key() {
  awk -F'+' '{
    n = split($1, p, ".");
    k = "";
    for (i = 1; i <= n; i++) k = k sprintf("%04d", p[i]);
    printf "%s%04d", k, ($2 == "" ? 0 : $2);
  }' <<<"$1"
}
[ "$(version_key "$version")" -gt "$(version_key "$current")" ] \
  || die "新版本 $version 不比当前 $current 大 —— App 只认「比本机新」的版本（把 + 后面那半改大也算）"

git tag -l "v$version" | grep -q . && die "本地已有 tag v$version（同一个版本不能发两次）"
if tags="$(git ls-remote --tags origin 2>/dev/null)"; then
  printf '%s\n' "$tags" | grep -qF "refs/tags/v$version" \
    && die "origin 上已有 tag v$version（同一个版本不能发两次）"
else
  say "  ⚠️ origin 暂时连不上，跳过远端的 tag 检查"
fi
say "[2/5] 版本检查通过：$current → $version"

# 更新说明：写进 tag 注释（CI 读它当发布页正文）。连着敲 3 个空行结束；不写就空按三次。
say ""
say "更新说明（会出现在发布页与 App 的更新弹窗里；连着敲 3 个空行结束）："
notes=""
blanks=0
while IFS= read -r line; do
  if [ -z "$line" ]; then
    blanks=$((blanks + 1))
    [ "$blanks" -ge 3 ] && break
    [ -n "$notes" ] && notes="$notes
$line"
  else
    blanks=0
    if [ -z "$notes" ]; then
      notes="$line"
    else
      notes="$notes
$line"
    fi
  fi
done
# 去掉结尾的空行（循环最多只会留两行）
notes="$(printf '%s\n' "$notes" | awk 'NF { last = NR } { line[NR] = $0 } END { for (i = 1; i <= last; i++) print line[i] }')"
[ -n "$notes" ] || notes="（本次没有更新说明）"

# ── 3/5 本地验收网（CI 不跑测试，测试就靠这里；先跑，省得白等十几分钟构建）─────────
if [ "${SKIP_TESTS:-0}" = "1" ]; then
  say "[3/5] 按 SKIP_TESTS=1 跳过本地验收网"
else
  if ! command -v flutter >/dev/null 2>&1 && [ -x "$FLUTTER_BIN_DIR/flutter" ]; then
    # scoop 装的 Flutter 只在新的用户环境里进 PATH；git bash 里要显式加（见《开发指南》3.2）
    export PATH="$FLUTTER_BIN_DIR:$PATH"
  fi
  if ! command -v flutter >/dev/null 2>&1; then
    say "[3/5] ⚠️ 找不到 flutter 命令，跳过本地验收网 —— 这一版不会有任何测试把关（CI 也不跑测试）"
  else
    say "[3/5] 本地验收网：core 分析 + 测试，app 分析 + 测试"
    ( cd packages/findr_core && dart analyze && dart test )
    flutter analyze
    flutter test
  fi
fi

# ── 4/5 确认（这一步就是「停一下」）────────────────────────────────────────────
say ""
say "========================================"
say "  发布  v$version"
say "  说明  （写进 tag 注释；发布页与 App 的更新弹窗都用它）"
printf '%s\n' "$notes" | sed 's/^/        /'
say "  提交  chore: 发布 v$version"
say "  推送  origin（$MAIN_BRANCH + tag）"
say "  之后  CI 自动：构建 → 发 GitHub 发布 → 镜像代码到 Gitee → 建 Gitee 发行版"
say "  ⚠️ 推完 GitHub 立刻开始构建（十几分钟）；这期间别再改这一版"
say "========================================"
read -rp "确认发布？(y/N)：" ok
case "$ok" in
  y | Y) ;;
  *) say "[已取消]"; exit 0 ;;
esac

# ── 5/5 写版本号 → 提交 → 打 tag → 推 GitHub（这一步触发 CI）──────────────────
say "[5/5] 写入版本号、提交、打 tag、推 GitHub …"
sed -i "s/^version: .*/version: $version/" pubspec.yaml
git add pubspec.yaml
git commit -m "chore: 发布 v$version"
git tag -a "v$version" --cleanup=whitespace -m "$notes"
git push origin "$MAIN_BRANCH"
git push origin "v$version"

say ""
say "========================================"
say "  v$version 已推送，CI 正在构建："
say "    看进度：gh run list --workflow=flutter.yml"
say "    发布处：GitHub 自动发；Gitee 的代码与发行版由 CI 同步（同一个 tag、同一个包）"
say "========================================"
