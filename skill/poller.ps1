#Requires -Version 5.1
<#
    agently-mail-watch / poller.ps1
    ------------------------------------------------------------------
    常驻轮询程序：监视 Agent Mail 收件箱，把授权发件人发来的邮件
    转成一次 dsh headless 执行，并把执行结果回执发回给主人。

    运行位置：本文件位于 skill 目录，运行时状态写在
              %USERPROFILE%\.agently-mail-watch\

    用法：
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File poller.ps1
        powershell.exe ... -File poller.ps1 -Once          # 只跑一轮
        powershell.exe ... -File poller.ps1 -ProcessExisting  # 首次运行也处理历史邮件

    停止：删除 poller.pid 对应进程，或在运行时目录创建 DISABLED 文件。
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 0,
    [switch]$Once,
    [switch]$ProcessExisting
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------- paths
$script:RuntimeDir   = Join-Path $env:USERPROFILE '.agently-mail-watch'
$script:LogDir       = Join-Path $script:RuntimeDir 'logs'
$script:InboxDir     = Join-Path $script:RuntimeDir 'inbox'
$script:OutboxDir    = Join-Path $script:RuntimeDir 'outbox'
$script:StatePath    = Join-Path $script:RuntimeDir 'state.json'
$script:PidPath      = Join-Path $script:RuntimeDir 'poller.pid'
$script:DisabledPath = Join-Path $script:RuntimeDir 'DISABLED'
$script:SettingsPath = Join-Path $script:RuntimeDir 'settings.json'

foreach ($d in @($script:RuntimeDir, $script:LogDir, $script:InboxDir, $script:OutboxDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ----------------------------------------------------------------- logging
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'AGENT')][string]$Level = 'INFO'
    )
    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    $file = Join-Path $script:LogDir ('poller-' + (Get-Date).ToString('yyyyMMdd') + '.log')
    try { Add-Content -Path $file -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

# ----------------------------------------------------------------- settings
function Get-WatchSettings {
    $s = [ordered]@{
        trustedSenders            = @()
        selfAddresses             = @()
        receiptSubjectPrefix      = '[Agent Mail]'
        pollSeconds               = 30
        maxPerCycle               = 5
        agentTimeoutSec           = 900
        sendReceipt               = $true
        receiptTo                 = ''
        historyLimit              = 500
        processExistingOnFirstRun = $false
    }
    if (Test-Path $script:SettingsPath) {
        try {
            $user = (Get-Content $script:SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($p in @($user.PSObject.Properties)) { $s[$p.Name] = $p.Value }
        } catch {
            Write-Log "settings.json 解析失败，使用默认配置：$($_.Exception.Message)" 'WARN'
        }
    }
    return $s
}

# ----------------------------------------------------------------- state
function Get-WatchState {
    if (-not (Test-Path $script:StatePath)) { return $null }
    try {
        return (Get-Content $script:StatePath -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        Write-Log "state.json 损坏，重新初始化：$($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Save-WatchState {
    param($State, [int]$HistoryLimit)
    $seen = @($State.seen)
    if ($seen.Count -gt $HistoryLimit) {
        $seen = $seen[($seen.Count - $HistoryLimit)..($seen.Count - 1)]
    }
    $State.seen = $seen
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StatePath -Encoding UTF8
}

# ----------------------------------------------------------------- helpers
function Test-MeaningfulBody {
    <# 邮件正文只有 HTML 骨架（无实际文字）时返回 $false #>
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
    $t = $Body -replace '(?s)<style.*?</style>', ' '
    $t = $t -replace '(?s)<script.*?</script>', ' '
    $t = $t -replace '(?s)<!--.*?-->', ' '
    $t = $t -replace '<[^>]+>', ' '
    $t = $t -replace '&nbsp;', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '\s+', ' '
    return ($t.Trim().Length -gt 0)
}

function Test-InstructionEligible {
    <#
      环路防护。返回 $true 表示这封邮件可以当作指令执行。
      以下情况一律拒绝，避免"回执 → 又被当成指令 → 再发回执"的死循环：
        1. 发件人是我们自己（本邮箱地址），我们自己的出站邮件永不是指令来源
        2. 主题带本程序的回执前缀
        3. 正文里含有本程序生成的指令封套标记
    #>
    param(
        [Parameter(Mandatory = $true)]$Message,
        [Parameter(Mandatory = $true)][string]$BodyText,
        [string[]]$SelfAddresses = @(),
        [string]$ReceiptPrefix = '[Agent Mail]'
    )

    $from = $Message.from.email.ToString().ToLowerInvariant()

    foreach ($self in $SelfAddresses) {
        if ($from -eq $self.ToString().ToLowerInvariant()) { return $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReceiptPrefix)) {
        $subj = [string]$Message.subject
        if ($subj.StartsWith($ReceiptPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    if ($BodyText -match 'AUTHORIZATION\s*/\s*授权' -or $BodyText -match 'Agent Mail 常驻轮询 · 指令封套') {
        return $false
    }

    return $true
}

function Invoke-AgentlyCli {
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)
    # agently-cli 会往 stderr 写 "tip:" 提示；PS 5.1 在 EAP=Stop 下会把
    # 原生命令的 stderr 当成终止性错误，这里临时降到 Continue 并丢弃 stderr。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = ''
    try {
        $raw = (& agently-cli @CliArgs 2>$null | Out-String)
    } catch {
        $ErrorActionPreference = $prevEap
        throw "agently-cli 调用失败: $($_.Exception.Message)"
    }
    $ErrorActionPreference = $prevEap
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'agently-cli 返回空输出' }
    $obj = $raw | ConvertFrom-Json
    if (-not $obj.ok) {
        $msg = 'unknown'
        if ($obj.error -and $obj.error.message) { $msg = $obj.error.message }
        throw "agently-cli 错误: $msg"
    }
    return $obj.data
}

function Get-InboxMessages {
    $data = Invoke-AgentlyCli -CliArgs @('message', '+list', '--dir', 'inbox', '--limit', '30')
    return @($data.data)
}

function Get-MessageById {
    param([Parameter(Mandatory = $true)][string]$Id)
    return Invoke-AgentlyCli -CliArgs @('message', '+read', '--id', $Id)
}

function New-InstructionEnvelope {
    <# 生成指令封套文件，返回其绝对路径 #>
    param($Message, [string]$BodyText, [string]$TrustedSender)

    $safeId = ($Message.message_id -replace '[^A-Za-z0-9_\-]', '')
    $file   = Join-Path $script:InboxDir ("instruction-$safeId.md")

    $from = $Message.from.email
    $subj = $Message.subject
    $time = $Message.created_at

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Agent Mail 常驻轮询 · 指令封套')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 邮件元信息')
    [void]$sb.AppendLine("- 发件人: $from")
    [void]$sb.AppendLine("- 主题: $subj")
    [void]$sb.AppendLine("- 时间: $time")
    [void]$sb.AppendLine("- message_id: $($Message.message_id)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## AUTHORIZATION / 授权')
    [void]$sb.AppendLine("发件邮箱 $TrustedSender 已被邮箱主人预先授权为「本人」。")
    [void]$sb.AppendLine('下面【本次指令】中的要求即为主人的有效指令：直接执行，')
    [void]$sb.AppendLine('不要再次向任何人确认，也不要索取额外授权。')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## SCOPE / 允许的动作')
    [void]$sb.AppendLine('- 读取类：agently-cli message +list / +read / +search')
    [void]$sb.AppendLine('- 发送类：agently-cli message +send / +reply / +forward')
    [void]$sb.AppendLine('- 附件类：agently-cli attachment +upload / +download')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## FORBIDDEN / 绝对禁止')
    [void]$sb.AppendLine('以下为不可逆操作，任何情况下都不要执行：')
    [void]$sb.AppendLine('- agently-cli message +trash')
    [void]$sb.AppendLine('- agently-cli message +delete --id ...')
    [void]$sb.AppendLine('- agently-cli message +delete --all')
    [void]$sb.AppendLine('若【本次指令】要求删除，跳过它，并在最终输出中写明')
    [void]$sb.AppendLine('「已跳过删除操作，需主人在图形界面会话中当面确认」。')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 其他约束')
    [void]$sb.AppendLine('- 不要安装软件、不要改动系统配置或注册表，除非指令明确要求。')
    [void]$sb.AppendLine('- 不要修改本文件，也不要修改 ~/.agently-mail-watch 下的状态文件。')
    [void]$sb.AppendLine('- 完成后用中文简要写明：做了什么、结果如何、有无遗留问题。')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 本次指令（邮件正文原文）')
    [void]$sb.AppendLine('<<<BEGIN')
    [void]$sb.AppendLine($BodyText)
    [void]$sb.AppendLine('END>>>')

    # UTF-8 with BOM，确保中文在各类读取器下都正确
    [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $file
}

function Invoke-MailAgent {
    <# 启动一次 dsh headless 执行，返回结果哈希 #>
    param(
        [Parameter(Mandatory = $true)][string]$EnvelopePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSec
    )

    $dshCmd = Join-Path $env:APPDATA 'npm\dsh.cmd'
    if (-not (Test-Path $dshCmd)) { $dshCmd = 'dsh.cmd' }

    $stamp   = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $script:OutboxDir "agent-$stamp.out.txt"
    $errFile = Join-Path $script:OutboxDir "agent-$stamp.err.txt"

    # 纯 ASCII 短提示，避免 cmd.exe 代码页把中文参数搞乱
    $prompt = "Read the UTF-8 file $EnvelopePath and carry out the instruction inside it. " +
              "Obey its AUTHORIZATION, SCOPE and FORBIDDEN sections exactly."

    Write-Log "启动 agent: $EnvelopePath"

    # 用 .NET Process 而不是 Start-Process：Start-Process 对 .cmd 包装进程
    # 拿不到可靠的 ExitCode，且异步读取可避免管道写满死锁。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $dshCmd
    $psi.Arguments              = '--profile headless "' + $prompt + '"'
    $psi.WorkingDirectory       = $script:RuntimeDir
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch { }
        return @{ ok = $false; exitCode = -1; output = ''; error = "agent 超时（${TimeoutSec}s），已终止" }
    }

    $out = ''
    try { $out = $outTask.Result } catch { }
    $err = ''
    try { $err = $errTask.Result } catch { }

    $code = -1
    try { $code = $proc.ExitCode } catch { }

    # 留档，便于排错
    try { [System.IO.File]::WriteAllText($outFile, $out, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    try { [System.IO.File]::WriteAllText($errFile, $err, (New-Object System.Text.UTF8Encoding($false))) } catch { }

    return @{ ok = ($code -eq 0); exitCode = $code; output = $out; error = $err }
}

function Send-Receipt {
    param(
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$BodyText
    )
    $rel = 'outbox\receipt-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.md'
    $abs = Join-Path $script:RuntimeDir $rel
    [System.IO.File]::WriteAllText($abs, $BodyText, (New-Object System.Text.UTF8Encoding($false)))

    Push-Location $script:RuntimeDir
    try {
        $null = Invoke-AgentlyCli -CliArgs @(
            'message', '+send', '--to', $To, '--subject', $Subject,
            '--body-file', $rel, '--confirmed'
        )
        return $true
    } finally {
        Pop-Location
    }
}

function Test-PollerRunning {
    if (-not (Test-Path $script:PidPath)) { return $false }
    $txt = (Get-Content $script:PidPath -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $false }
    $procId = 0
    if (-not [int]::TryParse($txt.Trim(), [ref]$procId)) { return $false }
    return ($null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue))
}

function Resolve-SelfAddresses {
    <# 自动识别本邮箱自己的地址，作为环路防护基准（比手写配置更不易出错）#>
    try {
        $me = Invoke-AgentlyCli -CliArgs @('+me')
        $addrs = @()
        foreach ($a in @($me.aliases)) {
            if ($a.email) { $addrs += $a.email.ToString() }
        }
        return $addrs
    } catch {
        Write-Log "无法自动识别本邮箱地址：$($_.Exception.Message)" 'WARN'
        return @()
    }
}

# ----------------------------------------------------------------- main
if (Test-PollerRunning) {
    Write-Log "已有轮询进程在运行（pid $(Get-Content $script:PidPath -Raw)），本次退出。" 'WARN'
    exit 0
}

Set-Content -Path $script:PidPath -Value $PID -Encoding ASCII
Write-Log "轮询启动 pid=$PID"

try {
    $settings = Get-WatchSettings
    if ($IntervalSeconds -le 0) { $IntervalSeconds = [int]$settings.pollSeconds }
    $trusted = @($settings.trustedSenders | ForEach-Object { $_.ToString().ToLowerInvariant() })

    # 失败安全：未配置信任发件人就拒绝启动。
    # 否则等于开了一条"任何邮件都能触发执行"的通道。
    if ($trusted.Count -eq 0) {
        Write-Log 'trustedSenders 为空，拒绝启动。请在 settings.json 配置授权发件人邮箱后重试。' 'ERROR'
        exit 2
    }

    # 环路防护基准：优先用配置，未配置则自动识别本邮箱地址
    $selfAddrs = @($settings.selfAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($selfAddrs.Count -eq 0) { $selfAddrs = @(Resolve-SelfAddresses) }
    if ($selfAddrs.Count -eq 0) {
        Write-Log 'selfAddresses 为空且自动识别失败，拒绝启动（存在邮件环路风险）。请手工配置。' 'ERROR'
        exit 2
    }

    # 回执收件人：未配置则默认发给第一个信任发件人
    $receiptTo = [string]$settings.receiptTo
    if ([string]::IsNullOrWhiteSpace($receiptTo)) { $receiptTo = $settings.trustedSenders[0] }

    $state = Get-WatchState
    $firstRun = $false
    if ($null -eq $state) {
        $state = [pscustomobject]@{ seen = @(); firstRunDone = $false; lastPoll = $null; processedCount = 0 }
        $firstRun = $true
    } elseif (-not $state.firstRunDone) {
        $firstRun = $true
    }

    Write-Log ("配置: 信任发件人=[{0}] 自身地址=[{1}] 轮询间隔={2}s 单轮上限={3}" -f ($trusted -join ', '), ($selfAddrs -join ', '), $IntervalSeconds, $settings.maxPerCycle)

    $primed = $false
    while ($true) {
        if (Test-Path $script:DisabledPath) {
            Write-Log '检测到 DISABLED 标记，轮询退出。' 'WARN'
            break
        }

        try {
            $messages = Get-InboxMessages
            $state.lastPoll = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($s in @($state.seen)) { [void]$seen.Add([string]$s) }

            # 首次运行：只登记已有邮件，不回放历史指令
            if ($firstRun -and -not $ProcessExisting -and -not $settings.processExistingOnFirstRun) {
                $n = 0
                foreach ($m in $messages) {
                    if ($seen.Add([string]$m.message_id)) { $n++ }
                }
                $state.seen = @($seen)
                $state.firstRunDone = $true
                Save-WatchState -State $state -HistoryLimit $settings.historyLimit
                Write-Log "首次运行基线：登记 $n 封已有邮件，不回放。"
                $firstRun = $false
                $primed = $true
            } else {
                $firstRun = $false

                # 旧邮件优先处理
                $pending = @()
                foreach ($m in $messages) {
                    if ($seen.Contains([string]$m.message_id)) { continue }
                    if ($trusted -notcontains $m.from.email.ToString().ToLowerInvariant()) {
                        [void]$seen.Add([string]$m.message_id)   # 非信任发件人：登记，永不执行
                        continue
                    }
                    # 环路防护（读正文之前先做便宜的两项检查）
                    $fromAddr = $m.from.email.ToString().ToLowerInvariant()
                    $isSelf = $false
                    foreach ($self in $selfAddrs) {
                        if ($fromAddr -eq $self.ToString().ToLowerInvariant()) { $isSelf = $true; break }
                    }
                    $subjStr = [string]$m.subject
                    $isReceipt = (-not [string]::IsNullOrWhiteSpace([string]$settings.receiptSubjectPrefix)) -and
                                 $subjStr.StartsWith([string]$settings.receiptSubjectPrefix, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($isSelf -or $isReceipt) {
                        [void]$seen.Add([string]$m.message_id)
                        Write-Log "环路防护：忽略自身/回执邮件「$subjStr」" 'WARN'
                        continue
                    }
                    $pending += $m
                }
                $pending = @($pending | Sort-Object { $_.created_at })

                $handled = 0
                foreach ($m in $pending) {
                    if ($handled -ge [int]$settings.maxPerCycle) { break }
                    $handled++
                    [void]$seen.Add([string]$m.message_id)

                    try {
                        $full = Get-MessageById -Id $m.message_id
                        $bodyText = [string]$full.body
                        if (-not (Test-MeaningfulBody -Body $bodyText)) {
                            Write-Log "跳过空正文邮件：$($m.subject) [$($m.message_id)]" 'WARN'
                            continue
                        }

                        # 环路防护第三项：正文里带本程序封套标记的，不回放
                        if (-not (Test-InstructionEligible -Message $m -BodyText $bodyText `
                                    -SelfAddresses $selfAddrs `
                                    -ReceiptPrefix ([string]$settings.receiptSubjectPrefix))) {
                            Write-Log "环路防护：封套标记命中，忽略「$($m.subject)」" 'WARN'
                            continue
                        }

                        $env_path = New-InstructionEnvelope -Message $m -BodyText $bodyText -TrustedSender $m.from.email
                        $result = Invoke-MailAgent -EnvelopePath $env_path -TimeoutSec ([int]$settings.agentTimeoutSec)

                        if ($result.ok) {
                            Write-Log "执行完成：$($m.subject)" 'AGENT'
                        } else {
                            Write-Log "执行失败（exit=$($result.exitCode)）：$($m.subject) :: $($result.error)" 'ERROR'
                        }

                        if ($settings.sendReceipt) {
                            $receipt = @()
                            $receipt += "# Agent Mail 执行回执"
                            $receipt += ""
                            $receipt += "- 原邮件主题: $($m.subject)"
                            $receipt += "- 发件人: $($m.from.email)"
                            $receipt += "- 执行状态: " + $(if ($result.ok) { '成功' } else { "失败 (exit=$($result.exitCode))" })
                            $receipt += ""
                            $receipt += "## 执行结果"
                            $receipt += ""
                            if ([string]::IsNullOrWhiteSpace($result.output)) {
                                $receipt += "(agent 无输出)"
                            } else {
                                $receipt += $result.output.Trim()
                            }
                            if (-not $result.ok -and -not [string]::IsNullOrWhiteSpace($result.error)) {
                                $receipt += ""
                                $receipt += "## 错误输出"
                                $receipt += ""
                                $receipt += '```'
                                $receipt += $result.error.Trim()
                                $receipt += '```'
                            }
                            try {
                                $null = Send-Receipt -To $receiptTo `
                                    -Subject "[Agent Mail] 已执行: $($m.subject)" `
                                    -BodyText ($receipt -join "`r`n")
                                Write-Log "回执已发送至 $receiptTo"
                            } catch {
                                Write-Log "回执发送失败：$($_.Exception.Message)" 'ERROR'
                            }
                        }

                        $state.processedCount = [int]$state.processedCount + 1
                    } catch {
                        Write-Log "处理邮件失败 [$($m.message_id)]：$($_.Exception.Message)" 'ERROR'
                    }
                }
            }

            $state.seen = @($seen)
            Save-WatchState -State $state -HistoryLimit $settings.historyLimit
        } catch {
            Write-Log "轮询周期出错：$($_.Exception.Message)" 'ERROR'
        }

        if ($Once) { Write-Log '单轮模式结束。'; break }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Remove-Item $script:PidPath -Force -ErrorAction SilentlyContinue
    Write-Log '轮询已停止。'
}
