#Requires -Version 5.1
<#
    agent-mail / install.ps1
    ------------------------------------------------------------------
    把 skill/ 安装到 ~/.agents/skills/agently-mail-watch/，
    并在 ~/.agently-mail-watch/ 生成配置模板。

    只安装，不启用。启用请手动执行 watch.cmd enable。

    用法：
        .\install.ps1
        .\install.ps1 -Force              # 覆盖已存在的脚本
        .\install.ps1 -SkillRoot <path>   # 换 skill 安装根目录
#>
[CmdletBinding()]
param(
    [string]$SkillRoot = (Join-Path $env:USERPROFILE '.agents\skills'),
    [string]$RuntimeDir = (Join-Path $env:USERPROFILE '.agently-mail-watch'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source  = Join-Path $Here 'skill'
$Target  = Join-Path $SkillRoot 'agently-mail-watch'

if (-not (Test-Path $Source)) { throw "找不到 skill 源目录：$Source" }

Write-Host '=== agent-mail 安装器 ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- 依赖自检
Write-Host ''
Write-Host '[1/4] 检查依赖'

$missing = @()
foreach ($cmd in @('node', 'npm')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
}

$cli = Get-Command agently-cli -ErrorAction SilentlyContinue
if (-not $cli) { $missing += 'agently-cli' }

if ($missing.Count -gt 0) {
    Write-Host ("  [缺失] " + ($missing -join ', ')) -ForegroundColor Yellow
    Write-Host '  请先执行：' -ForegroundColor Yellow
    Write-Host '    npm install -g @tencent-qqmail/agently-cli' -ForegroundColor Yellow
    Write-Host '    npx skills add https://agent.qq.com --skill -g -y' -ForegroundColor Yellow
    Write-Host '    agently-cli auth login' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  依赖没齐也可以继续安装，但轮询跑不起来。' -ForegroundColor Yellow
} else {
    Write-Host '  [OK] node / npm / agently-cli 均可用'
    # agently-cli 会往 stderr 写 tip:；EAP=Stop 下会被当成终止性错误，这里降级处理
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $meRaw = (& agently-cli +me 2>$null | Out-String)
        $me = $meRaw | ConvertFrom-Json
        if ($me.ok -and @($me.data.aliases).Count -gt 0) {
            Write-Host ("  [OK] 已授权邮箱：{0}" -f $me.data.aliases[0].email)
        } else {
            Write-Host '  [警告] agently-cli 尚未授权，请先执行 agently-cli auth login' -ForegroundColor Yellow
        }
    } catch {
        Write-Host '  [警告] agently-cli +me 调用失败，确认已完成 OAuth 授权。' -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# ---------------------------------------------------------------- 安装脚本
Write-Host ''
Write-Host '[2/4] 安装 skill'
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }

$files = @('SKILL.md', 'poller.ps1', 'watch.ps1', 'watch.cmd', 'README.md')
foreach ($f in $files) {
    $src = Join-Path $Source $f
    $dst = Join-Path $Target $f
    if (-not (Test-Path $src)) { Write-Host "  [跳过] 源缺失 $f" -ForegroundColor Yellow; continue }
    if ((Test-Path $dst) -and -not $Force) {
        Write-Host "  [保留] $f（已存在，用 -Force 覆盖）" -ForegroundColor DarkGray
        continue
    }
    Copy-Item $src $dst -Force
    Write-Host "  [写入] $f"
}
Write-Host "  → $Target"

# ---------------------------------------------------------------- 运行时目录
Write-Host ''
Write-Host '[3/4] 准备运行时目录'
foreach ($d in @($RuntimeDir, (Join-Path $RuntimeDir 'logs'),
                 (Join-Path $RuntimeDir 'inbox'), (Join-Path $RuntimeDir 'outbox'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$settingsPath = Join-Path $RuntimeDir 'settings.json'
if (Test-Path $settingsPath) {
    Write-Host "  [保留] settings.json（已存在，未覆盖）" -ForegroundColor DarkGray
} else {
    # 直接写字面量而不是 ConvertTo-Json：PS 5.1 会把空数组序列化成带空行的
    # 难看形式，而这个文件用户要手工编辑。
    $template = @'
{
  "trustedSenders": [],
  "selfAddresses": [],
  "receiptSubjectPrefix": "[Agent Mail]",
  "pollSeconds": 30,
  "maxPerCycle": 5,
  "agentTimeoutSec": 900,
  "sendReceipt": true,
  "receiptTo": "",
  "historyLimit": 500,
  "processExistingOnFirstRun": false
}
'@
    [System.IO.File]::WriteAllText($settingsPath, $template, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  [生成] settings.json"
}
Write-Host "  → $RuntimeDir"

# ---------------------------------------------------------------- 后续步骤
Write-Host ''
Write-Host '[4/4] 完成'
Write-Host ''
Write-Host '还需两步才能真正跑起来：' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1) 填授权发件人（必填，留空会拒绝启动）：'
Write-Host "     notepad `"$settingsPath`""
Write-Host '     把 trustedSenders 改成你自己的另一个邮箱，例如：'
Write-Host '       "trustedSenders": ["my-other-inbox@example.com"]'
Write-Host ''
Write-Host '  2) 启用轮询：'
Write-Host "     cd `"$Target`""
Write-Host '     .\watch.cmd enable'
Write-Host ''
Write-Host '  ⚠ 启用即意味着：任何能伪造该发件人地址的人都能让本机自动执行邮件内容。'
Write-Host '     详见 docs/SECURITY.md'
Write-Host ''
