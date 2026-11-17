---
name: darra-ethercat-realtime
description: >
  调 Darra EtherCAT 实时性能与抖动时使用：隔离核到底有没有拿到、抖动数字怎么读、
  周期怎么定、抖动变大怎么归因、怎么用 SDK 自证。API 名与数字都按仓内 C# SDK
  源码和官网文档核对过，没写在里面的不要编。触发词：实时、硬实时、软实时、抖动、
  jitter、µs、微秒、隔离核、绑核、核隔离、实时核、周期、LoopCycle、DC 周期、
  SMI、超期、过慢帧、丢帧、优先级、实时优化、抖动大、周期不稳、周期不准。
---

# Darra EtherCAT 实时性能与抖动

初始化、进 OP、PDO 映射、SDO、CiA 402 看 `darra-ethercat`。这份只管**实时**：隔离核有没有真拿到、抖动数字怎么读、周期怎么定、抖动变大是谁的问题、怎么拿数据自证。

## 一句话总则

1. **实时是安装器配的，不是你配的。** 隔离核与电源计划由官方安装包完成，代码里不写任何系统调优；SDK 的 `EnsureRtIsolation` 是**只读校验**，不弹权限、不改系统。
2. **「已配置隔离」不等于「本会话跑在隔离核上」。** 两个状态分开看，判据见第 2 节。
3. **1.2 µs 平均 / 4.5 µs 最大是「PDO 帧发送抖动」**，不是业务逻辑抖动，也不是任何机器都能拿到。前提写在数字旁边，见第 3 节。
4. **周期由 `LoopCycle` 决定，单位纳秒**；文档推荐 125 µs 起步，实时通道下限 31 µs；设小了先实测，不要凭感觉。
5. **周期回调里只读写 PDO。** SDO、Sleep、文件、界面刷新一律不许进 `ProcessDataCyclicSync`。

## 1. 实时是怎么实现的（用户视角）

装一次官方安装包，实时环境就配好了，**不需要自己改内核、不需要跑优化脚本**：

| 谁做的 | 做了什么 | 用户要做什么 |
|---|---|---|
| 安装包 | 预留实时核（写系统实时核预留设置，重启后生效） | 装完按提示重启 |
| 安装包 | 切电源计划到「卓越性能」，没有就「高性能」；锁 CPU 100%、关 C-State / 核心停泊 / PCIe ASPM / USB 选择性挂起 | 无 |
| 安装包 | 写引导时钟参数（`disabledynamictick` / `useplatformclock` 等），重启后生效 | 无 |
| SDK | PDO 线程启动时自己绑到预留实时核，并把线程优先级提到实时段 | 无（要状态就查，见第 2 节） |

预留几个核由安装时的 **RT 主站数**决定，`--rt-masters 1..4`，默认 1，**一个主站一个核**，取最高端的连续逻辑处理器，且必须给 Windows 留至少 2 个：

```powershell
.\Darra-EtherCAT-Setup.exe --silent --install --rt-masters 2
```

`--rt-masters` 只收 1 到 4 的整数。缺值、不是整数、超出范围，安装器直接失败（退出码 1639），**不会兜底成 1**。

注意三件事：

- `--no-rt-optimize` 会跳过本次实时优化，**不会有这次核预留**（除非机器之前已经配过）。除非你明确知道自己在做什么，不要带这个开关。
- 预留单位是**逻辑处理器**。开了超线程时，一个预留核可能和别的负载共享物理核 —— 这是安装器按逻辑处理器计数带来的，不是 bug，但高要求场合值得知道。
- 安装包**不动网卡高级属性 / 中断亲和性**（拿不到已确认的网卡身份时保留现值）。所以「网卡中断跑到别的核」不是安装器留下的坑，是需要现场自己看的情况。

代码侧默认不用做任何事。想确认或想显式触发，用 `EnsureSoftRealtime`：

```csharp
var st = DarraEtherCAT.EnsureSoftRealtime(master);   // 默认线程级：只动 PDO 线程，不改进程优先级类
if (st.Mode != SoftRealtimeMode.Active && st.Mode != SoftRealtimeMode.KernelOffload)
    Console.WriteLine($"软实时未生效: {st.Mode} / {st.Reason}");
```

`useProcessRealtime: true` 会把**整个进程**设成 REALTIME 优先级类，影响宿主所有线程（UI、GC 全在内），侵入性大。只有确实需要时才用。

## 2. 怎么看当前实时状态

先分清四个问题，SDK 分别回答：

| 你想知道 | 用哪个 | 判据 |
|---|---|---|
| 这台机器配了隔离核吗 | `master.IsolationConfigured`（`bool`） | `true` = 系统实时核预留存在。**只说明配置在，不说明本会话用上了** |
| 本会话真的进了硬实时吗 | `master.HardRealtimeActive`（`bool`） | `true` = 内核 DISPATCH 周期证据存在 |
| 周期在跑但没进硬实时？ | `master.SoftRealtimeActive`（`bool`） | `true` = 周期在跑，但没有内核 DISPATCH |
| 实际绑到哪个核 | `master.PinCore`（`int`）/ `SoftRealtimeStatus.PdoCore`（`int`） | `-1` = 未知或没绑上；`>= 0` 是真核号 |

要一次拿全，读 `master.IsolationStatus`（返回 `RtIsolationStatus`）：

```csharp
var iso = master.IsolationStatus;
Console.WriteLine($"隔离配置={iso.IsolationConfigured} 硬实时={iso.HardRealtimeActive} " +
                  $"软实时={iso.SoftRealtimeActive} 绑核={iso.PinCore}");
if (!string.IsNullOrEmpty(iso.AlarmMessage))
    Console.WriteLine("报警: " + iso.AlarmMessage);   // 「隔离已配置但本会话未进入内核 DISPATCH」
```

`RtIsolationStatus` 还有：`TotalCores` / `RtCoreCount` / `RtCoreStart` / `RtCoreEnd` / `ReservedMask` / `IsolatedCount` / `EvidenceSource` / `LegacyHint`。

进程级软实时状态是静态属性，四态：

```csharp
var s = DarraEtherCAT.SoftRealtimeStatus;   // SoftRealtimeStatus
// s.Mode: Unsupported / Inactive / Active / KernelOffload
// s.Supported            本机是否具备条件（Windows + 预留核有效 + 能提权）
// s.ReservedCoreCount    预留核数量
// s.PdoCore              PDO 线程绑到哪个核，-1 = 没绑上
// s.PdoThreadId          被提升的 PDO 线程号，0 = 未知
// s.PdoBasePriority      PDO 线程有效优先级，0 = 未知
// s.ThreadPriorityApplied 优先级是否已提升并通过回读校验
// s.Reason               中文原因，可直接展示（恒非空）
```

**读法**：`Mode == KernelOffload` 说明周期由内核线程承载，SDK 不改任何进程状态，这是最好的一档；`Mode == Active` 说明用户态实时段已生效；`Unsupported` / `Inactive` 就去看 `Reason`。

两个坑：

- `master.IsolationStatus` 是**查询即校验**：隔离配了但本会话没进硬实时时，第一次查会记一条 Error 报警（只记一次）。这是设计如此，不要当成崩溃。
- `EnsureRtIsolation()` 只回答「隔离配置存在吗」，不回答「本会话跑在隔离核上」。文档里明确写了这句。

## 3. 抖动指标口径（1.2 µs / 4.5 µs 到底是什么）

对外口径是 **PDO 帧发送抖动**：平均 **1.2 µs** / 最大 **4.5 µs**。

**它的前提，一条都不能省：**

- 平台是 **Windows + DarraRT 实时通道**（不是用户态软收发）。
- **实时核隔离已生效**，`IsolationConfigured == true`。
- **系统已完成优化**（官网的说法是「全部优化后」，基线两步 = BIOS 电源管理 + 系统电源计划）。
- 数字是「量级」，官网原话带一句 **「以现场实测为准」**。

所以：**不要承诺「任何机器都能 1 µs」**，也不要用这个数字评估一台没配隔离核的机器。

官网给的优化前后对照（同一页面，口径一致）：

| 指标 | 未优化 | 硬件层优化 | 全部优化 |
|---|---|---|---|
| 平均抖动 | 5~30 µs | 3~10 µs | 1~5 µs |
| 峰值抖动 | 100~300 µs | 5~50 µs | < 10 µs |
| 干净最大抖动 | 10~50 µs | 3~10 µs | 1~5 µs |
| 应用抖动 | < 50 µs | < 30 µs | < 20 µs |
| SMI 次数/秒 | 10~300 | 0~5 | 0~2 |

两个必须讲清的区别：

- **帧发送抖动 ≠ 应用抖动。** 前者是帧在总线上的发送时序（SDK 能直接读），后者是 PDO 数据到你程序里的时序偏差（SDK 没有直接属性，得自己量）。「总线抖动低、应用抖动高」= 你自己进程调度的问题。
- **Linux RT 的 0.8 µs / 3.5 µs 是文档口径，Linux SDK 与驱动未发布。** 不要写成已发布能力。

驱动保证的是 **PDO 帧在总线上的发送时序和 DC 同步质量，不承诺业务逻辑的硬实时**。

## 4. 周期的含义

```csharp
master.Config.LoopCycle = 1_000_000;   // 1 ms，单位纳秒
```

| 项 | 值 |
|---|---|
| 单位 | 纳秒（`uint`） |
| 默认 | 1,000,000 (1 ms) |
| 文档推荐范围 | 125,000 ~ 4,000,000（125 µs ~ 4 ms） |
| 实时通道下限 | 31,000 ns（31 µs，文档口径） |
| 低于推荐值时 | 抖动通常明显变大，先实测 |
| 托管层是否钳值 | **不钳**，配置值原样下发；设小于 125 µs 会记一条警告 |

**周期越短，对硬件要求越高**：同样的抖动绝对值，在 125 µs 周期里占的比例是 1 ms 周期的 8 倍。所以「1 ms 能跑」不等于「125 µs 能跑」，要按目标周期实测。

**`LoopCycle` 和 DC 周期是两个值，不可互换：**

- `LoopCycle` = PDO 交换周期。
- `master.DcCycle` = DC 时基（RT 帧周期）。
- 从站侧用 `ConfigureDC(sync0CycleNs, sync1CycleNs, shiftNs)`。

DENI 加载契约要求：DC 使能时，从站 SYNC0 周期非 0 **且与主站 DC 周期一致**，否则配置直接拒。所以常规做法是让 DC 周期与 `LoopCycle` 对齐；要偏离，先让配置校验过，再实测，不要凭猜。

`ConfigureDC` 的 `shiftNs`：`null` = 未指定（按 ESI 声明 → 默认 70% 相位解析），`0` = 字面 0 相位，**不是「没写」**。负值合法。

## 5. 抖动变大的常见原因（每条给判据）

| 可能原因 | 判据（能从 SDK 读到的） | 怎么处理 |
|---|---|---|
| **隔离核没配** | `master.IsolationConfigured == false`；日志里有一条「未检测到 RT 核隔离」Warning | 用官方安装器重装，**不要**自己改系统；装的时候别带 `--no-rt-optimize` |
| **配了隔离但本会话没进去** | `IsolationConfigured == true` 且 `HardRealtimeActive == false` 且周期已在跑；`RtAlarmMessage` 有中文报警 | 这是要报的问题，不是「调一调就好」。看 `AlarmMessage` 里的 mask / core / jitter 字段 |
| **PDO 线程没绑上预留核** | `SoftRealtimeStatus.PdoCore == -1`，或 `ThreadPriorityApplied == false`；`master.PinCore == -1` | 看 `SoftRealtimeStatus.Reason`；确认安装器确实预留了核（`ReservedCoreCount > 0`） |
| **预留核被别的实时任务占了** | 平均抖动整体偏高，`RtPreemptCount` 持续增长 | 同一台机器上不要跑第二个吃实时核的程序；一个核只给一个主站 |
| **电源计划被改回去了** | SDK **不报**电源计划。只能现场核对：`powercfg /getactivescheme` 应显示「卓越性能」或「高性能」 | 改回性能计划；安装器会配，但用户/组策略可能改掉 |
| **网卡中断落到了别的核** | `RtPreemptCount` / `BigGapUnknownCount` 增长，`RtPreemptPeakNs` 偏大；`LateFrameRate` 偏高 | 现场调网卡中断亲和性；安装器不动这一项 |
| **SMI（主板固件周期性打断 CPU）** | `BusMaxJitterUs` 明显大于 `BusCleanMaxJitterUs`；`SmiCount` 持续增长，`SmiPeakUs` 大 | 软件层消不掉，只能 BIOS 抑制（关 C-State / 锁频 / 关 USB Legacy 等）。`SmiMsrAvailable == 0` 时归因不了，看 `BigGapUnknownCount` |
| **超线程共享物理核** | 预留单位是逻辑处理器（安装器按逻辑处理器计数），开 HT 时预留核可能与人共享物理核 | 高要求场合关 HT；这一条官网现行文档未列为抖动原因，属可核对事实 |
| **其它实时任务 / 系统负载冲突** | 平均和峰值都高；`RtPreemptCount` 增长；`BusLoadPercent` 偏高 | 减负载、错开实时任务；先看是不是自己业务线程在抢 |

注意口径差异，别混用：

- `KtimerWakeOverrunCount` 是**定时器唤醒超期次数**，不是「丢了多少个周期」。
- `LateFrameRate` 是**过慢帧率**（帧到了但索引已过窗口，内核丢弃），健康度参考，不计入丢包率。
- `PacketLossRate` 是**发出 vs 接收**的丢包率，过慢帧不计入。
- `CyclicLostFrameCount` 是**累计丢帧次数**（ETG.1510 的权威值），不是百分比。

## 6. 怎么自证（跑一段时间的周期统计）

判据三件套：**平均值 / 最大值 / 超期次数**。再加一个抖动分布，能直接看出是常态偏慢还是偶发尖峰。

在 **PDO 已经在跑（进 OP）之后**，用独立线程采样，**不要**把这段放进 `ProcessDataCyclicSync`：

```csharp
using System;
using System.Diagnostics;
using System.Threading;
using DarraEtherCAT_Master;

static ulong Delta(ulong now, ulong prev) => now >= prev ? now - prev : now;
static uint  Delta(uint  now, uint  prev) => now >= prev ? now - prev : now;

static void SampleRealtime(DarraEtherCAT master, int seconds = 30)
{
    var diag = master.Diagnostics;
    uint setNs = master.Config.LoopCycle;

    var sw = Stopwatch.StartNew();
    var prev = diag.GetSnapshot();
    if (!prev.HasJitterInstrumentation)
    {
        Console.WriteLine("驱动未提供抖动统计（版本过旧或没走实时通道），先换官方安装包");
        return;
    }

    double maxSeenUs = 0;
    ulong cycles = 0, preempt = 0;
    uint overrun = 0;
    var hist = new ulong[7];
    double lastT = 0;

    while (sw.Elapsed.TotalSeconds < seconds)
    {
        Thread.Sleep(200);
        var s = diag.GetSnapshot();

        cycles  += Delta(s.CycleCount,             prev.CycleCount);
        preempt += Delta(s.RtPreemptCount,         prev.RtPreemptCount);
        overrun += Delta(s.KtimerWakeOverrunCount, prev.KtimerWakeOverrunCount);
        for (int i = 0; i < 7; i++)
            hist[i] += Delta(s.JitterHistogramBins[i], prev.JitterHistogramBins[i]);

        if (s.BusMaxJitterUs > maxSeenUs) maxSeenUs = s.BusMaxJitterUs;
        prev = s;
        lastT = sw.Elapsed.TotalSeconds;
    }

    var last = diag.GetSnapshot();
    double expectHz = 1_000_000_000.0 / Math.Max(1u, setNs);

    Console.WriteLine($"设定周期        : {setNs / 1000.0:F1} µs   实测周期 {last.CycleTimeUs} µs");
    Console.WriteLine($"实测频率        : {cycles / lastT:F1} Hz   期望 {expectHz:F1} Hz");
    Console.WriteLine($"平均抖动        : {last.BusAvgJitterUs:F2} µs");
    Console.WriteLine($"最大抖动(含SMI) : {maxSeenUs:F2} µs");
    Console.WriteLine($"干净最大(排SMI) : {diag.BusCleanMaxJitterUs:F2} µs");
    Console.WriteLine($"SMI             : {last.SmiCount} 次, 峰值 {last.SmiPeakUs:F2} µs");
    Console.WriteLine($"RT 被踢         : {preempt} 次, 峰值 {last.RtPreemptPeakNs} ns");
    Console.WriteLine($"唤醒超期        : {overrun} 次");
    Console.WriteLine($"累计丢帧        : {diag.CyclicLostFrameCount}");
    Console.WriteLine($"过慢帧率/丢包率 : {last.LateFrameRate:P2} / {last.PacketLossRate:P2}");
    Console.WriteLine("抖动分布 <1|1-2|2-5|5-10|10-50|50-100|>=100 µs:");
    Console.WriteLine("  " + string.Join(" | ", hist));
}
```

读结果的方式：

- **平均值看 `BusAvgJitterUs`**，这是和对外口径对得上的那个数。
- **最大值看 `BusMaxJitterUs`**（含 SMI）与 `BusCleanMaxJitterUs`（排除 SMI）。两者差得越大，SMI 嫌疑越大。
- **`HasJitterInstrumentation == false`** = 驱动没提供抖动统计，不要读成「抖动 0」。注意它要求 `JitterInstrumentVersion != 0` **且** `JitterTotalSamples > 0` —— 刚进 OP 的头一两秒可能还没攒到样本，稍等一下再采。
- **`CycleState`**：`CycleCount` / `CycleTimeSpan` / `BusCycleHz` 是 0 时它才是判据 —— `NotStarted`（没启动）/ `StartedNoAdvance`（启动但卡住）/ `Advancing`（正常推进）。**不允许只回一个 0 糊三种含义。**
- **实测频率对不上期望** = 周期没跑到，不是抖动问题。
- **直方图**：`>=100 µs` 桶有稳定增量 = 偶发尖峰（SMI / 抢占）；`1-2 µs` 桶占绝大多数 = 常态正常。

要一次性拿全部字段用 `master.Diagnostics.GetSnapshot()`；单读某几个属性会每次各查一遍，数值可能不同拍。采样周期 200 ms 即可，不必更快。

## 7. 不要做的事

- **不要在 `ProcessDataCyclicSync` 里做 SDO / Sleep / 文件 / 界面刷新 / 等锁。** 这个回调在实时线程里直接执行，阻塞它 = 阻塞周期。它也不在 UI 线程上，WinForms 用 `Invoke`/`BeginInvoke`，WPF 用 `Dispatcher`，但更好的做法是回调里只存数据、另开线程处理。
- **不要在 OP 里改 PDO 映射。** 会被拒。映射属于进 OP 之前的配置。
- **不要用非实时线程驱动决定时序的业务逻辑再指望它准点。** UI 线程、普通线程池线程都不保证调度；要确定性就把时序逻辑放在周期路径上，只做轻量计算。
- **不要自己写系统调优代码**（改电源计划、改引导参数、绑网卡、提权改注册表）。这些是安装器的职责；SDK 只提供只读校验。
- **不要自己包一层重试去「修」实时问题**。抖动大是物理/配置问题，重试修不了，只会掩盖。
- **不要用 `--no-rt-optimize` 装完再抱怨抖动大。**
- **不要把 `KtimerWakeOverrunCount` 当成「丢了多少帧」报给客户。**

## 8. 边界：这不是实时问题

先排除这几种，再谈抖动：

| 现象 | 实际是 | 看哪 |
|---|---|---|
| `CycleState == NotStarted` | 周期根本没跑 | 先启动 PDO 运行时 |
| 周期设成 0 或极小值 | 配置问题 | 回到 125 µs 起步重测 |
| `IsolationConfigured == false` | 安装/配置问题 | 重装走官方安装器 |
| WKC 不满、从站掉出 OP | 总线/从站问题 | `master.Diagnostics.WKC`（快照里是 `WkcActual` / `WkcExpected`）、从站状态，不是抖动 |
| `PacketLossRate` 高 | 链路/网卡/线缆问题 | 屏蔽网线、避开强电、网卡节能设置 |
| `LateFrameRate` 高 | 网卡拥塞或 DPC 抖动 | 网卡侧，不是 CPU 侧 |
| 总线抖动正常但业务动作不准 | **应用层调度** | 你自己的线程模型 |
| `SmiMsrAvailable == 0` 且 `BigGapUnknownCount` 增长 | 平台不支持 SMI 计数（AMD / 虚机常见），大间隔无法归因 | 只能按 BIOS 优化清单逐项排查，不要指望 SDK 给出归因 |

官方给的三条判读口诀（照抄口径）：

- **平均抖动低（< 10 µs）、峰值高（> 100 µs）** → 硬件层干扰（SMI），做 BIOS 优化。
- **平均和峰值都高** → 系统负载过重，做应用层优化。
- **总线抖动低、应用抖动高** → 用户进程调度问题，提升进程优先级。

还有一条硬边界：**需要业务逻辑层的硬实时（微秒级插补、确定性控制周期），标准 Windows 用户态做不到。** 帧发送准时 ≠ 你的业务代码准时。这种情况要上内核硬实时方案，不要靠调优先级硬凑。

## 出处

**实时状态 API**（`A:\c\Darra\Darra_EtherCAT_Master\Darra_EtherCAT_ClassLibrary\CSharp\Master\`）

- `IsolationStatus` / `HardRealtimeActive` / `SoftRealtimeActive` / `IsolationConfigured` / `PinCore` / `RtAlarmMessage` — `Utils\RtIsolation.cs:639-666`
- `RtIsolationStatus` 结构与字段 — `Utils\RtIsolation.cs:602-636`
- `EnsureRtIsolation`（只读）— `Utils\RtIsolation.cs:539-550`
- `DarraEtherCAT.SoftRealtimeStatus` / `EnableSoftRealtime` / `DisableSoftRealtime` / `EnsureSoftRealtime` / `ApplySoftRealtime` — `SoftRealtimeApi.cs:29,36,42,50,61,71`
- `SoftRealtimeStatus`（`Mode` / `Supported` / `PdoCore` / `PdoThreadId` / `PdoBasePriority` / `ThreadPriorityApplied` / `ReservedCoreCount` / `Reason`）— `Utils\SoftRealtime.cs:57-94`
- `SoftRealtimeMode` 四态 — `Utils\SoftRealtime.cs:34-50`

**诊断与计数**（`Master\MasterDiagnosticsInfo.cs`；行号指向成员声明或文档注释起始行）

- `CycleRunState` 三态（`NotStarted` / `StartedNoAdvance` / `Advancing`）— `:19-31`；`CycleState` — `:258-284`
- `CycleCount` — `:2089`；`CycleTimeSpan` — `:1762`；`BusCycleHz` — `:1833`
- `BusMaxJitterUs` — `:1922`；`BusAvgJitterUs` — `:1931`；`BusCleanMaxJitterUs`（排除 SMI）— `:1940`
- `SmiCount` — `:1950`；`SmiPeakUs` — `:1961`；`SmiMsrAvailable` — `:2065`
- `RtPreemptCount` — `:2034`；`RtPreemptPeakNs` — `:2045`；`BigGapUnknownCount` — `:2055`
- `WdkRtCpuCore` — `:2078`
- `JitterInstrumentVersion` — `:2161`；`JitterHistogramBins`（7 桶 `<1,1-2,2-5,5-10,10-50,50-100,>=100 µs`）— `:2166`；`JitterTotalSamples` — `:2185`；`JitterMinUs` — `:2190`
- `KtimerWakeNormalCount` — `:2210`；`KtimerWakeOverrunCount` — `:2215`；`DispatchCycleMaxJitterUs` — `:2220`；`DrainCycleMaxJitterUs` — `:2225`
- `PacketLossRate` — `:973`；`LateFrameRate` — `:981`；`CyclicLostFrameCount` — `:988`
- `WKC` — `:2378`；`BusLoadPercent` — `:2361`
- `DiagnosticsSnapshot` 字段表 — `:3326-3410`；`HasJitterInstrumentation` / `HasCpuBindingData` / `HasWdkDiagnostics` — `:3566-3595`
- `GetSnapshot()` — `:3469`

**配置与事件**

- `MasterConfig.LoopCycle` — `Master\MasterConfig.cs:46`；`DarraEtherCAT.LoopCycle` 与推荐最小值常量 — `Master\Core.cs:1743,1756`
- `DarraEtherCAT.DcCycle`（与 `LoopCycle` 不可互换）— `Master\Core.cs:1844`
- `ConfigureDC(...)` 主站级 — `Master\Slave\DC.cs:2398`；从站级 — `Master\Slave\DC.cs:1102`
- `ProcessDataCyclicSync` 事件 — `Master\Events.cs:1126`；委托「在实时线程中直接执行」— `Master\Events.cs:262-266`
- DC 契约（`DcCycleTime == CycleTime`）— `Master\Utils\Xml.cs:1296-1297`

**数字与口径**

- 「平均 1.2 µs / 最大 4.5 µs」+「以现场实测为准」+ 优化前后对照表 — `云端\ethercat-doc\docs\faq\stability.md`（判定口诀在 :49-53，对照表在 :63-69，结论在 :136）
- 「帧发送抖动 平均 1.2μs / 最大 4.5μs」+「推荐 125µs 起步」— `docs\quick-start\preparation.md:34-35`
- 「实际可达周期取决于 CPU、隔离配置、网卡与从站」— `docs\ethercat\overview.md:114`
- Linux RT 0.8 / 3.5 µs 为「文档口径，未发布」— `static\ai\performance-benchmarks.txt:11-20`、`docs\ethercat\prerequisites.md:41`
- 「驱动保证的是 PDO 帧在总线上的发送时序和 DC 同步质量，不承诺业务逻辑的硬实时」— `static\ai\darraRT-driver.txt:67`
- `LoopCycle` 默认 1 ms、推荐 125 µs~4 ms、31 µs 下限 — `docs\sdk\csharp\master\config.md:73-75,804`；Python/Java 页同口径

**安装器**

- `--rt-masters` / `--no-rt-optimize` 与退出码 1639 — `云端\ethercat-doc\docs\downloads.md:47-71`
- 核预留规则（N 主站 = 最高 N 个逻辑处理器，给 Windows 留 2 核）— `安装包\Services\RtOptimizationCore.cs:1201-1241`
- 电源计划切「卓越性能」否则「高性能」— `安装包\Services\RtOptimizationCore.cs:290-302`
- 电源细项（CPU 100% / 禁 C-State / 核心停泊 / PCIe ASPM / USB 选择性挂起）— `安装包\Services\RtOptimizationCore.cs:361-370`
- 引导时钟四项（`disabledynamictick` / `useplatformclock` / `useplatformtick` / `tscsyncpolicy`）— `Darra_发布专用仓库\Darra_ETH_Publish\docs\INSTALL_USER.md:16`
- 不动网卡高级属性 / 中断亲和性 — `安装包\Services\RtOptimizationCore.cs:232-234`

## 查不到、所以没写的项

1. **1.2 / 4.5 µs 的测试机细节没有公布。** 官网没有给 CPU 型号、从站数量、实测时用的周期、采样时长，也没定义「最大」是哪个统计口径。所以本文只写文档确实给出的前提（Windows + DarraRT + 隔离生效 + 全部优化 + 以现场实测为准），不补细节、不举例成「125 µs 下测得」。
2. **SDK 没有「应用抖动」属性。** 只有总线 / 帧发送抖动。「PDO 到用户程序」的时序偏差得自己在周期回调里打时间戳量。
3. **没有公开的 `MissedCycleCount` / `OverrunCycleCount` / `LateCycleCount` 这类「超了几个周期」计数器。** 语义接近的是 `KtimerWakeOverrunCount`（唤醒超期）、`RtPreemptCount`（RT 被踢）、`LateFrameRate`（过慢帧率），但口径都不同，不能互相替代。
4. **电源计划没有 SDK 只读接口。** 只能现场 `powercfg /getactivescheme` 核对。
5. **超线程未列入官网现行抖动原因清单**（只出现在归档页与内部发布文档）。本文只写可核对的事实：预留单位是逻辑处理器。
6. **`SoftRealtimeApi.cs:48` 与 `Utils/SoftRealtime.cs:17-18` 关于「默认是否自动启用」的注释互相矛盾**（一处说默认不启用，一处说默认 auto）。所以本文的写法是：不靠猜，调 `EnsureSoftRealtime` 后读 `Mode`，或以 `SoftRealtimeStatus.Mode` 实际值为准。
7. **官网未提供「安装后如何验证实时优化生效」的专门页面。** 现有手段是：安装器完成页的回执摘要 + `master.IsolationStatus` 只读校验 + 第 6 节的实测采样。
