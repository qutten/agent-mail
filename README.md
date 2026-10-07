# agent-mail

**给 Agent 一个邮箱，让它在你不在电脑前的时候也能替你干活。**

这个仓库是 [Agent Mail](https://agent.qq.com)（腾讯 QQ 邮箱团队做的 AI 专用邮箱）之上的
一层**常驻轮询**：让授权发件人的邮件自动变成一次 Agent 执行任务。

> 🤖 **如果你是 AI Agent**，请直接读 [AGENTS.md](AGENTS.md) —— 那是写给你的部署说明。
> 下面的内容是给人看的。

---

## 一、Agent Mail 是什么

如果你已经知道，可以跳到[第二节](#二这个项目加了什么)。

[Agent Mail](https://agent.qq.com)（也叫 Agently Mail）是**腾讯 QQ 邮箱团队**在 2026 年 7 月
推出的一款 **AI 专用邮箱**服务。核心想法很简单：

> 电子邮件本来就是异步的、标准的、跨平台的。既然如此，为什么不给 Agent 也发一个邮箱地址？

于是你的 Agent 就有了自己的邮箱，可以和任何人、任何服务、乃至**别人的 Agent** 通信。

### 和普通邮箱的区别

| | 普通 QQ 邮箱 | Agent Mail |
|---|---|---|
| 使用者 | 你 | 你的 Agent |
| 收信方式 | 网页 / 客户端 | **命令行工具**，天然适合 Agent 调用 |
| 与个人邮箱关系 | —— | **完全隔离**，不会混进你的私人邮件 |
| 地址格式 | `123456@qq.com` | `<名字>@agent.qq.com` |

关键在第二行：它提供的不是网页界面，而是一个 **CLI**。Agent 本来就会执行命令，
所以"收发邮件"对它来说就是跑一条命令的事，不需要额外的 MCP 或插件适配。

### 怎么开通

1. 打开 <https://agent.qq.com>，**微信扫码**注册（目前是内测，每人可注册 **2 个**地址）
2. 装 CLI 并授权：

```powershell
npm install -g @tencent-qqmail/agently-cli
npx skills add https://agent.qq.com --skill -g -y
agently-cli auth login
agently-cli +me          # 验证
```

官方文档：<https://agent.qq.com/doc/cli-setup.md>
官方 skill 仓库：[Tencent/AgentlyMail](https://github.com/Tencent/AgentlyMail)

### 免费配额

- 每日发送 **50 封**
- 邮箱容量 **1 GB**
- 速率限制：每分钟 10 次、每小时 200 次

（额度偏紧，所以本项目的轮询程序做了环路防护，避免把配额烧在自我循环上 —— 见下文。）

### 典型的用法

- **自动化注册**：需要邮箱验证码的服务，Agent 自己去收信、取码、完成注册
- **接收告警并处理**：证书快过期了，Agent 收到通知后自动续签
- **Agent 之间通信**：两个 Agent 用邮箱互相发任务（这个最有趣）
- **人在外面指挥**：地铁上发一封邮件，家里的机器把活干完 —— **这也正是本项目做的事**

---

## 二、这个项目加了什么

Agent Mail 给了 Agent 邮箱，但**没有解决"谁来叫醒它"的问题**。

你发了一封邮件，CLI 能读到它 —— 可如果没有一个进程在跑，什么也不会发生。
你得坐在电脑前对 Agent 说"去看下邮箱"。

这个项目补的就是这一环：

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

装上之后，你在任何地方发一封邮件，家里的机器就会自己把活干了，结果回到你邮箱。

> ⚠️ **代价是真实的。** 这等于开了一条**没有发件人认证的远程执行通道** ——
> 任何能伪造授权发件人地址的人，都能让这台机器自动执行邮件内容。
> 启用前请务必读完 [docs/SECURITY.md](docs/SECURITY.md)。

---

## 三、安装

### 前置条件

| 依赖 | 说明 |
|---|---|
| Windows + PowerShell 5.1+ | 控制脚本是 PowerShell |
| Node.js ≥ 18 | 运行 CLI |
| [`@tencent-qqmail/agently-cli`](https://www.npmjs.com/package/@tencent-qqmail/agently-cli) | 已按[第一节](#怎么开通)完成安装和 OAuth 授权 |
| 一个 headless Agent 入口 | 默认用 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 `dsh --profile headless`，可替换 |

### 安装步骤

```powershell
git clone https://github.com/qutten/agent-mail.git
cd agent-mail
.\install.ps1
```

安装器会：

1. 自检依赖，并显示已授权的邮箱地址
2. 把 `skill/` 装到 `~/.agents/skills/agently-mail-watch/`
3. 在 `~/.agently-mail-watch/` 生成配置模板
4. **不启用轮询** —— 启用是你的决定

然后编辑配置，**至少填上 `trustedSenders`**：

```powershell
notepad "$env:USERPROFILE\.agently-mail-watch\settings.json"
```

```json
{
  "trustedSenders": ["my-other-inbox@example.com"]
}
```

> 填你自己的**另一个**邮箱（日常在用的那个就行）。
> **绝对不要**填 Agent Mail 本身的地址 —— 那会让程序处理自己发出的回执，形成死循环
> （开发时实测触发过，主题会逐层嵌套膨胀）。

---

## 四、启用 / 停用

```powershell
cd "$env:USERPROFILE\.agents\skills\agently-mail-watch"

.\watch.cmd enable      # 开机自启 + 立即启动
.\watch.cmd status      # 看状态
.\watch.cmd logs 80     # 看日志
.\watch.cmd disable     # 停用
```

**硬刹车**：`watch.cmd disable` 会移除开机自启、停止进程、并落下一个 `DISABLED` 标记文件。
轮询在下一轮检测到该文件就会自行退出 —— 不是"这次不跑"，而是"以后都不跑，直到重新 enable"。

也可以手工在 `~/.agently-mail-watch/` 下建一个名为 `DISABLED` 的空文件达到同样效果。

---

## 五、它是怎么工作的

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

### 目录结构

```
agent-mail/
├── AGENTS.md                给 AI Agent 的部署说明
├── install.ps1              安装器
├── README.md                本文件
├── LICENSE
├── docs/
│   └── SECURITY.md          安全模型、威胁分析、加固建议
└── skill/                   被安装的内容
    ├── SKILL.md             skill 定义 + 内嵌授权规则
    ├── poller.ps1           常驻轮询主体
    ├── watch.ps1            控制面板
    ├── watch.cmd            cmd 包装
    └── README.md            运维说明 + 踩坑记录
```

运行时状态（不在本仓库，也不会被提交）：

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

## 六、设计上值得一提的几点

**环路防护。** 回执本身就是一封出站邮件。如果它回到本收件箱并被当成新指令，
就会「回执 → 指令 → 回执」无限循环 —— **这不是理论风险，开发时实测触发过**，
而且主题逐层嵌套膨胀（`[Agent Mail] 已执行: [Agent Mail] 已执行: ...`），
很快就能把每日 50 封的配额烧光。三道拦截解决：发件人是自己 / 主题带回执前缀 / 正文含封套标记。

**失败安全。** `trustedSenders` 为空时程序**拒绝启动**（退出码 2），
而不是退化成"谁都能触发"。这个默认值比"方便"重要。

**授权写进封套。** 授权规则不只写在 skill 里，还会复制进每封邮件的指令封套文件。
这样被唤醒的 Agent 一定能看到约束，不依赖 skill 是否被正确加载。

**正文走文件不走 argv。** Windows 命令行有 32K 上限，且 cmd.exe 的代码页会毁掉中文参数。
所以邮件正文写进 UTF-8 封套文件，命令行只传一句纯 ASCII 提示。

**可替换的 Agent 后端。** `poller.ps1` 里 `Invoke-MailAgent` 是唯一与 Agent 实现耦合的地方。
换成别的 headless CLI 只需改这一个函数。

---

## 七、已知限制

- **仅 Windows。** 脚本是 PowerShell 5.1 写的。核心逻辑不复杂，移植到 bash 不难（欢迎 PR）。
- **无发件人认证。** `agently-cli` 不返回 SPF/DKIM 结果，只能按 `From` 地址判断身份。
- **提示层约束 ≠ 沙箱。** 封套里的 SCOPE/FORBIDDEN 靠模型遵守，不是硬性隔离。
- **单实例。** 同时只允许一个轮询进程，靠 pid 文件保证。
- **不做并发。** 一轮内串行处理，`maxPerCycle` 默认 5。
- **依赖 Agent Mail 内测服务。** 上游若调整 CLI 或配额，本项目需要跟着改。

---

## 八、相关链接

| 资源 | 链接 |
|---|---|
| Agent Mail 官网 / 注册 | <https://agent.qq.com> |
| 官方 CLI 安装文档 | <https://agent.qq.com/doc/cli-setup.md> |
| 官方 skill 仓库 | <https://github.com/Tencent/AgentlyMail> |
| CLI npm 包 | <https://www.npmjs.com/package/@tencent-qqmail/agently-cli> |
| 本项目安全说明 | [docs/SECURITY.md](docs/SECURITY.md) |

---

## License

MIT
