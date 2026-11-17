---
name: darra-ethercat-troubleshooting
description: >
  Darra EtherCAT 现场排障手册。覆盖：扫不到从站、扫描返回负数、进不了 OP、
  AL 状态码怎么读、运行中掉站、热插拔恢复、周期抖动大、升级重装的 3010、
  授权与评估期。每个问题都按「判据 → 怎么查 → 怎么修」写，错误码、AL 码、
  诊断项都给了仓内出处。不编码：查不到的写「以实际 SDK 返回为准」。
  触发词：排障、故障、扫不到从站、扫不到设备、扫描返回负数、-1、-2、-3、
  -1201、-1202、-1203、-1204、-1205、-1206、空口、没量到、进不了 OP、
  卡在 PreOp、卡在 SafeOp、AL Status、AL Status Code、0x0134、0x002D、
  0x001B、SM 看门狗、PDO 未映射、掉站、掉线、WKC、expected_wkc、actual_wkc、
  丢帧、热插拔、插回、恢复、抖动大、周期跑不满、3010、5023、授权过期、
  评估期、2 小时。
---

# Darra EtherCAT 现场排障

现场排障只做两件事：**先分清是哪一层出问题，再按那一层修**。
每节都是三段：**判据**（看到什么就成立）→ **怎么查**（读哪个字段、发哪个调用）→ **怎么修**（动哪里）。

两条口径先记住：

1. **不编码。** 本文每个错误码、AL 码、诊断项都能在仓内找到出处（附录 A）。查不到的项写在附录 B，不要凭印象补一个。
2. **「没量到」不是「0 个从站」。** 任何计数字段都要配结论字段一起读；`null` / `NotMeasured` 不能写成 0。

> 文中 `路径:行` 一律相对仓库根 `Darra_EtherCAT_Master\`。

---

## 0. 先分清是哪一层

| 现象 | 先看什么 | 本文对应 |
|---|---|---|
| 启动主站 / 绑定网卡就失败 | 错误文本里的数字：`5023` / `1168` / `21` | §9 / §1 |
| 主站能启动，扫不到从站 | `ScanOutcome` / `NicScanState` 的结论态 | §1 §2 |
| 扫到了，但进不了 OP | 从站停在哪个基态 + AL Status Code | §3 §4 |
| 能进 OP，读写参数失败 | SDO Abort Code | 本文不展开（见 FAQ error-codes） |
| 跑着跑着掉站 | `IsLost` / WKC 缺口 / `PDOFrameLoss` | §5 §6 |
| 通信抖动大或周期跑不满 | 抖动指标 / SMI / RT 抢占计数 | §7 |
| 装不上 / 装完不生效 | 安装器退出码（`3010` 是成功） | §8 |
| 用着用着总线停了 | 授权状态 / 数据门 | §9 |

出处：`云端\ethercat-doc\docs\faq\error-codes.md:13-19`。

---

## 1. 扫不到从站

### 判据

先拿结论，不要拿数字下结论。同一轮扫描有三种表达，看哪个都行，但都要读配套的「结论态」：

| 入口 | 结论字段 | 说明 |
|---|---|---|
| `DarraEtherCAT.QuickScan()` | `NicScanState` | 每口一行，只回答「有没有从站 / 没有的话为什么」 |
| `DarraEtherCAT.ScanSlaves(adapter, secondary, out outcome)` | `ScanOutcome` | 直接透传原生码 |
| `DarraEtherCAT.StandardScan(...)` | `ScanOutcome` | 在 ScanSlaves 之上补齐 `AdapterNotFound` / `EmptyBus` / `Aborted` / `Failed` |

- `QuickScan` 的 `SlaveCount`：`null` = **没量到**；`0` = **实测空口**。两者严格区分，只有 `HasSlaves` / `EmptyBus` 带数字。
- `QuickSlaveCount(adapter)` 返回原生原始码：`>=0` 是站数（0 = 实测空口，正常结论），`<0` 是错误码原值，不压成 0。
- 没有任何网卡 → `QuickScan` 返回**空列表**（不是 null）；枚举或快扫整体失败 → 抛 `InvalidOperationException`，不会伪装成「没有网卡 / 没有从站」。

出处：`Darra_EtherCAT_ClassLibrary\CSharp\Master\Static\Network.cs:2900-2951`、`:2576-2610`、`:3015-3058`；`CSharp\README.md:150-186`。

`NicScanState` 八态：

| 状态 | 含义 | SlaveCount |
|---|---|---|
| `HasSlaves` | 实测有从站 | ≥ 1 |
| `EmptyBus` | 扫过了，这个口确实 0 站 | `0` |
| `OccupiedByMaster` | 本机主站正占用该口，扫描按设计跳过（是事实，不是失败） | `null` |
| `NotMeasured` | 没量到（开卡失败 / 本轮未参与） | `null` |
| `NotScanned` | 本轮 `adapters` 参数没选中该口 | `null` |
| `Unsupported` | 该口不能作主口（非物理有线口） | `null` |
| `Aborted` | 用户调了 `AbortScan()` | `null` |
| `Failed` | 其它原生负码，原值见 `NativeCode` | `null` |

出处：`CSharp\README.md:158-171`。

### 怎么查（五类分流）

一句话：**先看网卡属性，再看扫描结论，两者交叉定位。**

```csharp
// ① 网卡属性：能不能当主口、绑没绑、链路通不通、被谁占
foreach (var nic in DarraEtherCAT.GetNetworkAdapters())
    Console.WriteLine(nic);   // #[i] [已绑]/[未绑] LinkStatus MAC 描述 ← Error

// ② 每口一行：有没有从站、没有的话为什么
foreach (var row in DarraEtherCAT.QuickScan())
    Console.WriteLine($"{row.State,-16} 从站={(row.SlaveCount?.ToString() ?? "未测量")} " +
                      $"原生码={row.NativeCode} {row.Name}");
```

`NetworkAdapterInfo` 的五个字段就是分流依据：`EtherCatCapable` / `BoundProtocol` / `LinkStatus` / `UsedByAnotherInstance` / `OwnerMasterNumber`。`LinkStatus = Unknown` 表示系统没报，**不能当在线**。出处：`Network.cs:1408-1497`。

| 现象 | 对应字段 / 码 |
|---|---|
| 网卡没绑定 | `BoundProtocol = false`，扫描 `-1204`（Win32 1168） |
| 链路不通 | `LinkStatus != Up`，扫描 `-1205` |
| 不是有线物理口 | `EtherCatCapable = false`，或扫描 `-1206` |
| 被别的实例占用 | `UsedByAnotherInstance = true` + `OwnerMasterNumber`，扫描 `-1202`；或被本机主站占用 → `OccupiedByMaster` |
| 从站没上电 / 拓扑断 | 扫到了但数量少于预期；或 `EmptyBus` |
| 真的空口 | `EmptyBus`，且上述失败码一个都没出现 |

### 怎么修

**① 网卡没绑定（1168 / `-1204` `OpenNicNotFound`）**

- 判据：`BoundProtocol = false`，或扫描返回 `-1204`（Win32 1168/2/3）。含义是「驱动网卡池里没有这张卡」。
- 怎么修：确认用的是**官方安装包**并让安装程序完成驱动安装；重新运行安装包走「安装 / 升级」，装完按提示重启；确认选的是实际接线的那张物理网口，不是 Wi-Fi / 虚拟网卡 / 没接线的口。**不要手工拷贝驱动文件、不要手工绑定网卡。**
- 出处：`云端\ethercat-doc\docs\faq\error-codes.md:43-52`；`Network.cs:2939-2940`。

**② 链路不通（`-1205` `OpenLinkDown`）**

- 判据：扫描返回 `-1205`，或 `LinkStatus != Up`。
- 怎么查：网口指示灯、`LinkStatus`、对端设备是否上电。
- 怎么修：插紧 / 换线 / 确认对端上电。线型拓扑中间断开 → 后方从站全部不可达；耦合器断开 → 其分支下游全部不可达。
- 出处：`Network.cs:2941-2942`；`云端\ethercat-doc\docs\faq\hot-connect.md:28-29`。

**③ 从站没上电 / 拓扑不对**

- 判据：`HasSlaves` 但站数少于工程配置的站数；或整条链 `EmptyBus`。
- 怎么查：逐站看指示灯；核对工程里的从站清单与实际接线顺序。
- 怎么修：上电、按顺序接线；确认没有把「耦合器 + 模块」的数量算错。

**④ 被别的进程 / 实例占用（`-1202` `OpenOccupied`）**

- 判据：扫描返回 `-1202`（Win32 170 BUSY）；或 `UsedByAnotherInstance = true`（`OwnerMasterNumber` 指出占用者）。
- 怎么查：同进程里是否还有一个没 `Close()` 的主站实例在占同一张卡。
- 怎么修：先 `master.Close()` 归还网口，再扫描；不要开两个主站抢同一张卡。
- 注意：`OccupiedByMaster` 是「本机主站占用，扫描按设计跳过」，这是**事实不是失败**，也不是 0 站。
- 出处：`Network.cs:2935-2936`、`:1141-1222`、`:580-592`。

**⑤ 真的空口（`EmptyBus`）**

- 判据：`ScanOutcome.EmptyBus` / `NicScanState.EmptyBus`，`SlaveCount = 0`，且没有 `-1204` / `-1205` / `-1202`。
- 怎么修：**这是正常结论，不用修。** 不要写成「没量到」，也不要据此换网卡或重装驱动。
- 出处：`CSharp\README.md:163`、`:171`。

**另一个坑：`-3` 不是「没有从站」。** 见 §2。

---

## 2. 扫描返回负数

### 判据

负码分两类：**已归类的固定码** 和 **未归类的原生码**。
`(int)outcome` 恒等于原生码；未归类负码**原样保留**，不压成 `-1`（用 `IsUnknownScanOutcome()` 判定）。出处：`Network.cs:3015-3058`；`C\include\statics\network.h:57-99`。

### 怎么查（逐码表）

| 码 | `ScanOutcome` | 说明 | 下一步查什么 |
|---|---|---|---|
| `-1` | `OpenFailed` | 开网卡失败 / 参数非法 / 用户中断（未归类时保持此值） | 看 `LastScanErrorCode`（原生记录的 Win32 原码）+ 日志；确认网卡名不为空 |
| `-2` | `TopologyXactRefused` | 拓扑写事务被拒，本轮扫描不完整（网卡与从站正常） | 稍后重扫；确认没有并发的重建/收口在跑 |
| `-3` | `ScanBusy`（旧名 `ScanClosing`） | 扫描收口中，上一轮快扫/收口未排空 | **稍候再试**；绝不能显示成「未发现从站」 |
| `-1201` | `OpenAccessDenied` | 驱动安全门拒绝（权限不足，Win32 5） | 管理员权限；重启；核对 Core 与驱动身份；官方安装包重装 |
| `-1202` | `OpenOccupied` | 网口被占用（另一主站实例，Win32 170） | 关掉/`Close()` 另一个实例后重试 |
| `-1203` | `OpenNotReady` | 驱动或网卡未就绪（Win32 21） | 等几秒重试一次；仍失败重启；每次开机都这样 → 查安装完整性、安全软件是否拦截 |
| `-1204` | `OpenNicNotFound` | 驱动网卡池中没有这张卡（Win32 1168/2/3） | 官方安装包重装 + 重启；确认选的是物理接线口 |
| `-1205` | `OpenLinkDown` | 网口链路 down（原生侧实测为真） | 网线 / 对端上电 |
| `-1206` | `OpenBadMedia` | 非有线介质网卡（无线/蓝牙/回环/隧道） | 换物理有线网卡 |
| 其它负码 | `Failed` / 原值保留 | 未归类原生负码 | 显示原始码 + 查日志，不要猜成 `-1` |

出处：`Network.cs:2922-2944`、`:2962-2974`、`:3038-3058`；`network.h:62-117`；`CSharp\README.md:209-218`；`云端\ethercat-doc\docs\faq\error-codes.md:49-62`。

### 怎么修

- **`-3`**：只做「稍候再试」。原生码语义就是收口中，重试即可。**不要**顺手重装驱动。
- **`-2`**：本轮结果不完整，按「重扫」处理，不要当成空口结论。
- **`-1`**：先读 `LastScanError` / `LastScanErrorCode`。注意二者不同：`LastScanErrorCode` 是**开卡失败**时原生记录的 Win32 码，`0` 表示本轮没记录（例如 `-3` / `-2` 的情况），不是另一个扫描结论。出处：`Network.cs:2576-2610`。
- **`-1201..-1206`**：按表里的「下一步」逐项来；不要把所有 `-1` 都编造成「被占用 / 换网口」。
- **未归类负码**：如实显示 `(int)outcome`，附日志。不要压成 `-1`，也不要编一个含义。

> 另一个名字不要混：`HotSwapRebuild()` 的负码是 `-20` / `-21` / `-23` / `-25`（门禁 `-1` / `-6`），和扫描码不是一套。见 §6。

---

## 3. 进不了 OP

### 判据

看两样东西：**从站停在哪个基态** + **AL Status Code**。

```csharp
bool ok = master.SetState(EcState.OP, out string err);
if (!ok) Console.WriteLine(err);   // err 里已点名"停留在哪个状态 + 哪个从站 + AL 码"
```

`err` 由 `DescribeUnreachedSlaveAlDetails` 生成，逐站给「停留在 X 的从站 N，AL=0x....」。`State` 的低 4 位是基态，bit4（`0x10`）是 Error 位；`0x18` 这类复合状态 SDK 有具名成员（`OpFault` 等）。出处：`CSharp\Master\State.cs:683-760`；`Master\Data\Type.cs:28-93`。

### 怎么查（按卡住的基态分流）

| 停在 | 基础态 | 常见 AL | 典型原因 |
|---|---|---|---|
| INIT | `0x01` | `0x0014` / `0x0050` / `0x0051` | 固件 / EEPROM 类 |
| PREOP | `0x02` | `0x0015` / `0x0016` / `0x0017` / `0x0018` / `0x0019` | 邮箱配置、SM 配置、启动参数 |
| SAFEOP | `0x04` | `0x001D` / `0x001E` / `0x0024` / `0x0025` / `0x002D` | PDO 映射、输出/输入配置、DC 未同步 |
| OP | `0x08` | `0x001B` / `0x002D` / `0x0034` | SM 看门狗、DC 同步丢失、周期超时 |

`EcSlaveStatus` 对复合态有直接注释：`InitFault` 通常是 SII/EEPROM 问题、`PreOpFault` 通常是邮箱/SM/启动参数、`SafeOpFault` 通常是 PDO 映射/SyncManager、`OpFault` 通常是 watchdog/DC 同步丢失/cycle 超时。出处：`Master\Data\Type.cs:72-93`。

### 怎么修（四类）

**A. SM 看门狗（AL `0x001B`）**

- 判据：AL = `0x001B`。含义是「PDO 周期过慢或通信中断」。
- 怎么查：
  - `slave.GetWatchdogStatus()` / `GetWatchdogStatusEx()`：寄存器 `0x0440` bit0 = 0 表示看门狗溢出。
  - **但别只看这一位**：部分器件（如 EK1100）在健康、在 OP、计数器不递增、AL 干净时仍返回 bit0 = 0。要用 `Conclusive` 与 `0x0442` 计数器一起判：只有「位说溢出 + 状态已知 + 确实在 OP + 计数器不推进」四条同时成立，才认定证据自相矛盾。`Expired` 语义不变，仍如实反映 bit0。
- 怎么修：
  - 先查周期是否过慢、线缆/供电是否稳定、主站负载是否过高。
  - 调整 `slave.SetWatchdog(ms)` 时注意：分支站安全下限 5000 ms、环上 PDO 站 400 ms，请求被抬升时方法抛 `InvalidOperationException` 并给出实际下发值，**不谎报按请求设置成功**。
- 出处：`CSharp\Master\Slave\Core.cs:1500-1533`（看门狗状态与 Conclusive）、`:1402-1413`（SetWatchdog 与安全下限）；`云端\ethercat-doc\docs\faq\error-codes.md:83`。

**B. DC 未同步（AL `0x002D` "Sync not received"）**

- 判据：AL = `0x002D`，卡在 SAFEOP 等第一拍 SYNC0/SYNC1 超时，从站拒绝进 OP。
  **码名字面是「No sync error」，含义不是「无错」** —— 这是 ETG 的历史命名。
- 怎么查：
  - `slave.Sync0Armed`（`bool?` 三态）：`true` 已武装 / `false` 确知未武装（含无 DC 能力的从站）/ `null` 答不出来。**`null` 不得折成 `false`**。
  - `slave.Diagnostics.DC.IsInSync` / `slave.GetSyncWindowStatus()`。
  - `0x0300` 不是判据。武装 ≠ 整网时钟已收敛。
- 怎么修：
  - DC 站：在 `SetState(OP)` **之前** `ConfigureDC`，周期与 `Config.LoopCycle` 一致或为其整数倍。
  - `sync0CycleNs = 0` 是**卸下 SYNC0 武装（回 FreeRun）**，不是「0 ns 周期」。此时有 PDO 的站会把 `0x1C32:01` / `0x1C33:01` 写回 0，清掉上一会话残留 —— 不清就可能升 SafeOp 报 `0x002D`。
  - FreeRun / SM-Sync 站：确认确实没有残留 DC 意图。
  - 热插拔重武装要重写 `0x09A0` 与 `0x0990`，`0x0990` 必须晚于重新读 `0x0910`，否则起点过期、首拍 SYNC0 不来（这部分主站自己做，你只需知道「重武装失败不是配错了周期」）。
- 出处：`CSharp\README.md:294`、`:325-332`；`云端\ethercat-doc\docs\faq\error-codes.md:88`；`Master\Data\Type.cs:463-466`。

**C. PDO 未映射 / 映射不符（`0x0017` `0x001D` `0x001E` `0x0024` `0x0025`）**

- 判据：AL 码落在上面这一组；或 `slave.Ibytes` / `slave.Obytes` 与实际结构体大小不一致。
- 怎么查：对照 ESI 与设备手册，逐项核 RxPDO / TxPDO 的索引、子索引、数据类型、长度、顺序；核 Startup 参数的写入时机（IP = Init→PreOp，PS = PreOp→SafeOp，SP = SafeOp→PreOp，SO = SafeOp→OP）。
- 怎么修：改配置后重进 OP。**OP 里改 PDO 映射会被拒**（SDO 会返回 `0x08000022`），先回 PreOp。
- 出处：`云端\ethercat-doc\docs\faq\error-codes.md:81-87`、`:100-103`、`:139`。

**D. 从站不支持该模式 / 周期过小**

- `0x0027` FreerunNotSupported / `0x0028` SyncNotSupported → 换同步模式，别硬开 DC。
- `0x002E` CycleTimeTooSmall → 主站周期小于从站支持的最小周期，把 `Config.LoopCycle` 调大。
- `0x001F` WatchdogCfgInvalid → 这**可能不是硬错误**：SDK 对 `0x001F` 有「demote-grace」等待，若该站当前已干净到达 SAFEOP 且无 Error，只是还差最后一步，会继续等一会儿再判失败。只有「掉站（base state == 0）」或「Error 位 + AL 码既非 0 也非 `0x001F`」才立即判硬错误。
- 出处：`Master\Data\Type.cs:449`、`:457-459`、`:467-468`；`Master\State.cs:260-357`。

> **不要在外面再包一层状态切换重试。** 切换失败就如实报 `err`，不要把期望值改小去凑成功。

---

## 4. AL 状态码怎么看

### 判据

ESC 里是两个不同的寄存器：

| 寄存器 | 是什么 | 怎么读 |
|---|---|---|
| `0x0130` AL Status | 低 4 位 = 基态（`1` Init / `2` PreOp / `4` SafeOp / `8` OP），bit4（`0x10`）= Error 位 | `slave.State` / `slave.Status` |
| `0x0134` AL Status Code | 16 位错误码，**只在 Error 位置位时有意义** | `slave.ErrorCode`（完整码）/ `slave.AlStatusCode`（镜像，有损） |

出处：`C\include\data\structures.h:888-889`；`Master\Data\Type.cs:37-54`；`Master\Slave\Core.cs:3203-3212`。

### 怎么查

**两种读法，取源不同，不要混：**

| 属性 | 取源 | 特点 |
|---|---|---|
| `slave.ErrorCode` | native 从站结构体 `ALstatuscode` 字段 | **完整 16 位实读码**，要真码用这个 |
| `slave.AlStatusCode` / `AlStatusMirror` | AL 镜像高字节 | 只有低 8 位，**≥ `0x0100` 会被截断**；主站不在 OP 时返回 `Unknown`，不把冻结样本冒充当前值 |

- 失败日志里的实读链是 native `D_1699`：强制发一帧 FPRD 读 `0x0134`，绕开缓存与镜像 —— 这是分辨「设备真报错」与「主站没让它升 OP」的唯一可信来源。
- `0xFFFF` = 原生 `DX_AL_UNKNOWN`（本轮 FPRD 无应答），**只是读不到**，不是从站真报了 `0xFFFF`。
- 基础态 `0x00` = 无有效状态上报（从站无应答），**不是** AL=0x0000（无错误）。
- 在 OP 时 `AlStatusMirror`/`AlStatusCode` 无 Error 位 + 样本新鲜 = 确证无错误，返回 `NoError`；Error 位置位但镜像高字节为 0 时返回 `Unknown` —— SDK 不伪造 AL 码。

出处：`Master\Slave\Core.cs:169-192`、`:3197-3265`、`:1590-1630`；`Master\State.cs:762-778`。

**读到了码之后先分类：**

`ALErrorClassifier.Classify(ushort)` → `None` / `Transient` / `Configuration` / `Hardware` / `Unknown`。
唯一权威是 native 的逐码表（不是按高位段分桶 —— 同一个段里 `0x0024` 是配置错误、`0x002C` 是临时错误，按段归并必然判错）。

| 分类 | 处置 |
|---|---|
| `Transient` | 可重试状态转换，常自动恢复 |
| `Configuration` | PDO 映射 / SM / Startup 参数需重配 |
| `Hardware` | 从站硬件 / 线缆 / 电源 / 邮箱 / EEPROM |
| `Unknown` | 厂商自定义码或未收录码，查设备手册 |

出处：`Master\Data\Type.cs:520-544`；`Master\State.cs:4945-4963`；`C\include\master\diagnostics_ext.h:39-65`。

### 怎么修（常见码对照）

| AL 码 | 含义 | 常见原因与处理 |
|---|---|---|
| `0x0003` | 无效设备设置 | 耦合器没插模块，或模块配置与实际不一致 |
| `0x0017` | 无效 SM 配置 | SM 大小/方向与从站不匹配，查 PDO 与 ESI |
| `0x001A` | 同步错误 | 检查 SYNC0 周期、DC 配置、主站周期 |
| `0x001B` | SM 看门狗超时 | 见 §3-A |
| `0x001D` | 无效输出配置 | 查 RxPDO 映射 |
| `0x001E` | 无效输入配置 | 查 TxPDO 映射 |
| `0x001F` | 看门狗配置无效 | 可能是合法 demote 恢复等待，见 §3-D |
| `0x0024` / `0x0025` | 无效输入/输出映射 | 索引、子索引、长度、顺序逐项对照 ESI |
| `0x002D` | 同步未收到 | 见 §3-B |
| `0x002E` | 周期时间过小 | 调大主站周期 |
| `0x0034` | DC 同步超时 | DC 启动时间或参考时钟配置不合理 |
| `0x0043` | 邮箱 CoE 错误 | 查邮箱配置、从站状态、通信质量 |
| `0x0051` | EEPROM 错误 | 重新上电；持续出现联系厂商 |
| `0x0060` | 从站重启 | 查供电与看门狗设置 |

`0x8000` 以上是厂商自定义码，含义以设备手册为准。**查不到确切含义就写「以设备手册为准」，不要编。**

出处：`云端\ethercat-doc\docs\faq\error-codes.md:78-94`；`Master\Data\Type.cs:420-501`。

---

## 5. 运行中掉站

### 判据

**第一层（主站级 WKC）**

- `master.Diagnostics.WKC`（actual）vs `master.Diagnostics.ExpectedWKC`（expected）。
- `ExpectedWKC` 是**配置期固定真值**，概念上不可变；`WKC` 如实反映此刻总线。**绝不动态下调 expected 迁就劣化总线。**
- `WcDeficit > 0` **不是主站故障**，而是有映射从站此刻没贡献 WKC（疑似掉站 / 热插拔恢复中）。
- `0xFFFF`（`WkcUnknown`）= 本组本拍没测量，**不是全组零应答**；拿它求和会把 65535 当实测值。

出处：`Master\MasterDiagnosticsInfo.cs:2371-2384`、`:1001-1002`、`:1494-1510`、`:1559-1563`、`:2399-2400`；`云端\ethercat-doc\docs\faq\hot-connect.md:15`。

**第二层（逐站）**

- `slave.IsLost`：唯一真值入口 = native `SlaveLiveness()`。**本拍实测优先**（FPRD 探针应答 + 本周期过程数据贡献），拿不到实测才退到「实测置位的 is_lost 闩锁」；无任何实测时如实判「未确认离线」（false）。读失败也返回 false —— **不臆造离线**。
- `slave.HasEnteredOperational`：本次运行是否曾进过 OP（闩锁，进过就一直 true）。
- `slave.DroppedFromOperational`：进过 OP 但当前不在 OP（运行中掉出）。恢复进 OP 后回到 false。

出处：`Master\Slave\Core.cs:1319-1341`、`:1343-1367`。

**第三层（事件）**

- `master.Events.SlaveOffline` / `SlaveOnline`：参数是 `ushort slaveIndex`（**从 1 开始**）。
- `master.Events.SlaveOfflineDetailed`：带 `Reason` / `Probe` / `Contribution` 等证据。
- `master.Events.SlaveOfflineDisputed`：掉站标记与投递时刻证据矛盾（过程数据确证仍在贡献）。`Reason` 恒为 `Unreachable`，**不得据此判红 / 停线**。
- `slave.Events.Offline` / `Online`：从站级，无参数。

出处：`Master\Events.cs:277-287`、`:1176-1205`、`:2189-2245`、`:1553-1590`。

### 怎么查：从站掉了，还是主站丢帧？

| 证据 | 指向「从站掉」 | 指向「主站丢帧」 |
|---|---|---|
| WKC | `actual < expected`，缺口 ≈ 掉的那几站的贡献 | 整帧没发出/没收回，逐站 `IsLost` 仍为 false |
| 逐站 | `IsLost = true`；该站 AL 不可达（基础态 0x00） | 所有站 `IsLost = false`，但帧计数掉 |
| 事件 | `SlaveOffline` / `SlaveOfflineDetailed` | `PDOFrameLoss`（连续丢帧 ≥ `Config.FilterThreshold`，默认 3） |
| 主站统计 | `PrimaryPortErrors` / `SecondaryPortErrors` > 0 才是真端口错误 | `PacketLossRate`（5 秒滑窗，pipeline=2 帧在途容差）、`LateFrameRate`（帧到了但 idx 已过 8 帧窗口，说明 NIC 拥塞或 DPC 抖动严重）、`CyclicLostFrameCount`（ETG.1510 `0xF120:01` 累计真值） |

细节：

- `PrimaryPortOk = false` 且 `PrimaryPortErrors == 0` ⇒ **主口一帧都没走**（不是端口错误）；只有 `PrimaryPortErrors > 0` 才是真端口错误。
- 从站级端口计数：`ReadSlaveErrorCounters`（`0x0300-0x0313`，CRC 逐口，FrameErrors / LostFrames 四口求和）。字段名是历史遗留：数据来源是 ESC **Lost Link** 计数器，**不是 PDO 丢帧**。

出处：`Master\MasterDiagnosticsInfo.cs:964-996`、`:1545-1577`、`:2810-2859`、`:3261-3310`；`Master\Data\Type.cs:782-804`；`Master\MasterConfig.cs:261-276`；`Master\Events.cs:1216-1234`。

### R0 判据（物理机制，先记死）

> **帧从 A 口发出、没从 A 口回来 = 链路是通的，问题在「接收」**（B 口 / 对端 / 内核 RX / 绑定 / 接收路径）。
> **只有帧从 A 发出又从 A 弹回，才是中间真的断链。**

所以：`wkc = 0` / `BRD 无从站响应` / `-21 RESCAN_0` **都不等于链路断**。不要一看到 0 就重插网线或换卡，先去查接收路径。出处：`云端\ethercat-doc\_archive\sdk\csharp\error-handling.md:145`、`_archive\sdk\ccpp\error-handling.md:159`、`docs\sdk\java\master\diagnostics.md:301`。

### 怎么修

- **从站掉**：查该站线缆 / 接头 / 供电 / 接地、端口错误计数、AL 码。主站会**自动**尝试把它恢复到 OP（见 §6），**不要手动反复 `SetState`**。
- **主站丢帧**：查网线质量与屏蔽、交换机端口、网卡节能设置、EMI 干扰源、后台负载。
- **两个都不是**（`SlaveOfflineDisputed`）：按「证据矛盾」记录并继续观察，不要停线。

---

## 6. 热插拔恢复

### 判据

- **单站恢复是主站默认行为，不需要应用层写状态机。** 从站重新应答后，主站自动把它带回运行状态，健康从站不受扰动。
- **前提：主站目标状态是 OP。** 应用层把主站命令到 PreOp / SafeOp 时恢复不会启动（避免把操作员的降态命令顶回去）；命令回到 OP 后恢复继续。
- 从站**完全没有应答**（物理断开或断电）期间不会恢复；一旦重新应答（插回或重新上电）自动进入恢复流程。
- 恢复失败会如实上报并继续重试，**不会把失败报成成功**。
- 恢复耗时取决于从站响应速度、配置规模、是否需要重建拓扑，**不能用固定毫秒数承诺**。
- 检测时延以 PDO 周期计（周期越短越早察觉）。

出处：`云端\ethercat-doc\docs\faq\hot-connect.md:13-39`。

### 怎么查

1. 先确认主站目标态：上次 `SetState` 是不是 `EcState.OP`。
2. 看事件：`SlaveOffline` → `SlaveOnline`；或 `slave.Events.Offline` / `Online`。
3. 看现状：`slave.State` / `slave.HasEnteredOperational` / `slave.IsLost`。
4. 看拓扑是否需要重建：`master.Diagnostics.LastHotSwapRescanResult`。

### 怎么修（分级）

**① 目标态没回到 OP（最常见）**

```csharp
bool ok = master.SetState(EcState.OP, out string err);
```

恢复到 OP 后下一拍就会消费积压的恢复请求。

**② 站回来了但拓扑对不上 → 运行中增量重建**

`master.Diagnostics.HotSwapRebuild()`，结果码：

| 码 | 含义 | 处置 |
|---|---|---|
| `0` | 重建完成 | — |
| `-1` | 主站索引非法（门禁码） | 检查主站实例 |
| `-6` | 主站未初始化（门禁码） | 先 `Build()` |
| `-20` | BUSY，另一重建在跑 | 等它结束，不要并发 |
| `-21` | RESCAN_0，重扫 0 站可达 | 按 R0 **不归因链路断**，查接收路径 / 驱动绑定 |
| `-23` | NO_OP，从站在场但未进 OP | 看它带的第一个 AL 码，按 §3 / §4 查 |
| `-25` | IDX_FULL，资源耗尽 | 站数 / 组 / 缓冲上限，查工程规模 |

`-22` / `-24` / `-26` 是历史码，当前内核不再返回。

出处：`CSharp\Master\MasterDiagnosticsInfo.cs:2468-2488`、`MasterDiagnosticsInfo.HotSwapRescan.cs:41-109`；`C\include\master\diagnostics.h:601-620`；`Darra_EtherCAT_ClassLibrary\CSharp\README.md`（热插拔一节）与 `CPP\README.md:194`。

**③ 换过同型号设备 / 身份不符**

`master.AcknowledgeSlaveReplacement(slaveNum)` 人工确认后继续。出处：`CSharp\Master\Other.cs:460-480`。

**④ 从站本来就「可能不在场」**

- 单站：`slave.IsOptional = true`（**只允许在 `SetState(OP)` 之前设置**；设置失败会抛异常，不静默丢弃）。
- 成组：`HotConnect.AddGroup`（Alias 必须非 0 且组内唯一），属于 ETG.1020 组管理，和单站自动恢复是两件事；默认**没有任何组**配置。

出处：`Master\Slave\Core.cs:1380-1398`；`Master\HotConnect.cs:126-145`；`云端\ethercat-doc\docs\faq\hot-connect.md:80-87`。

**⑤ 自动增量重扫（不是单站恢复）**

`HotSwapAutoRescanEnabled` / `HotSwapAutoRescanIntervalMs` / `LastHotSwapRescanResult` —— 这是**拓扑增量重扫**，只在登记过 optional / Hot-Connect 组时才启用。不要把它当成「插回来自动进 OP」的开关。出处：`MasterDiagnosticsInfo.HotSwapRescan.cs:41-109`。

> **一处仓内注释与官方口径冲突，按官方口径办**：`CSharp\Master\HotConnect.cs:52-53` 写着「运行中插回不会自动进 OP」，这句只在「Hot-Connect 组登记」语境成立；单站自动恢复以 `云端\ethercat-doc\docs\faq\hot-connect.md:20`、`:70-78` 为准。

---

## 7. 周期抖动大 / 周期跑不满

### 判据

**先看是「平均高」还是「峰值高」**：

| 观察 | 结论 |
|---|---|
| 平均抖动低（< 10 µs）、峰值高（> 100 µs） | 硬件层干扰（SMI），要走 BIOS 优化 |
| 平均和峰值都高 | 系统负载过重，走应用层精简 |
| 总线抖动低、用户进程侧高 | 用户进程调度问题，提升进程优先级 |

出处：`云端\ethercat-doc\docs\faq\stability.md:49-53`。

诊断面板指标（SDK 同名属性）：

| 指标 | 属性 | 含义 |
|---|---|---|
| 平均抖动 / 峰值抖动 | `BusAvgJitterUs` / `BusMaxJitterUs` | RT 内核线程的帧发送时序偏差 |
| 干净最大抖动 | `BusCleanMaxJitterUs` | 排除 SMI 干扰后的最大抖动 |
| 往返延迟 | `BusRoundtripUs` | 帧发送到接收的往返时间 |
| SMI 次数 / 峰值 | `SmiCount` / `SmiPeakUs` | 系统管理中断干扰 |
| 丢包率 | `PacketLossRate` | 5 秒滑窗 `(ΣTX-ΣRX-pipeline)/ΣTX` |

> **旧的「应用抖动」指标已废止。** PDO 过程数据是纯内核 RT 收发 + GlobalIO 共享内存零拷贝，不存在「用户态每周期通知」环节，该量对本 SDK 无意义。GUI 上原来叫「应用抖动」的字段已改名为「邮箱收发延迟」（最大 `MailboxLatencyUs` / 平均 `MailboxLatencyAvgUs`）。用旧名字去找会找不到。

出处：`Master\MasterDiagnosticsInfo.cs:964-996`、`:1802-1811`、`:1922-1960`；`Darra_EtherCAT_Master\Logic\功能实现\状态诊断.cs:60`、`:155-156`；`云端\ethercat-doc\docs\faq\stability.md:38-47`。

### 怎么查

按顺序读这四个，能直接定位到层：

| 字段 | 回答什么 |
|---|---|
| `RtIsolation.Configured` | 实时核隔离**是否已配置**（权威 = Windows 内核的 ReservedCpuSets 预留核掩码）。注意：这只表示「已配置」，**不等于本会话已进入硬实时** |
| `KtimerWakeOverrunCount` | 定时器唤醒越过下一周期边界的次数 |
| `RtPreemptCount` / `RtPreemptPeakNs` | RT 线程被抢占 / 不可判定大间隔的累计次数与峰值 |
| `BigGapUnknownCount` | 硬件 SMI 计数不可用时、无法归因的大间隔次数 |
| `DispatchCycleMaxJitterUs` / `DrainCycleMaxJitterUs` | 分发/排空周期的最大抖动 |

GUI 的周期异常报警阈值（可作为「跑不满」的判据）：RTcnt 相对期望 **±20%**，连续 **3 次（1s 采样）** 才报周期漂；最大抖动 > 周期 **25%** 且 > **20 µs** 才算抖动异常。

出处：`CSharp\Master\Utils\RtIsolation.cs:36-41`、`:55-56`、`:307`、`:410-416`；`Master\MasterDiagnosticsInfo.cs:2034-2061`、`:2215-2227`；`Darra_EtherCAT_Master\Logic\功能实现\状态诊断.cs:803-809`。

### 怎么修

**① 实时核隔离没配 → 装包时预留**

- `--rt-masters 1..4` 预留最高端连续逻辑核，**重启后生效**。
- 缺值 / 不是整数 / 越界 → 安装器直接失败（`1639`），**不兜底成 1**。
- 覆盖安装 / 修复**不得把已预留的核数改小**；要改小必须显式传 `--rt-masters`。
- 隔离前提：至少给系统保留 2 核；逻辑核数必须在 3..64。

出处：`安装包\Program.cs:144-163`、`:290-305`、`:630-640`；`安装包\Services\RtMastersResolver.cs:27-32`、`:54-116`；`安装包\Services\RtOptimizationCore.cs:1201-1240`、`:1294-1296`；`云端\ethercat-doc\docs\downloads.md:68`。

**② BIOS 层（软件消不掉的 SMI）**

关 C-State、SpeedStep/EIST（锁频）、Turbo Boost、USB Legacy、风扇/温控 SMI；RT 核所在物理核关 SMT；关 Hyper-V / VBS / HVCI / 内存完整性。
**SMI 抖动无论 T1/T2/T3 软件层都消不掉，必须 BIOS 抑制。**

出处：`云端\ethercat-doc\docs\faq\stability.md:22-23`；`内部文档\HAL_CORE_ISOLATION_DESIGN.md:133-147`。

**③ 电源计划与优先级**

切「卓越性能」或「高性能」；`Win32PrioritySeparation = 0x18`（安装器已做）；CPU 最小/最大 100%、关 Core Parking、关 PCIe ASPM、关 USB 选择性挂起。

出处：`内部文档\兼容性与已知问题_Windows11.md:76-98`；`安装包\Services\RtOptimizationCore.cs:293-296`、`:848-854`。

**④ 周期值本身**

- `Config.LoopCycle` 单位 **ns**；Windows 建议 ≥ **125,000 ns（125 µs）**。
- `0` = 未配置 → 明确报错拒绝启动；`< 1000 ns` 物理不可行 → 拒绝；`< 125 µs` **只记一条 Message，按配置值原样下发，不静默钳制**（配置值与运行值必须一致）。
- 跑不动由诊断层如实报（抖动 / 超期 / 丢帧），不要靠悄悄把周期改大去「修好」。

出处：`Master\MasterConfig.cs:42-50`；`Master\State.cs:3554-3583`；`Master\Core.cs:1775-1777`；`云端\ethercat-doc\docs\sdk\csharp\master\config.md:63-82`。

**⑤ 应用侧**

- PDO 回调执行时间 < 周期的 50%；GC 暂停 < 1ms；回调里不做 SDO / Sleep / 文件 / 界面刷新 / 等锁。
- 安装器在没有确认网卡身份时**不猜改**网卡高级属性 / IRQ；这类调优要按现场网卡型号人工做。

出处：`云端\ethercat-doc\docs\faq\stability.md:88-90`；`安装包\Services\RtOptimizationCore.cs:165-174`、`:232-234`。

---

## 8. 升级 / 重装：3010 是什么意思

### 判据

**`3010` = 操作成功，重启后生效。它是成功码，不是失败。** 两档都算成功：

1. 本趟已装完，重启后生效。
2. 驱动本趟停不下来，安装器已安排好**开机换入**，重启后自动收尾，**不必再跑安装包**。

出处：`安装包\README.md:3-5`；`云端\ethercat-doc\docs\downloads.md:66-69`；`docs\quick-start\preparation.md:45-52`。

### 怎么查

安装器退出码表：

| 退出码 | 含义 | 下一步 |
|---|---|---|
| `0` | 成功 | 继续 |
| `1` | 失败（未分类异常 / 没有管理员权限） | 确认管理员权限与安装包完整性，重试一次 |
| `1602` | 用户取消，动作没执行 | 问用户还要不要装 |
| `1603` | 执行中出错（含磁盘空间不足） | 查磁盘空间与权限 |
| `1604` | 卸载没做全，机器上还剩文件 | 如实告知，或联系支持 |
| `1618` | 另一个安装/卸载事务正在跑 | 等它结束再重试 |
| `1622` | 日志写不进去，动作已停手 | 先解决磁盘空间、目录写权限 |
| `1639` | 命令行参数对这个动作不可用（`--rt-masters` 值不合法也算这个） | 按官方命令重写，不要自己加参数 |
| **`3010`** | **操作成功，重启后生效** | 见下 |

出处：`云端\ethercat-doc\docs\downloads.md:56-70`。

### 怎么修

- **看到 `3010`**：告诉使用人「已安装成功，需要重启才生效」，重启时机由使用人决定。**不要自动重启机器**，**不要因为「还没生效」反复重装**。重启后如仍未完成，再运行一次安装包。
- **升级 = 直接再跑一次安装包**（`--silent --install`），**不用先卸载、不用先重启**。把升级拆成「卸载 → 重启 → 安装」三步是错的。
- **卸载**是独立动作，只在用户明确要卸时执行（`--silent --uninstall`）。
- **版本兼容**：MAJOR/MINOR 变化（如 2.10.x → 2.11.0）**必须重新安装官方安装包**；PATCH（如 2.11.0 → 2.11.5）通常无需重装。版本不匹配**不阻断运行**，只记版本提示，是否兼容以驱动是否正常响应为准。

出处：`云端\ethercat-doc\docs\faq\licensing.md:56-62`；`docs\sdk\index.md:34-40`；`CSharp\Master\Utils\DriverVersionHelper.cs:91-111`。

---

## 9. 授权 / 评估期

### 判据

**状态面**：`Authorization.LicenseStatus`

| 值 | 成员 | 含义 |
|---|---|---|
| `0` | `NotVerified` | 未验证 / 未校验（运行库不可用也归这里，安全默认） |
| `1` | `Verifying` | 校验中 |
| `2` | `Verified` | **唯一有效态** |
| `3` | `Failed` | 校验失败 / 已吊销 |
| `4` | `Expired` | 已过期 |
| `7` | `QuotaExceeded` | 企业授权席位已用尽 |

未命名的内部态（机器码不匹配 / 时钟回拨 / 机器绑定未成立 / 时间判据不可用）读回一律按 `NotVerified` 处理。**判定永远是 `LicenseStatus == Verified`，其余一切都按未验证处理。**

出处：`CSharp\Master\Static\Authorization.cs:290-313`、`:348-400`。

**数据面**：未激活 / 过期 / 授权异常 → **数据门关闭**，对外表现是错误码 **`5023`**（Windows `ERROR_INVALID_STATE`）。

- `5023` 与网卡无关。绑定网卡时失败会带 `5023`。
- 主站能创建，但切 SafeOp / OP 会被拒（该路径返回 `FALSE` 并记「内部服务异常」，不另带 5023）。
- PDO 数据面被门控时会退 SafeOp 并停周期发送。

出处：`云端\ethercat-doc\docs\faq\error-codes.md:27-41`；`CSharp\Master\Initialise.cs:2905`；`Darra_EtherCAT_Drive\main\core\state\state_machine.c:4249-4259`、`:12090-12093`；`Darra_EtherCAT_Drive\main\core\base\events.c:4360-4388`。

**评估期**：未激活的评估版**每次开机、驱动启动后 2 小时内**可正常使用；到期停止总线通信。**同一开机内关闭或重开程序不重新计时**，重新开机后重新给满 2 小时。

出处：`云端\ethercat-doc\docs\faq\licensing.md:48-50`；`内部文档\认证与授权机制.md:14-26`。

### 怎么查

```csharp
var status = DarraEtherCAT.Authorization.LicenseStatus;
bool gateClosed = DarraEtherCAT.Authorization.DataGateClosed;
```

- 先查 `LicenseStatus`：`Expired` / `Failed` / `QuotaExceeded` / `NotVerified` 都按未验证处理。
- 再查 `DataGateClosed`：门已关 ≠ 一定是过期，也可能是未激活 / 证书校验失败 / 被改过的文件。
- 各语言入口一致：Python `Authorization.license_status` / `data_gate_closed`；Java `getLicenseStatus()` / `isDataGateClosed()`；Rust `license_status()` / `data_gate_closed()`；C `DarraEcat_GetLicenseStatusEx()` / `DarraEcat_IsDataGateClosed()`。

出处：`CSharp\Master\Static\Authorization.cs:348-421`；`云端\ethercat-doc\docs\faq\licensing.md:32-43`。

### 怎么修

1. 打开**软件激活**对话框看授权状态，只有「已验证」才表示有效。
2. 未激活：输入购买时发放的激活码并联网激活（`Authorization.Activate("激活码")`，需管理员权限）。
3. 已过期或席位用尽：续期或联系技术支持。
4. 重新激活时若提示「检测到本机已有授权」，按提示清除原有授权（需管理员权限）。
5. **不要因为看到 `5023` 就换网线、重装驱动或重新绑定网卡** —— 这些操作不会解决授权问题。

出处：`云端\ethercat-doc\docs\faq\error-codes.md:36-41`；`docs\faq\licensing.md:17-30`、`:44-54`；`CSharp\Master\Static\Authorization.cs:433`。

---

## 附录 A：出处索引

| 主题 | 文件:行 |
|---|---|
| 分层判断表 | `云端\ethercat-doc\docs\faq\error-codes.md:13-19` |
| `ScanOutcome` 全枚举 | `Darra_EtherCAT_ClassLibrary\CSharp\Master\Static\Network.cs:2909-2951` |
| 扫描两套来源 | `Network.cs:2900-2907` |
| 原生扫描码 `-1/-2/-3` + `-1201..-1206` | `Darra_EtherCAT_ClassLibrary\C\include\statics\network.h:57-117`、`:170-189` |
| 结束码 → 失败原因分类 | `Network.cs:2962-3007` |
| 未归类负码保留 | `Network.cs:3015-3058` |
| `LastScanError` / `LastScanErrorCode` | `Network.cs:2576-2610`、`:3076-3110` |
| `NicScanState` 八态 | `Darra_EtherCAT_ClassLibrary\CSharp\README.md:158-171` |
| `NetworkAdapterInfo` 字段 | `Network.cs:1408-1497` |
| `nic_scan_status_t` | `Darra_EtherCAT_ClassLibrary\C\include\data\structures.h:427-442` |
| OP 失败逐站原因 | `CSharp\Master\State.cs:683-760` |
| AL 码失败文案（0xFFFF = 未知） | `State.cs:762-778` |
| `0x001F` demote grace / 硬错误判定 | `State.cs:260-357` |
| `SetState` 公共入口 | `State.cs:3480-3489` |
| AL 码分类 | `State.cs:4945-4963`；`Master\Data\Type.cs:520-544`；`C\include\master\diagnostics_ext.h:39-65` |
| `EcState` / `EcSlaveStatus` | `Master\Data\Type.cs:28-93` |
| `EcALState` 全表 | `Master\Data\Type.cs:417-501` |
| `0x0130` / `0x0134` 寄存器语义 | `C\include\data\structures.h:888-889`；`Master\Data\Type.cs:37-54` |
| `ErrorCode` vs `AlStatusCode` | `Master\Slave\Core.cs:169-192`、`:3197-3265` |
| 实读链 `D_1699` | `Master\Slave\Core.cs:1590-1630` |
| 看门狗状态 + Conclusive | `Master\Slave\Core.cs:1500-1533` |
| `SetWatchdog` 安全下限 | `Master\Slave\Core.cs:1402-1413` |
| `IsLost` / `HasEnteredOperational` | `Master\Slave\Core.cs:1319-1367` |
| `IsOptional` | `Master\Slave\Core.cs:1380-1398` |
| WKC / ExpectedWKC | `Master\MasterDiagnosticsInfo.cs:2371-2384`、`:1545-1577` |
| R1「expected 固定」口径 | `MasterDiagnosticsInfo.cs:1001-1002`、`:1494-1510` |
| `WkcUnknown` 哨兵 | `MasterDiagnosticsInfo.cs:1559-1563`、`:2399-2400` |
| 丢包率 / 过慢帧 / 累计丢帧 | `MasterDiagnosticsInfo.cs:964-996` |
| 端口错误 / `PrimaryPortOk` | `MasterDiagnosticsInfo.cs:2810-2859` |
| 从站端口计数 | `MasterDiagnosticsInfo.cs:3261-3310`；`Master\Data\Type.cs:782-804` |
| 抖动 / SMI 指标 | `MasterDiagnosticsInfo.cs:1922-1960` |
| 「应用抖动」已废止 | `MasterDiagnosticsInfo.cs:1802-1811`；`Darra_EtherCAT_Master\Logic\功能实现\状态诊断.cs:60`、`:155-156` |
| RT 抢占 / 大间隔 | `MasterDiagnosticsInfo.cs:2034-2061`、`:2215-2227` |
| 实时核隔离判定 | `Master\Utils\RtIsolation.cs:36-41`、`:55-56`、`:307`、`:410-416` |
| 周期异常报警阈值 | `Darra_EtherCAT_Master\Logic\功能实现\状态诊断.cs:803-809` |
| `LoopCycle` 口径 | `Master\MasterConfig.cs:42-50`；`Master\State.cs:3554-3583`；`Master\Core.cs:1775-1777` |
| 掉站 / 上线事件 | `Master\Events.cs:277-287`、`:1176-1205`、`:2189-2245`、`:1553-1590` |
| `PDOFrameLoss` | `Master\Events.cs:1216-1234`；`Master\MasterConfig.cs:261-276` |
| 热插拔重建结果码 | `Master\MasterDiagnosticsInfo.cs:2468-2488`；`C\include\master\diagnostics.h:601-620` |
| 自动重扫 | `Master\MasterDiagnosticsInfo.HotSwapRescan.cs:41-109` |
| 从站替换确认 | `Master\Other.cs:460-480` |
| HotConnect 组 | `Master\HotConnect.cs:126-145` |
| 热插拔工作原理 | `云端\ethercat-doc\docs\faq\hot-connect.md:13-39`、`:62-78` |
| AL 码常见表 | `云端\ethercat-doc\docs\faq\error-codes.md:78-94` |
| 5023 / 1168 / 21 | `云端\ethercat-doc\docs\faq\error-codes.md:25-66` |
| 安装器退出码 | `云端\ethercat-doc\docs\downloads.md:56-70` |
| 3010 两档 | `安装包\README.md:3-5`；`docs\quick-start\preparation.md:45-52` |
| `--rt-masters` 解析与落盘 | `安装包\Program.cs:144-163`、`:290-305`、`:630-640`；`安装包\Services\RtMastersResolver.cs:27-116`；`安装包\Services\RtOptimizationCore.cs:1201-1240`、`:1294-1296` |
| 授权枚举与查询 | `Master\Static\Authorization.cs:290-421`、`:433` |
| 授权 / 评估期文档 | `云端\ethercat-doc\docs\faq\licensing.md:17-62` |
| 2h 宽限实现口径 | `内部文档\认证与授权机制.md:14-26` |
| 实时方案 T1/T2/T3、抖动目标 | `云端\ethercat-doc\docs\faq\stability.md:13-23`、`:38-53`、`:88-90` |
| BIOS 调优清单 | `内部文档\HAL_CORE_ISOLATION_DESIGN.md:133-147` |
| Windows 电源计划 | `内部文档\兼容性与已知问题_Windows11.md:76-98` |
| R0 判据（A 口/B 口） | `云端\ethercat-doc\_archive\sdk\csharp\error-handling.md:145`；`_archive\sdk\ccpp\error-handling.md:159`；`docs\sdk\java\master\diagnostics.md:301` |

---

## 附录 B：查不到出处、本文没写的项

以下项在仓内没有可靠起源，**不要凭印象补**，实际以设备手册或实际 SDK 返回为准：

1. **`0x002E`（周期时间过小）的完整触发与上报链路。** 仓内只找到枚举定义（`Master\Data\Type.cs:467-468`、`C\include\ethercat_types.h:828`、`:879`）和文档定义，没找到「主站周期 < 从站最小周期 → 报 0x002E」的逐行实现路径。本文只写「把周期调大」这一条稳妥处置。
2. **PDO 回调执行时间 / GC 暂停的直接代码度量。** 仓内只有文档目标值（`stability.md:88-90`），没有对应测量代码；能读的是 `RtPreemptCount` / `BigGapUnknownCount` / `DispatchCycleMaxJitterUs` 等 RT 线程侧代理指标。
3. **「清除授权」的独立 SDK API。** 仓内没有导出；只有「覆盖激活」（新码成功后覆盖证书，不先删旧证）。文档里的「清除本机原有授权」是激活流程中的提示动作，不是可调用接口。
4. **评估期「剩余时间 / 剩余秒数」的公开查询入口。** 仓内没有对外暴露（`Authorization.cs` 注释明确说明 Core 未提供）；只能读 `DataGateClosed` 与 `LicenseStatus`。
5. **`MasterDiagnosticsInfo.ActualWKC` 属性不存在。** 主站级 actual 的公开面是 `MasterDiagnosticsInfo.WKC`；组级才是 `SlaveGroupList.ActualWKC`。写代码时不要臆造属性名。
6. **`0x002F` 在 ETG 表里无定义**（`C\include\ethercat_types.h:829` 明确说明）。`0x8000` 以上为厂商自定义，含义以设备手册为准。
7. **`AL 0x0011 / 0x0012`（无效状态切换 / 未知请求状态）的具体处置。** 枚举里有定义（`Master\Data\Type.cs:435-436`），但仓内没有针对这两个码的处置口径，本文不给建议。
