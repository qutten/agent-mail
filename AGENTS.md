# AGENTS.md

> **本文件是写给 AI Agent 的部署说明。** 人类读者请看 [README.md](README.md)。
>
> 如果你的用户让你"安装这个仓库"或"配置邮件轮询"，按本文档执行即可。

---

## 0. 你在安装什么

[Agent Mail](https://agent.qq.com) 是腾讯 QQ 邮箱团队提供的 AI 专用邮箱，
通过 CLI `@tencent-qqmail/agently-cli` 收发邮件。

本仓库在它之上加了一个**常驻轮询程序**：监视收件箱，把授权发件人的邮件
转成一次 headless Agent 执行，并把结果以回执邮件发回。

**它的性质**：这是一条**无发件人认证的远程执行通道**。装好并启用后，
任何能伪造授权发件人地址的人都能让本机自动执行邮件内容。
因此下面的步骤里有两条不可跳过的红线。

---

## 1. 两条红线

### 🔴 红线一：不要自行启用

安装完**默认是停用状态**。`watch.cmd enable` 只能由用户明确要求时执行。
用户没说过"启用 / 打开 / 开启轮询"，就不要执行它。

### 🔴 红线二：`trustedSenders` 不能让你自己编

`trustedSenders` 填的是**用户的另一个邮箱地址**，必须由用户提供。

- ❌ 不要凭空编一个地址填进去
- ❌ 不要把 Agent Mail 自己的地址填进去（会导致邮件环路）
- ❌ 不要把示例占位符 `my-other-inbox@example.com` 留在配置里
- ✅ 问用户："请给我一个你日常在用的邮箱地址，作为指令来源白名单。"

---

## 2. 前置检查

依次执行并确认结果：

```powershell
node --version            # 需要 >= 18
npm --version
agently-cli --version     # 没装则见下
agently-cli +me           # 必须 ok:true 且返回邮箱地址
```

任何一项失败，先修好再继续：

```powershell
npm install -g @tencent-qqmail/agently-cli
npx skills add https://agent.qq.com --skill -g -y
agently-cli auth login    # 交互式：把输出的授权 URL 原样交给用户，等他完成
```

> `agently-cli auth login` 是交互式长命令：**后台运行**，从 stdout/stderr 提取原始授权 URL
> 发给用户，并提示"请点击或复制以下链接在浏览器中完成授权"。
> 把 URL 当作不可修改的 opaque string，不要做 URL 编码/解码或重新拼接。
> **失败或超时不要重试**，直接把错误反馈给用户。

---

## 3. 安装

```powershell
git clone https://github.com/qutten/agent-mail.git
cd agent-mail
.\install.ps1
```

安装器行为：

- 装到 `~/.agents/skills/agently-mail-watch/`
- 在 `~/.agently-mail-watch/` 生成 `settings.json` 模板
- **不会**启用轮询

参数：
- `-Force` 覆盖已存在的脚本
- `-SkillRoot <path>` / `-RuntimeDir <path>` 换安装位置

---

## 4. 配置

先向用户索取信任发件人邮箱（见红线二），然后写入：

`%USERPROFILE%\.agently-mail-watch\settings.json`

```json
{
  "trustedSenders": ["<用户提供的邮箱>"],
  "selfAddresses": [],
  "receiptSubjectPrefix": "[Agent Mail]",
  "pollSeconds": 30,
  "maxPerCycle": 5,
  "agentTimeoutSec": 900,
  "sendReceipt": true,
  "receiptTo": "<用户提供的邮箱>",
  "historyLimit": 500,
  "processExistingOnFirstRun": false
}
```

| 键 | 说明 |
|---|---|
| `trustedSenders` | **必填**。指令来源白名单。为空则程序拒绝启动 |
| `selfAddresses` | 本邮箱自己的地址，用于环路防护。**留空即自动从 `agently-cli +me` 识别**，建议留空 |
| `receiptSubjectPrefix` | 回执主题前缀，兼作环路防护标记 |
| `receiptTo` | 回执收件人。留空则取 `trustedSenders[0]` |

写文件时注意：**UTF-8，不要加 BOM**（JSON 解析器对 BOM 敏感度不一致，不加最稳）。

---

## 5. 验证

```powershell
$skill = "$env:USERPROFILE\.agents\skills\agently-mail-watch"

# 5.1 脚本能解析（PowerShell 5.1 对编码敏感）
.\$skill\watch.cmd status

# 5.2 跑一轮但不启用（可安全执行，只会登记已有邮件）
.\$skill\watch.cmd run-once

# 5.3 查看日志确认没有报错
.\$skill\watch.cmd logs 40
```

预期：`run-once` 输出「首次运行基线：登记 N 封已有邮件，不回放」且无 ERROR。
`status` 应显示 `轮询进程: 未运行`（因为还没 enable）。

**失败安全自检**（可选但推荐）：把 `settings.json` 临时移走再跑 `run-once`，
应当看到 `trustedSenders 为空，拒绝启动` 且退出码为 2。测完记得移回来。

---

## 6. 启用（仅在用户明确要求时）

```powershell
cd "$env:USERPROFILE\.agents\skills\agently-mail-watch"
.\watch.cmd enable
.\watch.cmd status
```

启用后向用户说明：

1. 轮询已启动，并且设置了**开机自启**
2. 让他从 `trustedSenders` 里那个邮箱发一封**带正文**的测试邮件
3. 约 30 秒内会被执行，回执发到 `receiptTo`
4. 随时可用 `.\watch.cmd disable` 停用（含硬刹车）

同时应提醒他安全边界，见 [docs/SECURITY.md](docs/SECURITY.md)。

---

## 7. 排错

| 现象 | 检查 |
|---|---|
| 脚本报语法错误 / 中文乱码 | `.ps1` 的 **UTF-8 BOM 丢了**。Windows PowerShell 5.1 没有 BOM 时按 ANSI(GBK) 解码 |
| 程序拒绝启动，退出码 2 | `trustedSenders` 为空，或 `selfAddresses` 为空且自动识别失败 |
| 邮件没被处理 | 发件人是否**精确等于**白名单；正文是否为空；`message_id` 是否已在 `state.json` 的 `seen` 里 |
| Agent 没执行 | 看 `outbox\agent-*.err.txt`；可能 `agentTimeoutSec` 太小 |
| 回执没发出 | 日志里搜「回执发送失败」；确认 `agently-cli +me` 授权仍有效 |
| 出现 `[Agent Mail] 已执行: [Agent Mail] 已执行: ...` | 环路。检查 `trustedSenders` 是否混入了本邮箱地址 |

**调试用命令：**

```powershell
# 看 Agent 实际输出了什么
Get-ChildItem "$env:USERPROFILE\.agently-mail-watch\outbox" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 6 Name,Length

# 看某封邮件生成的指令封套（审计留档）
Get-ChildItem "$env:USERPROFILE\.agently-mail-watch\inbox"

# 彻底重置（会重跑历史邮件）
Remove-Item "$env:USERPROFILE\.agently-mail-watch\state.json"
```

---

## 8. 关键实现约束（改代码时必读）

如果你要修改本项目，以下几条是踩过坑的结论，别踩回去：

| 约束 | 原因 |
|---|---|
| `.ps1` 必须 **UTF-8 with BOM** | Windows PowerShell 5.1 无 BOM 时按 ANSI 解码，中文注释会撑爆字符串字面量导致语法错误 |
| 调 `agently-cli` 时必须临时降 `$ErrorActionPreference` | 它往 stderr 写 `tip:` 提示，`EAP=Stop` 下会被当成终止性错误 |
| 不要用 `Start-Process` 跑 `.cmd` 取退出码 | 拿不到可靠 `ExitCode`，明明成功也报失败。用 `System.Diagnostics.Process` |
| Agent 提示必须是**纯 ASCII** | cmd.exe 代码页会把中文参数搞乱 |
| 长文本（邮件正文）走文件，不走命令行 | Windows 命令行 32K 上限 |
| 不要给 `$args` 赋值 | PowerShell 自动变量 |

---

## 9. 参考

- 人类向说明：[README.md](README.md)
- 安全模型与威胁分析：[docs/SECURITY.md](docs/SECURITY.md)
- 运维细节与踩坑记录：[skill/README.md](skill/README.md)
- Agent Mail 官方 CLI 文档：<https://agent.qq.com/doc/cli-setup.md>
- Agent Mail 官方 skill：[Tencent/AgentlyMail](https://github.com/Tencent/AgentlyMail)
