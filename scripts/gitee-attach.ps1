# 把 GitHub 上已经发出的 app-release.apk 补挂到 Gitee 发行版，然后把它从「预发布」翻成正式。
#
# 为什么这一步在本地：GitHub 的 runner 在境外，往 gitee.com 传 22MB 实测 1.9~20 KB/s
# （18~90 分钟，还经常 curl: (56) 断在半路）；从国内宽带传只要十几秒。
# 所以 workflow 只建「预发布」发行版、不传附件 —— 附件没到位时 App 的「检查更新」看不见这一版，
# 而不是弹窗能点、点进去 404。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/gitee-attach.ps1 -Tag v1.0.14
#      release.sh 末尾会自动调；忘了跑、或上次断在半路时单独重跑 —— 脚本是幂等的。
#
# 令牌按顺序取，取不到就报错（脚本不会自己存一份）：$env:GITEE_TOKEN → `gitee auth token`
param(
    [Parameter(Mandatory)][string]$Tag,
    [string]$GiteeRepo = 'ms6/findR'
)
$ErrorActionPreference = 'Stop'
# 报错只留一句人话（默认会把 CategoryInfo / FullyQualifiedErrorId 那一坨也倒出来）
trap { Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$api = "https://gitee.com/api/v5/repos/$GiteeRepo"
$page = "https://gitee.com/$GiteeRepo/releases/tag/$Tag"

# 远程附件大小：HEAD 下载地址拿 content-length。
# （Gitee 的发行版 JSON 里**没有** size 字段，只有 name 和 browser_download_url。）
function Get-RemoteSize([string]$Url) {
    $m = & curl.exe -sSIL $Url | Select-String '^content-length:\s*(\d+)' | Select-Object -Last 1
    if ($m) { [long]$m.Matches[0].Groups[1].Value } else { -1 }
}

# 按 tag 取发行版。自己读 HTTP 状态码而不是 --fail-with-body：
# 404（发行版没建）和 401（令牌不对）要给两套完全不同的提示。
function Get-GiteeRelease {
    $out = @(& curl.exe -sS -w "`n%{http_code}" "$api/releases/tags/$([uri]::EscapeDataString($Tag))?access_token=$token")
    $code = $out[-1]
    $body = if ($out.Count -gt 1) { ($out[0..($out.Count - 2)] -join "`n") } else { '' }
    if ($code -eq '404') {
        throw "Gitee 上没有 $Tag 的发行版（多半是 CI 里「建 Gitee 发行版」那步红了）。先去 $page 手动按同一个 tag 建一个，再重跑本脚本。"
    }
    if ($code -ne '200') {
        throw "Gitee 拒绝了请求（HTTP $code）：$($body.Trim())`n多半是令牌失效或没勾 projects。"
    }
    $body | ConvertFrom-Json
}

$token = $env:GITEE_TOKEN
if (-not $token -and (Get-Command gitee -ErrorAction SilentlyContinue)) {
    $token = & gitee auth token 2>$null | Select-Object -First 1
}
if (-not $token) {
    throw @"
本机没有 Gitee 令牌。配一次就行（换设备后要重配）：
  A. npm i -g @gitee/gitee-cli，再跑 gitee auth login    ← 令牌存进 ~/.config/gitee，脚本从 CLI 取
  B. setx GITEE_TOKEN 你的令牌，然后重开终端             ← 令牌在 Gitee → 设置 → 私人令牌，权限只勾 projects
"@
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw '找不到 gh 命令（GitHub CLI）' }

$ghRepo = (git remote get-url origin) -replace '^.*github\.com[:/]', '' -replace '\.git$', ''

# ── 1. 等 GitHub 出包 ────────────────────────────────────────────────────────
# 盯 release 的附件而不是盯 workflow run：真正要等的是那个包。同时看 run 结论，
# 构建红了就立刻退出，不陪着白等 45 分钟。
Write-Host "等 GitHub 出包：$Tag（约 12~18 分钟）…"
$deadline = (Get-Date).AddMinutes(45)
while ($true) {
    $json = & gh release view $Tag --repo $ghRepo --json assets 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) {
        if ((($json | ConvertFrom-Json).assets | Where-Object { $_.name -eq 'app-release.apk' })) { break }
    }
    $runs = & gh run list --repo $ghRepo --workflow flutter.yml --limit 20 --json headBranch,conclusion 2>$null | ConvertFrom-Json
    $run = $runs | Where-Object { $_.headBranch -eq $Tag } | Select-Object -First 1
    if ($run.conclusion -in 'failure', 'cancelled') {
        throw "GitHub 那次构建 $($run.conclusion) 了（gh run list --workflow=flutter.yml 看日志）。Gitee 这边没东西可补，修了下个版本重发。"
    }
    if ((Get-Date) -gt $deadline) { throw "等了 45 分钟还没出包 —— gh run list --workflow=flutter.yml 看卡在哪。" }
    Start-Sleep -Seconds 20
}

# ── 2. 下载 ─────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force build | Out-Null
& gh release download $Tag --repo $ghRepo --pattern app-release.apk --dir build --clobber
if ($LASTEXITCODE -ne 0) { throw '下载 app-release.apk 失败' }
$apk = (Resolve-Path build/app-release.apk).Path
$size = (Get-Item $apk).Length
Write-Host ('已下载：{0:N1} MB' -f ($size / 1MB))

# ── 3. 传附件 ───────────────────────────────────────────────────────────────
$rel = Get-GiteeRelease
$dlUrl = "https://gitee.com/$GiteeRepo/releases/download/$Tag/app-release.apk"

# 「预发布」是这一步的隐藏机制：App 读的是 /releases/latest，按说它跳过预发布，
# 所以附件没挂上时用户看不到新版。这条假设只用一行日志兜住 —— 万一 Gitee 不跳过，
# 会在这里留下证据（那几秒/几分钟里点更新的人会 404）。
if ($rel.prerelease) {
    $latest = (& curl.exe -sS "https://gitee.com/api/v5/repos/$GiteeRepo/releases/latest" | ConvertFrom-Json).tag_name
    if ($latest -eq $Tag) { Write-Host "注意：/releases/latest 已经指向 $Tag，预发布没被跳过 —— 本轮传完前 App 会点到 404" }
}

if ($rel.assets | Where-Object { $_.name -eq 'app-release.apk' }) {
    if ((Get-RemoteSize $dlUrl) -eq $size) {
        Write-Host 'Gitee 上已经挂着同样大小的附件，跳过上传'
    }
    else {
        throw "Gitee 上有同名附件但大小对不上（上次传了半截？）。先到 $page 删掉那份 app-release.apk，再重跑本脚本。"
    }
}
else {
    Write-Host '上传中（国内链路，十几秒）…'
    & curl.exe -sS --fail-with-body -X POST "$api/releases/$($rel.id)/attach_files" `
        -F "access_token=$token" -F "file=@$apk" -o NUL `
        -w "上传耗时 %{time_total}s，平均 %{speed_upload} B/s`n"
    if ($LASTEXITCODE -ne 0) { throw '上传失败。重跑本脚本即可，它不会传第二份。' }
    $remote = Get-RemoteSize $dlUrl
    if ($remote -lt 0) {
        Write-Host '警告：HEAD 没读到 content-length，附件已传但没能核对大小 —— 到发行版页看一眼'
    }
    elseif ($remote -ne $size) {
        throw "传上去的大小不对（本地 $size，Gitee $remote）。到 $page 删掉那份附件再重跑。"
    }
    else {
        Write-Host "附件校验通过：$remote 字节"
    }
}

# ── 4. 翻成正式（App 的「检查更新」到这一刻才看得见新版）────────────────────
# ⚠️ Gitee 的这个接口要求把 tag_name / name / body 一起带上（只改 prerelease 会被打回），
#    正文按原样回填，不动发行版内容。
if ($rel.prerelease) {
    $payload = @{ tag_name = $rel.tag_name; name = $rel.name; body = $rel.body; prerelease = $false } | ConvertTo-Json
    $tmp = New-TemporaryFile
    # 用 .NET 写 UTF-8 无 BOM：带 BOM 的 JSON 会让 Gitee 解析失败，而 Windows PowerShell 5.1 的
    # `-Encoding utf8` 恰好带 BOM。
    [IO.File]::WriteAllText($tmp, $payload, (New-Object System.Text.UTF8Encoding $false))
    & curl.exe -sS --fail-with-body -X PATCH "$api/releases/$($rel.id)?access_token=$token" `
        -H 'Content-Type: application/json' --data-binary "@$tmp" -o NUL
    Remove-Item -LiteralPath $tmp
    if ($LASTEXITCODE -ne 0) { throw '把发行版翻成正式失败（附件已经在了，重跑本脚本只重试这一步）' }

    # Gitee 时不时用 200 + 错误信封回应（gitee-cli 的 apiErrorEnvelope 就是为这个留的），
    # 所以得回读一次确认，别信 200。
    if ((Get-GiteeRelease).prerelease) { throw "发行版还是预发布状态。到 $page 网页上手动取消「预发布」。" }
}

Write-Host ''
Write-Host "完成：$page"
Write-Host "  App 的「检查更新」现在能看到 $Tag 了。"
