---
name: darra-ethercat-windows
description: >
  在 Windows 上把 Darra EtherCAT 装好、跑通、写第一个主站程序的专用技能。一个官方安装包同时装
  实时运行时 + 驱动 + GUI + 六语言 SDK；静默安装/升级/卸载命令与退出码（3010 = 成功待重启）、
  升级直接覆盖安装、装后确认活着（服务在跑 + 安装包签名有效 + 扫一遍总线）、C# 主站最小可跑程序与
  六语言入口差异、Windows 专属坑（主站独占网口需 Close 归还、驱动换入要重启、三个扫描入口怎么选）、
  以及怎么区分「没量到」和「实测空口」。
  触发词：Windows、装包、安装、装驱动、静默安装、silent install、卸载、重装、升级、3010、需要重启、
  --rt-masters、装完怎么确认、写主站程序、
  QuickScan、ScanSlaves、QuickSlaveCount、StandardScan、绑定网卡、专用口、网口不归还、
  扫不到从站、没量到、空口、三态。
---

# Darra EtherCAT for Windows

在 Windows 上从零装好、跑通、写出第一个主站程序，用这份 skill。

只做 Windows。公开安装包是 Windows x64 一个 exe，Linux 版规划中，**不要写 Linux 安装命令**。

没写在这里、也没写在规则文件里的安装器参数、端口、接口，不要编。API 名称以
[ai-prompts.txt](https://ethercat.darra.xyz/ai-prompts.txt) 为准，读不到就停，不要凭记忆补接口。

同仓另外三份通用技能可以一起用：

- [`darra-runtime-install`](../darra-runtime-install/SKILL.md) — 下载 / 校验 / 静默装卸载的完整契约
- [`darra-verify`](../darra-verify/SKILL.md) — 装完跑小程序出机器可读 JSON
- [`darra-ethercat`](../darra-ethercat/SKILL.md) — 主站 API 细则（PDO / SDO / CiA 402 / DC）

---

## 1. 前置：一个官方安装包解决全部

`Darra-EtherCAT-Setup.exe` 是唯一入口，一次装齐四样东西：

| 装到什么 | 是什么 | 落点 |
|---|---|---|
| 实时运行时 | DarraRT 实时驱动配套的运行环境 | 安装目录 |
| 驱动 | 随安装包自动安装，无需单独获取 | 由安装器决定 |
| GUI | Darra EtherCAT Master 配置与调试工具 | 开始菜单 |
| 六语言 SDK | C# / C / C++ / Python / Java / Rust | `<安装目录>\SDK\`（默认 `C:\DARRA\EtherCAT_Master\SDK\`） |

**不要单独下载驱动、不要手工拷贝驱动文件、不要手工绑定网卡。** 驱动的安装与绑定只走安装器。

系统要求：

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 x64 |
| 运行时 | .NET Framework 4.7.2 或更高 |
| 网络适配器 | 标准以太网网卡（Intel / Realtek 等），物理有线 |
| 权限 | 管理员 |
| 运行库 | Visual C++ Redistributable x64（缺失时程序启动会提示） |

装之前先跟用户说清楚两件事，拿到确认再动手：

1. 会替换机器上的实时驱动；带 `--rt-masters` 时还会预留对应的实时核。
2. 装完可能要重启才生效。

不建议装在日常开发机上，尤其是 USB 网卡的笔记本。**不许「先装上再说」。**

未激活可免费评估：每次开机、驱动启动后 2 小时内可用，到期停止总线通信（同一开机内重开程序不重新计时）。

---

## 2. 安装 / 升级 / 卸载

下载只认不带版本号的固定直链，**不要按版本号拼文件名**：

```
https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe
https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe.sha256   ← 同一地址加 .sha256
```

下载后算 SHA256 与校验文件比对，不一致就停手，把两个值告诉用户，不要「先装再看看」。

命令行静默（管理员 PowerShell）：

```powershell
# 安装 / 升级（装没装过旧版都是这一条）
.\Darra-EtherCAT-Setup.exe --silent --install

# 主站数 2（安装目录由安装器决定，实时优化不可关闭）
.\Darra-EtherCAT-Setup.exe --silent --install --rt-masters 2

# 卸载（独立动作，只在用户明确要卸时执行）
.\Darra-EtherCAT-Setup.exe --silent --uninstall
```

参数只有这几个，**没有 `--repair`**（加了会被拒），也没有对外的 `--resume`（那是安装器重启后自己收尾用的）：

> **实测（2026-11-18 / 2.13.16）：未知开关不会被拒绝。** `--silent --install --no-such-flag` 会照常执行安装
> 并以 `3010` 结束 —— 拼错开关不会报 1639，只会静默按有效参数装上。1639 只覆盖「已知参数但值不合法」
> （`--rt-masters` 缺值/非整数/越界、`--repair`）。所以命令要逐字对照本表，不能靠退出码发现拼写错误。

| 参数 | 含义 |
|---|---|
| `--silent --install` | 静默安装 / 升级 |
| `--silent --uninstall` | 静默卸载 |
| `--rt-masters 1..4` | RT 主站数，即预留的实时核数，装完记在机器上 |

安装目录由安装器决定，实时优化不可关闭。

`--rt-masters` 只收 1 到 4 的整数。缺值、不是整数、越界 → 安装器直接失败（1639），**不兜底成 1**。
用户没说要几个就问，不要替用户补默认值。

**升级 = 直接再跑一次安装包，不用先卸载、不用先重启。** 安装器按驱动状态自动处理已装版本：
先停旧驱动，再删旧驱动与旧程序文件，然后装本次版本。把升级拆成「卸载 → 重启 → 安装」三步是错的。

### 退出码

| 退出码 | 含义 | 下一步 |
|---|---|---|
| 0 | 成功 | 继续后面步骤 |
| 1 | 失败（未分类异常，或没有管理员权限） | 确认管理员权限与安装包完整性，重试一次；还失败就如实告诉用户 |
| 1602 | 用户取消，动作没执行 | 问用户还要不要装，不要自动重装 |
| 1603 | 执行中出错（含空间不足、临时目录写不进去） | 查磁盘空间和权限，处理后再跑 |
| 1604 | 卸载没做全，机器上还剩文件 | 如实告诉用户还剩什么，或联系 support@darra.xyz |
| 1618 | 另一个安装 / 卸载事务正在跑 | 等它结束再重试，不要同时开几个安装器 |
| 1622 | 日志写不进去，动作已停手 | 先解决磁盘空间、目录写权限，再重跑 |
| 1639 | 命令行参数对这个动作不可用（`--rt-masters` 值不合法也算这个） | 按上面的命令重写，不要自己加参数 |
| **3010** | **操作成功，重启后生效** | **成功码，不是失败**（见下） |

**3010 有两档，两档都是成功**：

1. 本趟已装完，重启后生效。
2. 驱动本趟停不下来，安装器已安排好**开机换入**，重启后自动收尾，**不必再跑安装包**。

对用户就说「已安装成功，需要重启才生效」，什么时候重启由用户决定。**不要自动重启机器**，
**不要因为「还没生效」就反复重装**。

---

## 3. 装完怎么确认活着

按顺序过一遍，四条都过才算装好。前三条是本机状态，第四条是总线。
要逐层判据（L0 安装事实 → L1 SDK 就位 → L2 能加载 → L3 网卡 → L4 扫总线 → L5 可选进 OP），
跑 [`darra-verify`](../darra-verify/SKILL.md)。

**① 安装器退出码是成功码**

`0` 或 `3010`。`3010` = 已成功、**重启后**生效，先重启再往下看。

驱动随安装包一并安装，程序启动后自动接入。产品**不以「某个 Windows 服务在跑」作为判据**，
也不要自己发明 `Get-Service` / `sc query` 之类的检查 —— 驱动缺失时程序会把结论写进日志，
主站初始化会如实失败，那才是判据。

**② 安装包签了名**

```powershell
Get-AuthenticodeSignature .\Darra-EtherCAT-Setup.exe |
    Select-Object Status, SignerCertificate
```

期望 `Status = Valid` 且有签名者证书。`NotSigned` / `HashMismatch` / `NotTrusted` 都要报给用户，
不要当成小事。

**③ SDK 就位**

`<安装目录>\SDK\` 下有六种语言的包；也可以直接走公共包管理器（见第 4 节），那条路径不依赖安装目录。

**④ 扫一遍总线**

用 SDK 扫一次（第 6 节怎么读结果）。或者直接开 Darra EtherCAT Master 工具扫从站。
扫出来的结论是「有 N 个站」还是「实测空口」都算通过 —— 空口是正常结论，不代表没装好。

> 想要一段能直接引用的机器可读输出（逐口 JSON + 三态结论），跑 [`darra-verify`](../darra-verify/SKILL.md)。

---

## 4. 写第一个主站程序

用户没指定语言时用 **C#**。最小可跑骨架（网卡名来自 `GetNetworkAdapters()`）：

```csharp
using System;
using DarraEtherCAT_Master;

class Program
{
    static void Main()
    {
        // 1. 选卡 —— Name 形如 \Device\NPF_{GUID}
        foreach (var a in DarraEtherCAT.GetNetworkAdapters())
            Console.WriteLine($"#{a.Index} {a.Name} [{a.LinkStatus}] capable={a.EtherCatCapable}");

        // 2. 建主站 —— 必须看 result.Success，不要只拿 .Master
        var result = new DarraEtherCAT()
            .SetENI(@"config.deni")          // 有 DENI 用 DENI；没有才用 ESI
            .Build();
        if (!result.Success) { Console.WriteLine(result.Message); return; }
        var master = result.Master;

        // 3. 绑网口（写了 SetENI 又写 SetNetwork 时，后写的网口生效）
        // master.SetNetwork(@"\Device\NPF_{GUID}", "");

        // 4. 订阅事件 → 设周期、配 DC → 进 OP → 回调里写 PDO
        bool ok = master.SetState(EcState.OP, out string err);
        Console.WriteLine(ok ? "OP" : err);

        // 5. 结束必须归还网卡
        master.Close();
    }
}
```

`Build()` 只能调用一次。`master.SetState(EcState.OP, out string err)` 里 `EcState.OP` 是枚举值 ——
不是 `Operational`，也不是 `Run`（Rust 才是 `EcState::Operational`）。

### 六语言入口差异

功能对齐，入口按各自语言惯例，**不要把 C# 的写法套到别的语言上**：

| 语言 | 装包 | 建主站 | 进 OP |
|---|---|---|---|
| C# | `dotnet add package Darra.EtherCAT.Master` | `new DarraEtherCAT().SetENI(p).Build()` → 看 `result.Success` | `master.SetState(EcState.OP, out err)` |
| Java | Maven `xyz.darra:darra-ethercat-master`（JDK 11+） | `EtherCATMaster.create().setENI(p).build()`（静态工厂，不用 new）→ 看 `r.success`，`r.master` 是 `AutoCloseable` | `master.setState(EcState.OP)` |
| Python | `pip install darra-ethercat-master`（Python 3.12，64 位） | `EtherCATMaster().set_eni(p).build()`（`build()` 返回自身） | `master.set_state(EcState.OP)` |
| C | `darra_ethercat_c-win-x64.zip`，`#include "ethercat.h"` | `deni_load` → `Initialize` → `xml_apply_config` → `SetNetwork` | `SetStateSequence(m, EC_STATE_OPERATIONAL, 10000)` → `Start(m)` |
| C++ | `darra_ethercat_cpp-win-x64.zip`，`#include "ethercat.hpp"`，C++17 | `darra::dll_t dll; darra::EtherCATMaster master(dll);` 再 `SetENI(p).Build()`（返回 bool） | `master.SetState(darra::EcState::OP)` |
| Rust | `cargo add darra-ethercat-master` | `EtherCATMaster::builder().set_eni(p).build()?.master` | `master.set_state(EcState::Operational)?` |

语言包直链在下载页，不要另造链接：

- C# https://ethercat.darra.xyz/doc/sdk/csharp
- Java https://ethercat.darra.xyz/doc/sdk/java
- Python https://ethercat.darra.xyz/doc/sdk/python
- C https://ethercat.darra.xyz/doc/sdk/ccpp
- C++ https://ethercat.darra.xyz/doc/sdk/cpp
- Rust https://ethercat.darra.xyz/doc/sdk/rust

**Rust 包在 crates.io 上**，`cargo add darra-ethercat-master` 就能加，不需要手解包。
离线环境用下载页的 `darra-ethercat-master.crate`（源码包）解出后走 path 依赖；`darra_ethercat_rust.zip`
是完整树（crate 源码 + 运行库）。

C# 聚合表 `GetNetworkAdapters()` / `QuickScan()` / `StandardScan()` 只有 C# 有；
其它语言同样提供「选卡 / 快扫 / 完整扫描 / 取消」四个入口，只是没有这两张聚合表。

### 完整主站的时序

1. `Build()`，检查成功
2. 订阅事件
3. 设周期、配 DC（CSP / CSV / CST 必须在 `SetState(OP)` **之前**配 DC）
4. `SetState(OP)`
5. `Start()` 起 PDO 周期（Python / Java / C / C++ / Rust 必调；C# 可省，幂等）
6. `InitializePdoOffsets()`，再设操作模式
7. `Enable()` 一次（**进 OP 之后**才调）
8. 在 `ProcessDataCyclicSync` 周期回调里写 PDO
9. `master.Close()`

回调里只读写 PDO，不做 SDO / Sleep / 文件 / 界面刷新 / 等锁。事件不在 UI 线程：
WinForms 用 `Invoke` / `BeginInvoke`，WPF 用 `Dispatcher`。更多 API 细则见
[`darra-ethercat`](../darra-ethercat/SKILL.md)。

---

## 5. Windows 专属坑

### 5.1 主站独占网口，不 Close 网口不归还

`SetNetwork(m, @"\Device\NPF_{GUID}", "")` 之后这块网口被主站**独占**：

- 程序退出前必须 `master.Close()`。不调 → **网口不归还，下次启动绑定失败**。
- 别的程序此时扫这个口，会拿到 `OccupiedByMaster`（**事实，不是失败**），不是「没有从站」。
- 同一进程里别的主站实例占用该口时，`GetNetworkAdapters()` 的 `UsedByAnotherInstance` 为 true。

**用作 EtherCAT 主口的那块网卡是专用口**：它跑的是 EtherCAT 帧，不要同时拿它上网、开共享、
做桥接或当普通网口用。要联网另接一块网卡。选卡只认物理有线 802.3（`EtherCatCapable = true`）；
无线 / 虚拟 / 黑名单口**通常根本不出现在 `GetNetworkAdapters()` / `QuickScan()` 的清单里**
（实测机器上有一张 WLAN，清单里没有它）；如果出现了，它的 `EtherCatCapable` 为 `false`、快扫给 `Unsupported`。

绑定状态（`BoundProtocol`）由官方安装器配置，**不要自己手绑 / 手解协议**。

### 5.2 驱动换入要重启，别反复重装

安装器在驱动运行时不会原地替换内核文件，而是把「停旧驱动 → 换新驱动」安排到**下次开机**，
本次返回 3010。所以：

- 3010 = 成功待重启，**不是失败**。重启后系统自动收尾，**不要再跑安装包**。
- 装完发现行为还是旧的，第一件事是确认「重启了没有」，不是重装。
- 万一重启后仍未完成，再运行一次本安装包（这是文档写明的兜底，不是常规动作）。
- 不要自动重启用户的机器。重启时机由用户定。

### 5.3 三个扫描入口怎么选

| 入口 | 什么时候用 | 返回什么 |
|---|---|---|
| `QuickScan()` | 「哪个口有从站 / 没有是为什么」——每口一行结论，不复述网卡属性 | `List<NicQuickScanRow>`，含 `State` + `SlaveCount` + `NativeCode` |
| `QuickSlaveCount(adapter)` | 只要**单口**从站数，DENI / 下拉数量走这条。不读 EEPROM，快 | `int`：`>= 0` 是站数（`0` = 实测空口）；**负数是原因码，不是站数** |
| `ScanSlaves(adapter, secondary)` | 要**逐站详情**（厂商 ID / 拓扑 / 端口类型 / 地址）来做设备清单、选型核对。读 EEPROM + 拓扑，慢 | `List<ScannedSlaveInfo>` |
| `StandardScan(adapter, secondary, out outcome)` | 同上，但要「扫描 + 一个结局码」一步拿到 | 列表 + `ScanOutcome`（`EmptyBus` / `AdapterNotFound` / `Aborted` / …） |
| `GetNetworkAdapters(includeSlaveCount)` | 做选卡界面：网卡标识 / 能力 / 绑定 / 占用 / 链路 | `NetworkAdapterInfo[]` |

三条容易搞错的：

1. **`ScanSlaves` 和 `StandardScan` 的区别**只是结局码的粒度：只要「扫描 + 一个结论」优先
   `StandardScan`；要扫描接口本身的原始返回码才用 `ScanSlaves`。
2. **`QuickScan` 的 `NicScanState` 和 `GetNetworkAdapters` 的 `NicScanStatus` 是两个不同枚举**，
   不要混用取值。空口在前者叫 `EmptyBus`，在后者叫 `IdleNoSlave`。
3. `QuickSlaveCount` 返回负值（如 `-2` 未测量、`-3` 主站占用）时**不能当 0 站**。

### 5.4 克隆部署：镜像搬到新机器，网卡名字一样但 MAC 变了

客户现场常用克隆镜像部署。Windows 里的接口名（「以太网 3」）甚至 NDIS 接口 GUID 都可能原样保留，
但 MAC 是网卡硬件的出厂地址，**换了机器一定不同**。

先把两条路径分开——它们不是同一条链：

- **SDK 主体选卡不看 MAC**：`SetENI(...).Build()` 走原生 `ParseDeniXmlConfig` → `ResolveNicByDeniInfo`，
  只认 `deni:Interface`（`\Device\NPF_{GUID}` / Windows 友好名 / 网卡描述）与 `deni:ExpectedSlaveCount`。
  名字命中就直接绑；命不中按「从站数 == DENI 期望数」找唯一一张；再不行才报 `-42`（`RESULT_ERR_DENI_NIC`）。
  **`deni:InterfaceMAC` / `Master/Info/Source` 不参与选卡**，所以纯 SDK 用法在克隆机上通常能连
  （GUID 变了会多付一次枚举 / 活扫）。
- **应用层自己加的 MAC 预检会拦**：例如开源案例里的倒立摆程序，`MatchNic` 要求 DENI 的
  `Master/Info/Source` 与本机唯一一张网卡的 MAC 相等；克隆机上必然不等，而且 `--nic` 也救不了
  （显式给名后仍比对 MAC）。这时报错是应用层的 fail-closed，不是 SDK 连不上。

正解按优先级：

1. **在新机器上重新导出 DENI**（首选）。MAC 与本机一致，回到最快的「名字命中」，不需要任何放宽。
2. **显式开关**：倒立摆示例的 `--allow-nic-name-fallback`（CLI 加在 `--cli` 之后；GUI 用
   `FurutaPendulum.exe --gui --allow-nic-name-fallback`）。默认关闭，只按 DENI 里写死的
   `deni:Interface` / `deni:InterfaceDescription` 精确匹配且必须唯一，命中后日志大声写明
   「DENI 原本的 MAC → 本机实际网卡名 + MAC + 描述 + GUID」。
   认错卡会把主站绑到另一张连着别的设备的网卡上，所以**不允许默认放宽**。
3. **不要为了凑 DENI 去改网卡 MAC**：不是所有驱动都支持，而且两台机器同 MAC 在同一网段会冲突。

现场怎么判走了哪条路（GUI / SDK 日志原文）：

| 日志 | 含义 |
|---|---|
| `快速连接：DENI 网卡名 '...' → ...，跳过挑选` | 名字命中，最快路径 |
| `ResolveNicByDeniInfo: 名称不对, 唯一网口从站数=N 与 DENI 一致 → ...` | 克隆机按从站数兜底（多一次枚举 / 活扫） |
| `ResolveNicByDeniInfo: 无匹配网卡` / `-42` | 名字和从站数都对不上，必须重新导出 DENI |
| `克隆部署网卡名回退已启用：DENI 记录的网卡 MAC=... 在本机不存在；改用本机网卡 "..."` | 示例程序在显式开关下按名字回退，务必核对 MAC 是否就是要接的那张卡 |

细节、四场景实测数字与判据见
[`darra-ethercat-fast-connect`](../darra-ethercat-fast-connect/SKILL.md) §2.1。

---

## 6. 验证：区分「没量到」和「实测空口」

这两句话指向完全不同的排查方向，绝不能互相冒充。

**判据（严格三态）：**

| 结论 | 怎么判 | 含义 | 下一步 |
|---|---|---|---|
| 有站 | `SlaveCount >= 1`，`State = HasSlaves` | 实测 N 个从站 | 继续进 OP、读从站 |
| **实测空口** | `SlaveCount == 0` **且** `State == NicScanState.EmptyBus`（完整扫描看 `ScanOutcome.EmptyBus`） | 扫过了，确实 0 个从站。**正常结论，不是失败** | 告诉用户「SDK 能扫、这个口是空的」；接线后再跑一遍 |
| **没量到** | `SlaveCount == null` | 本轮没拿到数字，**不是 0 站** | 看 `State` 说清原因 |

`NicScanState` 各值怎么读：

| 值 | `SlaveCount` | 说法 |
|---|---|---|
| `HasSlaves` | ≥ 1 | 实测有从站 |
| `EmptyBus` | 0 | 实测空口 |
| `OccupiedByMaster` | null | 本机主站占用该口，扫描按设计跳过（**事实，不是失败**） |
| `NotMeasured` | null | 没量到（开卡失败 / 未参与本轮） |
| `NotScanned` | null | `adapters` 参数没选中该口 |
| `Unsupported` | null | 这个口不能当 EtherCAT 主口（**不等于驱动没装好**） |
| `Aborted` | null | 被 `AbortScan()` 中断 |
| `Failed` | null | 底层失败，原始码看 `NativeCode` |

**三句话话术：**

- 有站 → 「扫到 N 个从站」
- 空口 → 「扫过了，总线上确实没有从站」
- 没量到 → 「这轮没量到，原因是 …」，**绝不说「没有从站」**

全都是 `NotMeasured` / `OccupiedByMaster` / `NotScanned` / `Unsupported` / `Aborted` / `Failed`、
一个 `EmptyBus` 都没有时，就是**没量到**。按 `State` 和 `NativeCode` 把原因说清楚，别猜从站。

> 实测提醒（2.13.16）：**链路 Down 的网口也可能被快扫报成 `EmptyBus` + `SlaveCount=0`**（同一张卡
> `GetNetworkAdapters()` 的 `LinkStatus=Down`、`QuickSlaveCount` 返回负码）。判「实测空口」前先确认
> 该口 `LinkStatus == Up`；Down 的口一律按「没量到」说。

反过来，一个可复用的自检片段（逐口三态）：

```csharp
foreach (var row in DarraEtherCAT.QuickScan())
{
    string verdict = row.State == DarraEtherCAT.NicScanState.HasSlaves ? $"{row.SlaveCount} 站"
                   : row.State == DarraEtherCAT.NicScanState.EmptyBus ? "实测空口"
                   : $"没量到（{row.State}, 码 {row.NativeCode}）";
    Console.WriteLine($"{row.Name}: {verdict}");
}
```

`NicScanState` 是 `DarraEtherCAT` 的**嵌套枚举**，代码里必须写全名 `DarraEtherCAT.NicScanState`，
只写 `NicScanState` 编译不过（CS0103）。同理 `ScanOutcome` 要写 `DarraEtherCAT.ScanOutcome`。

**这条路径证明不了的事**：实时性能、抖动、硬实时、从站能不能进 OP。别顺着往下说。

---

## 7. 不要生成的写法

- 升级写成「先卸载、重启、再装新版」——升级就是再跑一次 `--silent --install`。
- 把 3010 当失败、反复重装、或自动重启机器。
- 按版本号拼安装包文件名；自己发明参数（`--repair` 不存在）；给 `--rt-masters` 补默认值。
- 在日常开发机上装这个包做实验。
- 手工拷贝驱动文件、手工绑定网卡、手工改绑定关系 —— 装驱动只走官方安装包。
- 不调 `master.Close()`，或在退出路径上漏掉它。
- 有 DENI 时又调 `SetNetwork(...)` —— DENI 已带网口，实测 SetENI 后再 SetNetwork 会让 `SetState(OP)` 失败（AL `0x0017`）。
- 用作 EtherCAT 主口的网卡同时上网 / 桥接 / 共享。
- `Build().Master` 不检查 `result.Success`；`EcState` 写成 `Operational` / `Run`（C#）。
- 把 `null` 当 0 站，或把「没量到」说成「没有从站」。
- 用 `QuickSlaveCount` 的负返回值当站数。
- 混用 `NicScanState` 与 `NicScanStatus` 的取值。
- 编造下载地址、包名、端口、安装步骤或文档链接。
