# Darra EtherCAT 技能体

> 让通用 AI 助手在零背景知识下，把 Darra EtherCAT 主站从「下载安装包」一路带到「现场跑起来」。

官方文档页：[ethercat.darra.xyz/doc/skills](https://ethercat.darra.xyz/doc/skills/) · 英文概览见文末 [English](#english)

这里不是代码库，是**一组纯 Markdown 的操作技能**（每份一个 `SKILL.md`）。没有构建步骤、没有运行时依赖、不需要编译。把它交给 Claude Code、Cursor、Copilot 或你自研的 agent，它就知道在 Darra EtherCAT 这件事上**按什么顺序做、每一步怎么算做完、做错了会怎样**——不需要你先教会它 EtherCAT 主站。

技能正文是中文，YAML front matter 里带机器可读的英文名和触发词，路由靠 `description` 字段。

---

## 定位：最终交付物是你的程序，不是技能体

技能体只做一件事：把「Darra 的 SDK 怎么用才对」讲清楚，**让 AI 帮你把「你自己的程序」写对**。

- **你的程序长什么样，由你决定。** 上位机、产线软件、测试台、机器人控制器都行。技能体不替你决定工艺，也不生成一套「我们的标准答案」应用。
- **技能体负责这一段：** 这台机器该怎么接、该调哪个 API、这个状态能不能改、这个错是什么原因、这个数字算不算正常。
- **它不接管你的业务逻辑。** 节拍、状态机、联锁、报警分级、配方、插补算法都是你的；它只保证你调 SDK 的那几行是对的。

三个例子，都是「用户说一句 → AI 帮他把**他的**程序写对」：

- **「我要在 C# 里每 1 ms 读 6 个伺服的位置并写目标位置。」** 它会给出 `LoopCycle` 的单位和取值（纳秒，125 µs 起步、31 µs 下限）、PDO 映射怎么落到 `struct` + `Pack=1` 的字节顺序、映射在哪个状态才能改（OP 下改会被拒，要回 PreOp）、输入映像陈旧怎么判（C# 的 `PdoInputStaleException` / Python 的 `pdo.is_input_frame_stale`）。插补怎么算、节拍怎么排，是你的事。
- **「我的 Python 程序偶尔读不到 `0x6064`。」** 它会先确认 `sdo_read` 失败是返回 `ok=False`（C# 是 `null`）而不是抛异常，再按 abort 码分类（`0x05040000` 是协议超时、邮箱没回来，不等于对象不存在），再查邮箱与从站状态。它不会给你换一个"更顺手"的 API。
- **「我这台机器上电后要自动进 OP 并开始跑我的节拍。」** 它会给出 DENI 全量配置、关掉自动启动由你的程序挑时机、`Close()` 必须放 `finally`（不放，下一次连接要多等 18–23 s）的完整路径和实测秒数。

---

## 它能替你做什么

下面每一条都是「你说一句 → 它做完什么」。括号里是执行这条的技能体。

**1. 「把这台 Windows 机器装好。」**
`darra-runtime-install` / `darra-ethercat-windows`

先说明这次会发生什么（装实时运行时与驱动、可能预留实时核、可能需要重启），拿到你的确认后，从固定直链下载、核对 SHA256、用 `--silent --install` 静默安装；按退出码判断结果（`3010` = 操作成功、重启后生效）。**不会自己重启你的机器**，也不会在校验和不符时继续装。

**2. 「装完了，到底活没活着？」**
`darra-verify`

按 L0 → L5 六层往下走：安装事实 → SDK 文件就位 → SDK 能加载 → 网卡能枚举 → 总线能扫 →（可选）进 OP 读从站身份对象。最后交回一段机器可读 JSON，直接贴进工单：

```json
{
  "sdk_version": "2.13.16",
  "adapters": [
    { "name": "以太网 2", "mac": "…", "ethercat_capable": true,
      "scan_state": "EmptyBus", "slave_count": 0, "native_code": 0, "error": "" }
  ]
}
```

`slave_count` 严格三态：`null` = 没量到，`0` = 实测空口，`N > 0` = 实测 N 个从站。没有从站也能跑完，空口是正常结论而不是故障。

**3. 「写一个主站程序：选网卡、扫从站、进 OP、每周期写 PDO、读一次 SDO、最后 Close。」**
`darra-ethercat`

给一份**完整可跑的 C# 骨架**和一份**完整可跑的 Python 骨架**（选卡 → 建站 → 进 OP → 周期回调 → SDO → `Close()`），其余四种语言给入口差异对照。写代码之前强制先读官方 API 规则文件；读不到就停下，而不是编一个不存在的接口。

**4. 「SDO 读 `0x6041` 一直是 null，是不是从站坏了？」**
`darra-ethercat-parameters` / `darra-ethercat-troubleshooting`

先纠正 API 事实：`SDORead` 失败就是返回 `null`（不是抛异常），`SDOWrite` 返回 `bool`，C# 的 `CoEInstance` 没有 `CoE[index][sub].Value` 这种写法，条目路径是 `ODList[i].OEList[s]` 加 `TryGetBytes`。然后按 abort 码分流：`0x06020000` 对象不存在、`0x06070010` 类型/长度不匹配、`0x08000022` 当前状态不允许、`0x05040000` 协议超时（WKC=0，邮箱没回来，**不是**对象不存在），每条都给处置办法。

**5. 「扫不到从站 / 卡在 PreOp / 运行中掉站了。」**
`darra-ethercat-troubleshooting`

九类现场故障，每类按「判据 → 怎么查 → 怎么修」写成三段。有一条物理判据会被反复用到：**帧从 A 口发出、没从 A 口回来，链路就是通的，问题在接收路径**——所以 `wkc = 0` 不等于断线，别让人先去重插网线。

**6. 「每次连接都要等一分钟。」**
`darra-ethercat-fast-connect`

把这一分钟拆开：SDK 首次初始化 5.7 s、ESI 自动配置 Build 7.5 s、上次没 `Close()` 多付 18–23 s、网卡未就绪重试 25 s。然后用 GUI 导出的 DENI 全量配置、不重复传 ESI 目录、关掉自动启动——实测（Intel 总线、2 从站）Build 从 **7.46 s 降到 3.32 s**，同一进程里重连 **0.5 s**。

**7. 「第一次上现场，从接线到电机转第一下。」**
`darra-ethercat-commissioning`

十步现场顺序：接线 → 选网口 → 确认从站在线 → 核对拓扑 → 配 PDO → 配 DC → 进 OP → 首动 → 验收 → 固化成 DENI。每一步都写「做完怎么算过」和「做错了会怎样」，另附 18 条安全清单——第 1 条是急停/STO 先接好并实测有效，第 2 条是使能前目标值必须等于实际值。

---

## 为什么可信

这是这批技能体和「让模型自由发挥」的区别所在。

**每条结论都带出处。** 技能体里的事实不是模型记忆，逐条标到源文件和行号区间，指向 SDK 源码、GUI 实现或官网文档。举例：

- 「`SlaveCount == null` 是没量到，`0` 才是实测空口」——依据是 `Darra_EtherCAT_ClassLibrary/CSharp/Master/Static/Network.cs:1932-1936`（可空语义）与 `:2824-2825`（0 站 = `EmptyBus`）。
- 「C# 没有 `CoE[index][sub].Value`」——依据是 `.../Master/Slave/CoE.cs:2320` 的 `SDORead(ushort, byte, bool)` 与 `:7230` 的 `SDOWrite` 签名。
- 「`EnsureRtIsolation` 是只读校验，不改系统」——依据是 `Utils/RtIsolation.cs:539-550`；四个隔离布尔各自的含义在 `:639-666`。

**数字是测出来的，条件写在数字旁边。** 快速连接那组数据带完整的分阶段实测表（Intel 总线、2 从站、ESI 目录 122 个文件且索引已预热），并注明冷启动要再多 2.0–2.3 s、换成另一条总线数字怎么变。抖动口径写清是「PDO 帧发送抖动，平均 1.2 µs / 最大 4.5 µs」，同时写明前提和「以现场实测为准」——不把它说成业务逻辑抖动，也不说成任何机器都能拿到。

**查不到就不写。** 实时技能体末尾有一节「查不到、所以没写的项」，明确列出没有公布的信息（测试机型号、采样时长、「最大」的统计口径），并因此不补细节、不举例成「125 µs 下测得」。参数技能体把每个索引标成「标准值，厂商可以有差异」。排障技能体查不到的项直接写「以实际 SDK 返回为准」。

**反假绿是硬约束。** 测试技能体列了十种「看起来通过、其实没验证」的情形：进程还活着就判过、`catch { }` 吞异常、把 `null` 折成 0、用 `actual >= expected` 冒充 WKC 满、拿旧二进制跑新代码、用 Debug 件的结果宣布 Release 可用……并给出「断言必须能真的失败」的写法。

---

## 覆盖全景

| 技能体 | 解决什么问题 | 什么时候找它 |
|---|---|---|
| [`darra-ethercat`](skills/darra-ethercat/SKILL.md) | 写主站程序：DENI 初始化、进 OP、PDO 映射、SDO、CiA 402、DC。C# 与 Python 各一份完整可跑骨架，Java / C / C++ / Rust 给入口差异。 | 要写或改主站侧代码。 |
| [`darra-ethercat-windows`](skills/darra-ethercat-windows/SKILL.md) | Windows 全链路：一个官方安装包装齐实时运行时 + 驱动 + GUI + 六语言 SDK；静默装卸与退出码、装后确认活着、Windows 专属坑（主站独占网口、驱动换入要重启、三个扫描入口怎么选）。 | 在 Windows 上从零走到第一个能跑的主站。 |
| [`darra-download`](skills/darra-download/SKILL.md) | 从零拿到安装包：官网页与固定直链（不需要账号）、版本号规则、728 MB 包的下载与断点续传、SHA256 从 `.sha256` 直链取而不是抄死值、拿不到时的替代路径，最后输出 JSON 契约把接力棒交给安装。 | 机器上连安装包都还没有。 |
| [`darra-runtime-install`](skills/darra-runtime-install/SKILL.md) | 下载并静默安装 / 卸载 / 升级：固定直链、SHA256 校验、退出码（3010 = 成功待重启）、升级直接覆盖安装，以及「先确认、不自动重启、校验不符停手」的边界。 | 机器上还没有运行时，或要升级 / 卸载。 |
| [`darra-verify`](skills/darra-verify/SKILL.md) | 六层验证 L0→L5，输出机器可读 JSON；扫描结论严格三态。不需要从站也能跑完。 | 有人问「装好了吗 / 为什么扫不到」。 |
| [`darra-ethercat-commissioning`](skills/darra-ethercat-commissioning/SKILL.md) | 现场投产十步：接线 → 选网口 → 扫描 → 拓扑 → PDO → DC → 进 OP → 首动 → 验收 → 导出 DENI。每步有通过判据和错误后果，附 18 条安全清单。 | 真机第一次上电。 |
| [`darra-ethercat-gui`](skills/darra-ethercat-gui/SKILL.md) | 图形界面逐页说明：选网卡与三态显示、导入 ESI/ENI/DENI、PDO 映射、Startup SDO、DC 配置、状态机、实时监视、诊断、导出。末尾列出界面里做不到的事。 | 有人正在点界面，问某个页/按钮是干什么的。 |
| [`darra-ethercat-parameters`](skills/darra-ethercat-parameters/SKILL.md) | 参数读写：SDO 四个入口的正确写法、abort 码判读、对象字典加载、CiA 402 常用对象、状态字、`0x1010` 掉电保存、PDO 映射对象。 | 任何伺服 / IO 参数问题，或 SDO 代码要能编译跑通。 |
| [`darra-ethercat-writeback`](skills/darra-ethercat-writeback/SKILL.md) | 运行中改配置：什么状态下能改什么（主站周期 / 三档转换超时 / 看门狗 / 邮箱超时，到从站 DC 四元组 / 启动 SDO / PDO 输出）、哪些必须成组写、哪些根本不该在线改、写完怎么读回确认、被拒的六个码怎么处置。 | 你的程序要在跑的时候改参数，或不确定某个状态能不能改。 |
| [`darra-ethercat-troubleshooting`](skills/darra-ethercat-troubleshooting/SKILL.md) | 九类故障：扫不到从站、扫描返回负数、进不了 OP、AL 状态码、运行中掉站、热插拔恢复、抖动大、升级重装 3010、授权与评估期。每类给判据 / 怎么查 / 怎么修。 | 现场有东西坏了。 |
| [`darra-ethercat-realtime`](skills/darra-ethercat-realtime/SKILL.md) | 实时与抖动：隔离核到底拿到没有（四个布尔分别代表什么）、1.2 / 4.5 µs 这个数字量的是什么、`LoopCycle` 怎么定、抖动变大怎么归因、怎么用 SDK 自证。 | 周期或抖动数字被质疑。 |
| [`darra-ethercat-testing`](skills/darra-ethercat-testing/SKILL.md) | 证明程序是对的：先跑官方开源案例、六级自检、三态判据、能真的失败的断言写法、十种假绿与证据收集清单。 | 需要判断「是真的在工作」还是「看起来在工作」。 |
| [`darra-ethercat-fast-connect`](skills/darra-ethercat-fast-connect/SKILL.md) | 连接慢的分阶段实测归因，和用 DENI 全量配置把 Build 压到秒级的写法；含「不 Close 就退出要等 18–23 s」这类真实代价。 | 启动慢、重连频繁、每次都要等。 |

---

## 怎么用

三种方式，任选一种。

### 方式一：Claude Code 插件（一条命令）

本仓库本身声明为 Claude Code 的插件市场（`.claude-plugin/marketplace.json`），不用拷文件：

```bash
claude plugin marketplace add DarraTechnology/ethercat-skill
claude plugin install darra-ethercat-skill@darra-ethercat-skills
```

会话里也可以用 `/plugin marketplace add DarraTechnology/ethercat-skill`，再 `/plugin install darra-ethercat-skill@darra-ethercat-skills`。**全部技能体随这一个插件一起装上。**

也可以用开放的 `skills` CLI 直接从 GitHub 装：

```bash
npx skills add DarraTechnology/ethercat-skill
```

### 方式二：拷进 skills 目录

```bash
git clone https://github.com/DarraTechnology/ethercat-skill.git

# 个人全局：所有项目都能用
mkdir -p ~/.claude/skills && cp -r ethercat-skill/skills/* ~/.claude/skills/

# 或只给当前项目：跟仓库一起提交，团队每个人都能用
mkdir -p .claude/skills && cp -r ethercat-skill/skills/* .claude/skills/
```

目录结构必须保持 `skills/<name>/SKILL.md`，`name` 和 `description` 从 YAML front matter 读。拷完开新会话即可。

### 方式三：喂给任意 LLM / 自研 agent

每份 `SKILL.md` 都是自包含的 UTF-8 Markdown，没有运行时依赖。三种接法：

1. **整段进 system prompt** —— 最简单，但即使不触发也占上下文。
2. **按需读文件（推荐）** —— 给 agent 一个只读文件工具，指向本仓库；等任务对上了才读对应那份。不触发时零成本，读到的永远是最新文本。
3. **用 `description` 做路由** —— 解析每份文件的 `description` 触发词（EtherCAT、DENI、PDO、SDO、install、verify……），命中才把正文注入。

技能体默认几条前提：API 名、包名、参数名、退出码、状态名都是字面量，不许改写；写代码前先读 <https://ethercat.darra.xyz/ai-prompts.txt>；装东西前必须向人确认；`3010` 只报告不自动重启；`null` / `0` / `N` 三态不可互换。

---

## 它负责哪一段，剩下的归你

| 技能体负责 | 归你 |
|---|---|
| 装、升级、卸载只走官方安装包；装前说明会发生什么并等你确认；`3010` 只报告，不自动重启 | 什么时候装、装在哪台机器、什么时候重启 |
| 告诉你哪个 API 能用、在什么状态下能改、改了会发生什么（映射、DC、WKC、AL 码） | 工艺参数取多少、PDO 选哪几条、增益和软限位怎么定 |
| 把失败语义说准（`null` / `false` / 三态），并给 abort 与 AL 码的处置 | 你的程序怎么重试、怎么报警、怎么和产线联锁 |
| 只描述当前真实在售能力：Windows x64 公开包；Linux 版规划中 | 选型、工期、上线计划 |
| 守住产品边界：Darra 在 ISA-95 Level 1-2（控机器），数据经 OPC UA 交出去 | 上层 MES / ERP 的工单、排产、物料追溯 |
| 给实时与验证的判据和测量方法 | 在你自己的机器上测抖动、跑 24 小时稳定性 |

三句话说清这段分工：

1. **技能体不生成应用。** 它给你片段级的正确写法和判据；应用的架构、模块划分、界面、部署是你的设计。
2. **技能体不接管业务逻辑。** 它可以在你写的时候指出「这里在周期回调里做了 SDO，会阻塞实时线程」，但回调里该算什么，是你决定的。
3. **技能体不替你承担工艺与安全责任。** PDO 映射、DC 参考钟、限位和急停回路要按 ESI、厂商手册和你们的安全流程来；技能体只把「做错了会怎样」写清楚。

---

## 版本与事实来源

技能体跟产品一起维护。三者冲突时的优先级：**产品文档 > 技能体 > 本 README**。

- AI 规则文件（写代码前的唯一 API 事实来源）：<https://ethercat.darra.xyz/ai-prompts.txt>
- SDK 文档：<https://ethercat.darra.xyz/doc/sdk/csharp/>
- 下载与退出码：<https://ethercat.darra.xyz/doc/downloads/>
- 技能体页面：<https://ethercat.darra.xyz/doc/skills/>

---

## 许可证

Proprietary。允许随 Darra EtherCAT Master 使用、复制、原样分发（包括嵌入 AI agent、IDE 助手和内部工具）；不允许修改后以自己的名义再分发，不允许作为独立产品或竞品的一部分销售。全文见 [LICENSE](LICENSE)。商业授权联系 support@darra.xyz。

---

## English

**What this is.** A set of plain-Markdown `SKILL.md` files that teach any AI agent how to operate Darra EtherCAT Master — install it on Windows, call the SDK correctly, verify a live bus, and commission a real machine. No build step, no runtime dependency, nothing to compile.

**What it is for.** The deliverable is always *your* program. The skills make the agent fluent in how our SDK has to be used: how this machine should be wired, which call to make, whether a state can be changed, what an error means, whether a number is normal. Your application — HMI, line software, test bench, robot controller — stays your design.

**What it does for you.** Say "install it on this machine" and the agent explains what will happen, waits for your go-ahead, downloads from the fixed URL, checks the SHA256, runs the official silent installer, and reads exit code `3010` as success-with-reboot-pending — it never reboots for you. Say "is it actually alive?" and it walks six layers (installer → SDK files → SDK loads → adapters enumerate → bus scan → optional OP) and hands back machine-readable JSON. Say "SDO read of `0x6041` keeps returning null" and it corrects the API first (`SDORead` returns null on failure, `SDOWrite` returns bool, there is no `CoE[index][sub].Value`), then classifies the abort code. Say "connect takes a minute" and it shows the measured breakdown (5.7 s native init, 7.5 s ESI auto-config, 18–23 s if the previous process never called `Close()`) and the fix that brings Build from 7.46 s to 3.32 s on the measured setup.

**Why it is trustworthy.** Every factual claim carries a source file and line range pointing at the SDK source, the GUI implementation, or the published docs. Measured numbers are published with their test conditions next to them, and the skills contain explicit "not measured, so not written" sections rather than filling gaps with guesses.

**How to use it.** `claude plugin marketplace add DarraTechnology/ethercat-skill` then `claude plugin install darra-ethercat-skill@darra-ethercat-skills`; or copy `skills/*` into `~/.claude/skills/`; or feed a single `SKILL.md` to any agent and route on its `description` trigger words.

**What it will not do.** It will not generate your application, take over your business logic, or make process decisions for you. It will not bypass the official installer, install anything without asking, or reboot for you. The public installer is Windows x64; the Linux version is planned, not released. It also does not prove real-time performance — verification proves the install is alive, not that your jitter is good.

**Docs.** <https://ethercat.darra.xyz/doc/skills/> · **License.** Proprietary; use and redistribute unmodified with Darra EtherCAT Master, no modified redistribution, no standalone resale. See [LICENSE](LICENSE).
