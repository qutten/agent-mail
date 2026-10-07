# agently-mail-watch — 运维说明

常驻轮询程序：把 Agent Mail 收件箱变成可执行的指令通道。
Skill 定义与授权模型见同目录 `SKILL.md`；安全分析见仓库 `docs/SECURITY.md`。

## 文件布局

```
~/.agents/skills/agently-mail-watch/     ← 程序（不在工作区）
    SKILL.md        授权 + 使用说明
    poller.ps1      常驻轮询主体
    watch.ps1       控制面板
    watch.cmd       控制面板的 cmd 包装
    README.md       本文件

~/.agently-mail-watch/                    ← 运行时状态
    settings.json   配置（改完下一轮生效，无需重启）
    state.json      已处理邮件登记表 + 计数
    poller.pid      运行中进程号
    DISABLED        存在即硬性停用（轮询下一轮自行退出）
    logs/           poller-YYYYMMDD.log
    inbox/          生成的指令封套（审计留档）
    outbox/         Agent 的 stdout/stderr + 回执草稿
```

## 日常操作

```powershell
cd "$env:USERPROFILE\.agents\skills\agently-mail-watch"
.\watch.cmd enable      # 开机自启 + 立即启动
.\watch.cmd disable     # 移除自启 + 停止 + 落 DISABLED
.\watch.cmd start       # 只启动
.\watch.cmd stop        # 只停止
.\watch.cmd status      # 状态一览
.\watch.cmd logs 80     # 最近 80 行日志
.\watch.cmd run-once    # 前台跑一轮（含历史邮件），排错用
```

## 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `trustedSenders` | `[]` | **必填**。授权发件人白名单。为空则拒绝启动 |
| `selfAddresses` | `[]` | 本邮箱自己的地址，用于环路防护。留空自动从 `agently-cli +me` 识别 |
| `receiptSubjectPrefix` | `"[Agent Mail]"` | 回执主题前缀，兼作环路防护标记 |
| `pollSeconds` | `30` | 轮询间隔 |
| `maxPerCycle` | `5` | 单轮最多处理几封 |
| `agentTimeoutSec` | `900` | 单次 Agent 执行超时 |
| `sendReceipt` | `true` | 是否回执 |
| `receiptTo` | `""` | 回执收件人，留空取 `trustedSenders[0]` |
| `historyLimit` | `500` | `state.json` 里保留多少条已处理登记 |
| `processExistingOnFirstRun` | `false` | 首轮是否回放历史邮件 |

## 关键实现细节（踩过的坑）

| 坑 | 处理 |
|---|---|
| PS 5.1 按 ANSI 读 `.ps1`，中文乱码导致语法错误（实测直接把字符串字面量撑爆） | 所有 `.ps1` 必须存为 **UTF-8 with BOM**（`EF BB BF`）。改完脚本务必确认 BOM 还在 |
| `agently-cli` 往 stderr 写 `tip:`，`EAP=Stop` 下被当成终止性错误 | `Invoke-AgentlyCli` 内临时把 `$ErrorActionPreference` 降为 `Continue` 并 `2>$null` |
| `Start-Process` 对 `.cmd` 拿不到可靠 `ExitCode`（明明成功却报失败） | 改用 `System.Diagnostics.Process` + 异步读流 |
| 回执回到自己收件箱 → 被当成指令 → 无限循环（实测嵌套到三层） | 三道环路防护，见 `SKILL.md` |
| Windows 命令行 32K 上限 + cmd.exe 代码页毁中文参数 | Agent 提示用纯 ASCII 短句，正文走封套文件，不走 argv |
| `$args` 是 PowerShell 自动变量，赋值会出问题 | `watch.ps1` 里改用 `$psArgs` |

## 排错

```powershell
# 1. 链路是否通
agently-cli +me

# 2. 手动跑一轮看详细日志
.\watch.cmd run-once

# 3. 看 Agent 到底输出了什么
Get-ChildItem "$env:USERPROFILE\.agently-mail-watch\outbox" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 6 Name,Length

# 4. 看某封邮件为什么没触发
#    settings.json 的 trustedSenders / selfAddresses
#    state.json 的 seen 里是否已登记

# 5. 彻底重置（会重跑历史邮件）
Remove-Item "$env:USERPROFILE\.agently-mail-watch\state.json"
```

## 换掉 Agent 后端

`poller.ps1` 里只有 `Invoke-MailAgent` 与 Agent 实现耦合。默认调用：

```
dsh --profile headless "<读取封套文件的提示>"
```

换成别的 headless CLI，只需改这个函数：把 `$psi.FileName` / `$psi.Arguments`
换成目标命令，保持"传入一个文件路径、回收 stdout 作为执行结果"的约定即可。

## 安全边界

见 `docs/SECURITY.md`。要点：无发件人认证、提示层约束不等于沙箱、
硬刹车是 `watch.cmd disable` 或 `DISABLED` 标记文件。
