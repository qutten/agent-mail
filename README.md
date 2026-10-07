# agent-mail

把 **Agent Mail 收件箱**变成一条可自动执行的指令通道：
授权发件人发来一封邮件，本机常驻程序唤醒一个 Agent 执行它，结果以回执邮件发回。

> ⚠️ **这不是一个普通的工具。** 启用后，它会建立一条**没有发件人认证的远程执行通道** ——
> 任何能伪造授权发件人地址的人，都能让这台机器自动执行邮件内容。
> 启用前请务必读完 [docs/SECURITY.md](docs/SECURITY.md)。

---

## 它解决什么问题

IM 里的 Agent 需要你坐在电脑前。邮件是异步的 —— 你在地铁上发一封邮件，
家里的机器就能把活干完，结果回到你邮箱。

```
你 ──邮件──▶ Agent Mail 收件箱
                    │
                    │  常驻轮询程序（本仓库）
                    ▼
             headless Agent 执行
                    │
                    │  回执
                    ▼
             你 ◀──邮件────┘
```

---

## 前置条件

| 依赖 | 说明 |
|---|---|
| Windows + PowerShell 5.1+ | 控制脚本是 PowerShell |
| Node.js ≥ 18 | 运行 CLI |
| [`@tencent-qqmail/agently-cli`](https://www.npmjs.com/package/@tencent-qqmail/agently-cli) | Agent Mail 官方 CLI，提供收发信能力 |
| 一个 headless Agent 入口 | 默认用 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 `dsh --profile headless`，可替换 |

```powershell
# 1. 安装 CLI
npm install -g @tencent-qqmail/agently-cli

# 2. 安装邮件 skill（提供邮件读写能力）
npx skills add https://agent.qq.com --skill -g -y

# 3. OAuth 授权（交互式，浏览器完成）
agently-cli auth login

# 4. 验证
agently-cli +me
```

---

## 安装

```powershell
git clone https://github.com/qutten/agent-mail.git
cd agent-mail
.\install.ps1
```

`install.ps1` 会把 `skill/` 安装到 `~/.agents/skills/agently-mail-watch/`，
并在 `~/.agently-mail-watch/` 生成配置模板。**它不会自动启用轮询。**

然后编辑 `~/.agently-mail-watch/settings.json`，至少填上 `trustedSenders`：

```json
{
  "trustedSenders": ["your-own-address@example.com"]
}
```

> 用你自己的另一个邮箱填 `trustedSenders`。**不要**填 Agent Mail 本身的地址 ——
> 那会形成邮件环路（见下）。

---

## 启用 / 停用

```powershell
cd "$env:USERPROFILE\.agents\skills\agently-mail-watch"

.\watch.cmd enable      # 开机自启 + 立即启动
.\watch.cmd status      # 看状态
.\watch.cmd logs 80     # 看日志
.\watch.cmd disable     # 停用（含硬刹车标记）
```

**硬刹车**：`watch.cmd disable`，或手工在 `~/.agently-mail-watch/` 下建一个名为 `DISABLED`
的空文件 —— 轮询会在下一轮检测到并自行退出。

---

## 工作流程

```
每 30 秒
 └─ agently-cli message +list --dir inbox --limit 30
     └─ 过滤：发件人 ∈ trustedSenders
              且 ∉ selfAddresses（环路防护）
              且 主题不以 [Agent Mail] 开头
              且 message_id 未处理过
         └─ 读正文 → 空正文跳过
              └─ 生成 inbox/instruction-<id>.md
                 （含 AUTHORIZATION / SCOPE / FORBIDDEN 三段）
                  └─ 唤醒 headless Agent 执行（超时 900s）
                      └─ 回执发到 receiptTo
                          └─ 写 state.json
```

---

## 目录结构

```
agent-mail/
├── install.ps1              安装器：装 skill + 生成配置模板
├── README.md                本文件
├── LICENSE
├── docs/
│   └── SECURITY.md          安全模型、威胁分析、缓解措施
└── skill/                   被安装的内容
    ├── SKILL.md             skill 定义 + 内嵌授权规则
    ├── poller.ps1           常驻轮询主体
    ├── watch.ps1            控制面板
    ├── watch.cmd            cmd 包装
    └── README.md            运维说明 + 踩坑记录
```

运行时会生成（不在本仓库）：

```
~/.agently-mail-watch/
├── settings.json   配置
├── state.json      已处理登记表
├── poller.pid      进程号
├── DISABLED        硬刹车标记
├── logs/           按天滚动日志
├── inbox/          指令封套（审计留档）
└── outbox/         Agent stdout/stderr + 回执草稿
```

---

## 设计要点

**环路防护。** 回执本身就是出站邮件。如果它回到本收件箱并被当成新指令，
就会「回执 → 指令 → 回执」无限循环 —— 这不是理论风险，开发时实测触发过，
且主题逐层嵌套膨胀。三道拦截解决：发件人是自己 / 主题带回执前缀 / 正文含封套标记。

**失败安全。** `trustedSenders` 为空时程序**拒绝启动**，而不是退化成"谁都能触发"。

**授权写进封套。** 授权规则不只写在 skill 里，还会复制进每封邮件的指令封套文件，
因此被唤醒的 Agent 一定能看到约束，不依赖 skill 是否被加载。

**正文走文件不走 argv。** Windows 命令行有 32K 上限且 cmd.exe 代码页会毁掉中文参数，
所以正文写进 UTF-8 封套文件，命令行只传一句纯 ASCII 提示。

**可替换的 Agent 后端。** `poller.ps1` 里 `Invoke-MailAgent` 是唯一与 Agent 实现耦合的地方，
换成别的 headless CLI 只需改这一个函数。

---

## 已知限制

- **仅 Windows。** 脚本是 PowerShell 5.1 写的。核心逻辑不复杂，移植到 bash 不难（欢迎 PR）。
- **无发件人认证。** `agently-cli` 不返回 SPF/DKIM 结果，只能按 `From` 地址判断身份。
- **提示层约束 ≠ 沙箱。** 封套里的 SCOPE/FORBIDDEN 靠模型遵守，不是硬性隔离。
- **单实例。** 同时只允许一个轮询进程，靠 pid 文件保证。
- **不做并发。** 一轮内串行处理，`maxPerCycle` 默认 5。

---

## License

MIT
