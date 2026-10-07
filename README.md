# agent-mail

让 Agent 拥有自己的邮箱，并且在你不在电脑前的时候替你干活。

## 这是什么

[Agent Mail](https://agent.qq.com) 是腾讯 QQ 邮箱团队做的 AI 专用邮箱：
给你的 Agent 一个 `<名字>@agent.qq.com` 地址，通过 CLI
（`@tencent-qqmail/agently-cli`）收发邮件，与你的个人邮箱完全隔离。
免费额度每日 50 封、1 GB 容量。

但它只解决"能收发"，不解决"谁来叫醒 Agent"。你发了一封邮件，如果没有进程在跑，
什么都不会发生 —— 还是得坐到电脑前说一声"看下邮箱"。

这个项目补上这一环：

```
你 ──邮件──▶ 收件箱 ──▶ 常驻轮询程序 ──▶ Agent 执行 ──▶ 回执 ──▶ 你
```

轮询程序每隔 30 秒检查一次收件箱，把白名单发件人的邮件转成一次 headless Agent 执行，
再把结果以回执邮件发回。你在外面发一封邮件，家里的机器就把活干了。

> ⚠️ 这等于开了一条**没有发件人认证的远程执行通道**：任何能伪造白名单发件人地址的人，
> 都能让这台机器自动执行邮件内容。启用前请读一下 [docs/SECURITY.md](docs/SECURITY.md)。

## 安装

环境要求：Windows + PowerShell 5.1+、Node.js ≥ 18。

先装好 CLI 并完成授权：

```powershell
npm install -g @tencent-qqmail/agently-cli
npx skills add https://agent.qq.com --skill -g -y
agently-cli auth login
agently-cli +me
```

然后安装本项目：

```powershell
git clone https://github.com/qutten/agent-mail.git
cd agent-mail
.\install.ps1
```

安装器会自检依赖、把 skill 装到 `~/.agents/skills/agently-mail-watch/`、
在 `~/.agently-mail-watch/` 生成配置模板。它**不会**自动启用轮询。

编辑配置，填上你自己的另一个邮箱作为指令来源：

```powershell
notepad "$env:USERPROFILE\.agently-mail-watch\settings.json"
```

```json
{
  "trustedSenders": ["my-other-inbox@example.com"]
}
```

> 不要填 Agent Mail 本身的地址，那会让程序处理自己发出的回执，形成死循环。

### 让 AI 帮你装

把 [AGENTS.md](AGENTS.md) 交给任意 AI Agent，它会自己完成依赖检查、安装、配置和验证。

也可以直接对 Agent 说：

```
请阅读 https://github.com/qutten/agent-mail/blob/main/AGENTS.md 并按其中步骤安装配置。
```

## 使用

```powershell
cd "$env:USERPROFILE\.agents\skills\agently-mail-watch"

.\watch.cmd enable      # 启用：开机自启 + 立即启动
.\watch.cmd status      # 查看状态
.\watch.cmd logs 80     # 查看日志
.\watch.cmd disable     # 停用
```

`disable` 会移除开机自启、停止进程，并落下一个 `DISABLED` 标记文件 ——
轮询下一轮检测到就会自行退出，不是"这次不跑"而是"以后都不跑，直到重新 enable"。

## 目录结构

```
agent-mail/
├── AGENTS.md                给 AI Agent 的安装说明
├── install.ps1              安装器
├── README.md
├── LICENSE
├── docs/SECURITY.md         安全模型与威胁分析
└── skill/                   被安装的内容
    ├── SKILL.md             skill 定义 + 内嵌授权规则
    ├── poller.ps1           常驻轮询主体
    ├── watch.ps1 / .cmd     控制面板
    └── README.md            运维说明与踩坑记录
```

## 已知限制

- 仅 Windows（脚本是 PowerShell 5.1 写的）
- 发件人身份仅按 `From` 地址判断，`agently-cli` 不返回 SPF/DKIM 结果
- 封套里的权限约束是提示层，不是硬沙箱
- Agent 后端默认用 `dsh --profile headless`，换别的只需改 `poller.ps1` 里 `Invoke-MailAgent` 一个函数

## 相关链接

| 资源 | 链接 |
|---|---|
| Agent Mail 官网 / 注册 | <https://agent.qq.com> |
| 官方 CLI 文档 | <https://agent.qq.com/doc/cli-setup.md> |
| 官方 skill 仓库 | <https://github.com/Tencent/AgentlyMail> |
| 本项目安全说明 | [docs/SECURITY.md](docs/SECURITY.md) |

## License

MIT
