#Requires -Version 5.1
<#
    agently-mail-watch / watch.ps1
    ------------------------------------------------------------------
    常驻轮询程序的控制面板。

        watch.ps1 enable     启用：开机自启 + 立即启动轮询
        watch.ps1 disable    停用：移除自启 + 停止轮询 + 落 DISABLED 标记
        watch.ps1 start      只启动（不设自启）
        watch.ps1 stop       只停止
        watch.ps1 status     查看状态
        watch.ps1 logs [n]   查看最近 n 行日志（默认 40）
        watch.ps1 run-once   前台跑一轮，用于排错
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'status',
    [Parameter(Position = 1)][int]$Tail = 40
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Poller      = Join-Path $ScriptDir 'poller.ps1'
$RuntimeDir  = Join-Path $env:USERPROFILE '.agently-mail-watch'
$LogDir      = Join-Path $RuntimeDir 'logs'
$PidPath     = Join-Path $RuntimeDir 'poller.pid'
$Disabled    = Join-Path $RuntimeDir 'DISABLED'
$StatePath   = Join-Path $RuntimeDir 'state.json'
$RunKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue    = 'AgentlyMailWatch'
$PowerShell  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null }

function Get-PollerProcess {
    if (-not (Test-Path $PidPath)) { return $null }
    $txt = Get-Content $PidPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    $procId = 0
    if (-not [int]::TryParse($txt.Trim(), [ref]$procId)) { return $null }
    return (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}

function Test-Autostart {
    $v = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue).$RunValue
    return (-not [string]::IsNullOrWhiteSpace($v))
}

function Start-Poller {
    if (Get-PollerProcess) { Write-Host '轮询已在运行。'; return }
    if (Test-Path $Disabled) { Remove-Item $Disabled -Force }

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $Poller + '"'))
    Start-Process -FilePath $PowerShell -ArgumentList $psArgs -WindowStyle Hidden | Out-Null

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        if (Get-PollerProcess) { break }
    }
    if (Get-PollerProcess) {
        Write-Host "[OK] 轮询已启动 (pid $((Get-Content $PidPath -Raw).Trim()))"
    } else {
        Write-Host '[WARN] 启动后未检测到 pid 文件，请用 status / logs 排查。'
    }
}

function Stop-Poller {
    $p = Get-PollerProcess
    if (-not $p) {
        Write-Host '轮询未在运行。'
        Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
        return
    }
    try {
        Stop-Process -Id $p.Id -Force
        Write-Host "[OK] 已停止轮询 (pid $($p.Id))"
    } catch {
        Write-Host "[WARN] 停止失败：$($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 400
    Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
}

function Set-Autostart {
    param([bool]$On)
    if ($On) {
        $cmd = '"' + $PowerShell + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Poller + '"'
        Set-ItemProperty -Path $RunKey -Name $RunValue -Value $cmd
        Write-Host '[OK] 已设置开机自启。'
    } else {
        Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
        Write-Host '[OK] 已移除开机自启。'
    }
}

function Show-Status {
    $p = Get-PollerProcess
    Write-Host '=== agently-mail-watch 状态 ==='
    if ($p) {
        Write-Host ("  轮询进程   : 运行中 (pid {0}，启动于 {1})" -f $p.Id, $p.StartTime)
    } else {
        Write-Host '  轮询进程   : 未运行'
    }
    if (Test-Path $Disabled) {
        Write-Host '  DISABLED   : 存在（轮询被硬性停用）'
    } else {
        Write-Host '  DISABLED   : 不存在'
    }
    if (Test-Autostart) { Write-Host '  开机自启   : 已启用' } else { Write-Host '  开机自启   : 未启用' }

    if (Test-Path $StatePath) {
        try {
            $s = (Get-Content $StatePath -Raw -Encoding UTF8) | ConvertFrom-Json
            Write-Host ("  已处理计数 : {0}" -f $s.processedCount)
            Write-Host ("  最近轮询   : {0}" -f $s.lastPoll)
            Write-Host ("  已登记邮件 : {0} 条" -f @($s.seen).Count)
        } catch { }
    } else {
        Write-Host '  状态文件   : 尚未生成（未跑过）'
    }

    $today = Join-Path $LogDir ('poller-' + (Get-Date).ToString('yyyyMMdd') + '.log')
    if (Test-Path $today) {
        $last = Get-Content $today -Tail 1
        Write-Host ("  最新日志   : {0}" -f $last)
    }
}

function Show-Logs {
    param([int]$Lines = 40)
    $files = @(Get-ChildItem $LogDir -Filter 'poller-*.log' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { Write-Host '暂无日志。'; return }
    $latest = $files[-1]
    Write-Host "=== $($latest.FullName) (最近 $Lines 行) ==="
    Get-Content $latest.FullName -Tail $Lines -Encoding UTF8
}

switch ($Action.ToLowerInvariant()) {
    'enable' {
        Set-Autostart -On $true
        Start-Poller
        Show-Status
    }
    'disable' {
        Set-Autostart -On $false
        New-Item -ItemType File -Path $Disabled -Force | Out-Null
        Stop-Poller
        Write-Host '[OK] 已停用（DISABLED 标记已落下，轮询不会自动重启）。'
    }
    'start' { Start-Poller }
    'stop'  { Stop-Poller }
    'status' { Show-Status }
    'logs'  { Show-Logs -Lines $Tail }
    'run-once' {
        Write-Host '前台单轮运行（Ctrl+C 可中断）...'
        & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Poller -Once -ProcessExisting
    }
    default {
        Write-Host '用法: watch.ps1 {enable|disable|start|stop|status|logs [n]|run-once}'
    }
}
