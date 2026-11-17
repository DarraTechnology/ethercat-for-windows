---
name: darra-ethercat-fast-connect
description: >
  主站连接慢、每次都要重新连、等半分钟到一分钟时用这份。讲清楚慢在哪一阶段，
  以及用 GUI 导出的 DENI 全量配置把 Build 从 7.5 s 压到 0.5 s（重连）的写法。
  覆盖 C#（`DarraEtherCAT`）与六语言通用的调用顺序；给实测秒数，不给估算。
  写代码前先读 https://ethercat.darra.xyz/ai-prompts.txt ，API 以那份为准，不要另造接口。
  触发词：连接慢、加载慢、等一分钟、每次都要重连、快速连接、快启动、DENI、ENI、SetENI、
  SetNetwork、Build 慢、ESI 自动配置、扫描从站慢、SetEsiFiles、DisableAutoStartup、
  AutoStartup、配置缓存、导出 DENI、DarraEtherCAT、BuildAsync、进 OP 慢。
---

# Darra EtherCAT 快速连接

这份 skill 只解决一件事：**把「连接」从一分钟压到几秒**。
主站 API、PDO、SDO、CiA 402 的完整用法不在这里，看 [`darra-ethercat`](../darra-ethercat/SKILL.md)；
装完怎么验证看 [`darra-verify`](../darra-verify/SKILL.md)。

同仓另外几份可以一起用：

- [`darra-ethercat`](../darra-ethercat/SKILL.md) — 主站 API 细则
- [`darra-ethercat-windows`](../darra-ethercat-windows/SKILL.md) — Windows 端到端
- [`darra-verify`](../darra-verify/SKILL.md) — 装完验证

---

## 一句话总则

1. **有 DENI 就用 DENI**：DENI 是完整配置（网口 + 从站 + PDO + DC + 启动参数），一次配好，每次直接加载。
2. **用 DENI 时不要再 `SetEsiFiles`**：那会把 ESI 目录再扫一遍，白付 1.2–1.5 s。
3. **进程别反复起**：第一次调用原生库要付约 5.7 s 的固定初始化；之后同一个进程里重连 Build 只要 0.5 s。
4. **退出必须 `Close()`**：不关就退出，下一次连接要等驱动把实例交还，实测多花 18–23 s。
5. 失败即失败：`result.Success == false` 就把 `result.Message` 原样报出来，不要包一层重试掩盖。

---

## 1. 为什么会慢

同一条总线、同两块从站、同一个进程逐项计时（ETH 台架 `192.168.3.120`，2026-11-18 实测）：

| 阶段 | ESI 自动配置 | DENI 全量配置 | 说明 |
|---|---|---|---|
| 原生库首次初始化（每进程一次） | 5.7 s | 5.7 s | `new DarraEtherCAT()` 或第一次静态调用时一次付清 |
| 读 DENI 契约 + 解析 + 选网卡 | — | 2.5–2.8 s | 原生一次做完「选卡 + 活扫 + 套全配置」 |
| 绑定网卡并扫描从站 | 3.49 s | 含在上面 | ESI 路径这里是独立一段 |
| 读从站身份 + FSoE 能力探测 | 0.69 s | 0.69 s | 逐站 SDO 预探 `0xF980:01` / `0x9001:02` |
| **枚举 + 轻量扫描 ESI 候选文件** | **1.52 s** | **1.52 s** | 122 个文件；**DENI 路径默认也会走这一段** |
| ESI 精确匹配 | 0.18 s | 0.18 s | 命中即止 |
| 应用从站配置（PreOp + SM/PDO + DC） | 1.36 s | 0.93 s | AutoStartup |
| **Build 合计** | **7.46 s** | **6.13 s** | |

关键事实：**默认的 DENI 路径并不跳过 ESI 匹配**。不传 `SetEsiFiles`、并显式
`DisableAutoStartup()` 之后，Build 才降到 3.3 s。

一分钟是怎么攒出来的（每一项都有实测或代码常数）：

| 项 | 代价 | 触发条件 |
|---|---|---|
| 原生库首次初始化 | 5.7 s | 每个进程一次 |
| ESI 自动配置 Build | 7.5 s | 没有 DENI，每次连接都扫站 + 匹配 + 算映射 |
| 上一次没 `Close()` | **18–23 s** | 进程被杀/崩溃/直接退出；日志 `上一代会话属主已死, 但驱动在硬上限内仍未交还 instance` |
| 网卡未就绪重试 | **25 s** | `BIND_NIC error=21`，代码是 5 次 × 5000 ms 固定间隔 |

5.7 + 7.5 + 22 + 25 ≈ 60 s。把这四项去掉，就是几秒。

---

## 2. 正解：DENI 全量配置

DENI（`.deni` / `.xml`）是**完整配置**：网口、从站、PDO 映射、DC、启动参数、看门狗、状态机超时。
配置工具/GUI 配好一次导出，以后每次加载都不用再扫站、再匹配、再算映射。

最小写法（C#）：

```csharp
using DarraEtherCAT_Master;

var result = new DarraEtherCAT()
    .SetENI(@"config.deni")        // 网口由 DENI 里的 InterfaceMAC 决定，不要再 SetNetwork
    .Build();

if (!result.Success) { Console.WriteLine(result.Message); return; }
DarraEtherCAT master = result.Master;
```

三条硬规矩：

1. **`SetENI` 之后不要再 `SetNetwork`** —— 后写网口会让 SDK 退回「C# 自解析」慢路径。
   网卡换过/改名了就让 SDK 按 DENI 里的网卡名与 MAC 自己找。
2. **用 DENI 时不要 `SetEsiFiles`** —— 实测多付 1.2 s（Intel 总线 6.13 s → 4.91 s）。
3. **`Build()` 只能调一次**，必须看 `result.Success`。

DENI 路径下网卡是怎么选的（了解即可，不要自己写选卡逻辑）：

- ① 按 `deni:Interface` 的名字 / 描述 / `{GUID}` / Windows 友好名匹配，只枚举不探测；
- ② 名字对不上时按「从站数 == DENI 期望数」找唯一一张；
- ③ 还对不上才逐口完整扫描。

所以 **DENI 里的网卡名与机器不一致时，会退化成慢路径**。换机器/换网卡后重新导出一份。

---

## 3. DENI 从哪来：在 GUI 里配好一次，导出

### 3.1 手工导出（当前界面）

```
主窗口 → 「导出」 → 「模板程序」 →（弹出「导出程序」窗口）→ 左侧「导出」 → 「DENI 配置文件」
```

保存对话框过滤器是 `DENI 配置文件|*.deni`，默认文件名 `config.deni`；同一对话框也能存成 `*.xml`。
以实际界面为准；界面文案随版本可能微调，但入口固定在「导出」这一组里。

导出前 GUI 必须已经扫描过一次真实总线（有从站、拓扑正确），否则导出的是空配置。

### 3.2 GUI 自己就在用的缓存（最省事）

GUI 全扫描成功后**自动**把当前配置写一份到：

```
C:\ProgramData\Darra\EtherCAT\config-cache\deni-<网卡标识>.xml
```

下次启动命中这份缓存就直接走 `SetENI` 原生快路径（界面上显示「使用缓存配置快速启动」）。
缓存文件的 MAC 与当前选中网卡不一致时会自动弃用并回落到全扫描。

**要一份现成的 DENI，直接拿这个目录里的文件就行**，不需要先去点导出窗口。

### 3.3 AI / 命名命令注入

GUI 给这个动作注册了命名命令 `exportDeni`（`Main.cs` 的命名命令分发），会打开导出窗口并自动生成 DENI，
最后停在保存对话框。自动化场景下用它比点界面稳。

### 3.4 第三方只能读、不能写

`SaveXMLConfiguration` 是 **internal**，只对 IDE / 中间层开放，NuGet SDK 用户拿不到。
**导出放在 GUI（或自有工具）里做，运行时只用 `SetENI` 读。**

---

## 4. 最快的一条路（实测 3.3 s）

DENI 已经把从站、PDO、DC 全写死了，就不需要 SDK 再去扫 ESI、再去逐站配一遍：

```csharp
var result = new DarraEtherCAT()
    .SetENI(@"config.deni")
    .DisableAutoStartup()     // 跳过 ESI 匹配 + SDK 侧逐站配置（DENI 契约已完整）
    .Build();

if (!result.Success) { Console.WriteLine(result.Message); return; }
var master = result.Master;
```

实测（Intel 总线，2 从站）：Build **3.32 s**，进 OP 正常，`WKC 4/4`，`Start` 成功。

> 什么时候**不能**这么写：DENI 里没有带启动参数（SDO 初始化）、或从站是需要在 PreOp 阶段
> 做邮箱配置的伺服。这类拓扑请保留默认的自动启动配置，只把 `SetEsiFiles` 去掉。

---

## 5. 不要 DC 的写法

DC 由 DENI 契约决定：**DENI 里 DC=disabled 时，SDK 不会去武装 `0x0980`**，日志会写
`DENI 契约 DC=disabled → 不武装 0x0980 ... => FreeRunByContract`；仍然可以跑 PDO。

- 适用：普通 IO 从站、MDP 耦合器、步进驱动器这类不需要同步时钟的站。
- 不适用：CSP / CSV / CST 伺服 —— 这类必须 DC，DENI 里要带 DC。
- 应用层要显式打开 DC：`master.ConfigureDC(ns)`，周期与 `master.LoopCycle` 一致或为其整数倍，
  且必须在 `SetState(OP)` **之前**调。

实测对比（同一条 Intel 总线，2 从站）：DC 关闭时 `dcArmed=0/2`、进 OP 1.12 s；
伺服总线（DC 开启）`dcArmed=2/2`、进 OP 2.2–2.7 s。DC 关掉能省一点，但伺服别省。

---

## 6. 实测数字

台架：`192.168.3.120`，SDK `Darra.Core.dll` 2.13.16 + `Darra.EtherCAT.Master` 2.13.16，
两条独立总线各 2 个从站。`ESI` 目录 122 个文件且索引已预热（冷启动会再多 2.0–2.3 s）。

### 6.1 新进程第一次连接（进程启动 → PDO 跑起来）

| 写法 | Build | 进程→PDO | WKC | DC 武装 |
|---|---|---|---|---|
| ESI 自动配置（`SetNetwork` + `SetEsiFiles` + 自动启动） | 7.46 s | **15.4 s** | 4/4 | 1/2 |
| DENI（`+ SetEsiFiles` + 自动启动） | 6.13 s | 13.7 s | 4/4 | 0/2 |
| DENI，不传 `SetEsiFiles` | 4.91 s | 12.5 s | 4/4 | 0/2 |
| **DENI，不传 `SetEsiFiles` + `DisableAutoStartup()`** | **3.32 s** | **11.6 s** | 4/4 | 0/2 |

伺服总线（HCFA X3E + Ezi-SERVO2）同一套对比：

| 写法 | Build | 进程→PDO | WKC | DC 武装 |
|---|---|---|---|---|
| ESI 自动配置 | 7.79 s | 15.7 s | 4/4 | 1/2 |
| DENI（`+ SetEsiFiles` + 自动启动） | 6.97 s | 15.5 s | **6/6** | **2/2** |
| DENI，不传 `SetEsiFiles` + 自动启动 | 5.29 s | 13.8 s | **6/6** | **2/2** |
| DENI，不传 `SetEsiFiles` + `DisableAutoStartup()` | **3.63 s** | **13.4 s** | **6/6** | **2/2** |

注意最后两列：同一条伺服总线，ESI 自动配置只拿到 `4/4` 的 WKC、只武装了 1 个站的 DC；
DENI 拿到 `6/6`、两个站都武装。**DENI 不是「少做点事所以快」，它把 GUI 里配好的映射原样带过来了。**

### 6.2 同一个进程里反复连（断开 → 再连）

| 写法 | 第 1 次 Build | 第 2/3 次 Build | 每次到 PDO |
|---|---|---|---|
| ESI 自动配置 | 7.72 s | 1.07 s / 1.06 s | 3.1 s |
| DENI + `DisableAutoStartup` | 3.74 s | **0.51 s / 0.51 s** | 4.0–4.7 s |
| DENI + 自动启动 | 5.29 s | 1.19 s | 4.8 s |

读法：

- **固定成本只付一次**：5.7 s 原生初始化只在进程内第一次发生，之后 `new DarraEtherCAT()` 是 0 ms。
- 重连时 DENI 的 Build 只有 ESI 的一半（0.5 s vs 1.07 s）；
  但 DENI 到 OP 的**状态迁移**多花 1–1.5 s —— 它在做 DC/映射，ESI 那条是少做了事。
- 所以「连接要几秒」取决于你怎么用：
  - 进程常驻、断线重连：**DENI 约 4 s，ESI 约 3 s 但映射/DC 不全**；
  - 每次起新进程连一次：**DENI 11–13 s，ESI 15–16 s**，其中 5.7 s 是原生库初始化，躲不掉。

### 6.3 网卡枚举不是瓶颈

`DarraEtherCAT.GetNetworkInfo(needSlavesNum: false)` 第一次调用 5.76 s（含上面那 5.7 s 初始化），
第二次 `needSlavesNum: true` 只要 0.55 s（3 张已绑定网卡，2 张各 2 从站）。
**不要把 5.7 s 记到「扫描网卡慢」头上。**

---

## 7. 常见坑

| 现象 | 真因 | 正确做法 |
|---|---|---|
| 用 DENI 还是很慢 | `SetENI` 之后又调了 `SetNetwork`，退回 C# 自解析慢路径 | 只 `SetENI`，网口交给 DENI |
| 用 DENI 还是慢 1.2 s | 顺手传了 `SetEsiFiles` | DENI 路径不要传 |
| 换机器后 DENI 连不上 / 变慢 | DENI 里的网卡名 / MAC 与新机器不一致，退化成逐口全扫 | 在新机器上重新导出一份 DENI |
| 第二次连接卡 20 s 左右 | 上一次没有 `Close()`，驱动在等实例交还 | 所有路径（含异常）都 `finally { master.Close(); }` |
| 重连偶发失败，报 `SetNetwork 打开网卡失败 (LoadConfigJson 返回 -52)` | 上一轮刚断，实例还没交还；实测同进程连到第 3 次可能撞上 | 重连前留 300 ms 以上间隔；失败就把 `result.Message` 报出来，间隔后重试一次 |
| 冷机第一次特别慢 | ESI 索引缓存没建，全量解析 120+ 个文件要多 2.0–2.3 s | 用 DENI 就不受影响 |
| 以为 `GetNetworkInfo` 每次都慢 | 第一次含 5.7 s 原生初始化 | 看第二次的耗时 |

---

## 8. 不要生成的写法

- `SetENI(...)` 之后再 `SetNetwork(...)`
- 用 DENI 还传 `SetEsiFiles(...)`
- 每个操作都 `new DarraEtherCAT()` + `Build()`，进程里反复初始化原生库
- 退出不 `Close()`，或只在正常路径 `Close()`、异常路径漏掉
- `Build().Master` 不检查 `result.Success`
- 自己写选卡逻辑去猜该用哪张网卡（DENI 里已经有）
- 把 5.7 s 的初始化说成「扫描慢」，然后去优化扫描
- 编造没测过的秒数

---

## 出处

- 实测日志：ETH 台架 `192.168.3.120`，2026-11-18，`events.log` 的 `[PROGRESS] ...（完成，耗时 N ms）` 行
- 分阶段实现：`Darra_EtherCAT_ClassLibrary/CSharp/Master/Initialise.cs`
  （DENI 原生加载 `初始化FromNative`、ESI 匹配 `MatchEsiFilesForSlaves`、BIND 重试 `SetNetworkWithBindRetryCore`）
- 配置缓存：`Darra_EtherCAT_ClassLibrary/CSharp/Master/Utils/Xml.cs` 的 `ConfigCacheDirectory` / `TrySaveCache` / `TryLoadCache`
- GUI 导出：`Darra_EtherCAT_Master/导出/导出.cs`（`DENI 配置文件` 导航项）、`Logic/导出/CodeGenerator.cs`、`Logic/导出/EniSerializer.cs`
- 原生 DENI 引擎：`Darra_EtherCAT_Drive/main/core/config/highlevel.c`（`ParseDeniXmlConfig`）、
  `config_common.c`（`ResolveNicByDeniInfo`）
