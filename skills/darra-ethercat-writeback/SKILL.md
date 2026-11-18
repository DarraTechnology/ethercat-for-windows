---
name: darra-ethercat-writeback
description: >
  用户程序在运行中要改 EtherCAT 配置时使用：先查「当前状态允不允许写」，再按正确的组合与时机下发，
  写完读回确认真的生效，改错了能回退。覆盖主站级（周期、三档状态转换超时、看门狗、邮箱超时、
  PDO 丢帧阈值、热插拔重扫、诊断开关、传输/帧参数）与从站级（DC 的 assignActivate/SYNC0/SYNC1/相位、
  启动 SDO 计划、PDO 输出、PDO 映射、SM 配置、普通 SDO 参数）。讲的是「什么状态下能改什么、
  怎么改才不把总线搞掉、改错了会怎样」，不是工艺参数整定。
  触发词：在线改参数、下发、写回、写参数、什么状态能改、状态机能不能改、query:writable、--write、
  STATE_NOT_ALLOWED、PATH_READONLY、改周期、改 loopCycle、改 DC、改 SYNC0、改 assignActivate、
  改 PDO 映射、改启动 SDO、改看门狗、改邮箱超时、换配方、调参、热插拔重扫、生效时机、读回验证。
---

# Darra EtherCAT 在线下发：什么状态下能改什么

这份技能只回答三件事：**现在这个状态允许不允许写**、**怎么写才不把从站搞掉**、**写完怎么确认真的生效**。

> **服务对象是「用户自己写的程序」的运行时**，不是我们的 GUI。主场景：你的程序正在跑，需要在线改某个参数
> （换配方、调 PID、改周期），这时候怎么改才不把总线搞掉。你走 SDK 直调也好、走写回接口也好，
> **状态门、成组约束、验证判据是同一套**；本文给的是约束与判据，不规定你的程序长什么样。

写主站程序看 [darra-ethercat](../darra-ethercat/SKILL.md)；SDO/对象字典/abort 码看
[darra-ethercat-parameters](../darra-ethercat-parameters/SKILL.md)；现场投产顺序看
[darra-ethercat-commissioning](../darra-ethercat-commissioning/SKILL.md)。

> **出处前缀**：`ETH\` = `A:\c\Darra\Darra_EtherCAT_Master\`；`DOC\` = `ETH\云端\ethercat-doc\`。
> 本文 `文件:行` 按这两个前缀展开。SDK 源码在 `ETH\Darra_EtherCAT_ClassLibrary\CSharp\`，
> 原生实现在 `ETH\Darra_EtherCAT_Drive\main\core\`。

---

## 先记住四句话

1. **先查表，再动手。** 运行时以 `query:writable` 返回的 `allowedStates` 为准，**不要凭记忆硬编码本文的矩阵**；本文的表是「为什么这么划分」和「判据出处在哪」。
2. **写成功 ≠ 已生效。** 有的字段下一个周期生效，有的要等下一次状态转换，有的要重建主站；还有几个字段**根本改不动**（写进去只留一条日志）。验证方式必须跟着 `applyTiming` 走。
3. **该成组的绝不拆开写。** DC 的 `assignActivate + SYNC0 + SYNC1 + 相位` 是一个整体，分开写会在中间态把从站带进错误周期。
4. **改错了要有回退，不要靠再改一次碰运气。** 写之前先读旧值，读回不一致就写回旧值并报错。

---

## 0. 为什么这件事危险

不是「改参数会报错」这么轻。下面四条是**真实后果**，每一条都能在源码或实测注释里找到依据。

### 0.1 OP 下改 DC：你以为改了，其实没写；真写了会掉站

- **正常路径下根本写不进去。** `SetSyncBySlaveIndex` 先登记意图，再过一个**逐站实测 AL 状态**的写门；门没开只打一条 warning，硬件寄存器一个都不动：
  `[roundCFGPREGATE1][ECM-USERDC2] SetSyncBySlaveIndex intent kept, ESC 0x0980/0x09A0 deferred ... 本分支未调用 dc_sync0/dc_sync01`
  （`ETH\Darra_EtherCAT_Drive\main\core\config\config_common.c:17439-17450`）
- **更坑的是调用方看不出来。** C# 的 `Slave.ConfigureDC(uint,uint,int?)` 走的是 void 原生入口，只要派发成功就返回 `true`，**不代表已落地**
  （`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Slave\DC.cs:1098-1129`，原生 `d1090` 是 void：`...\Master\Utils\DLL.cs:580`）。
  结果就是：程序以为改好了，实际要等你下次降到 PRE_OP 才被重放——那时候现场已经没人盯着了。
- **就算真写进去了（写门当时恰好开着，或绕过 SDK 直接动 ESC 寄存器），代价是掉站。** 从站按新节拍等 SYNC0，主站还按旧节拍发帧，第二拍就同步超时：
  AL `0x001A`（同步错误）/ `0x002D`（第一拍 SYNC0 超时，从站拒绝进 OP）/ `0x0034`（DC 同步超时）
  （`DOC\docs\faq\error-codes.md:82,88,89`）。
- 原生自己也有明确保护：OP 中 SYNC0 已在跑时**不写** `0x0990/0x0980`，因为「没有 0→1 沿的重写不会锁存新起点，只会打乱已锁定的 PLL」
  （`ETH\Darra_EtherCAT_Drive\main\core\ethercat\dc.c:5097-5100`）。

### 0.2 OP 下改 PDO 映射：从站直接拒绝，或者**不报错地错位**

- 改 `0x1C12` / `0x1C13` 必须在 PreOp；SafeOp / OP 下写会被从站拒绝
  （`DOC\docs\ethercat\device-profiles\coe.md:288`）。
- 更狠的是「字节数对、顺序错」：映射条目顺序必须和主站侧结构体字段顺序一致，错了不会报任何错——
  你读到的「状态字」其实是别人的字段。值看着在跳，一使能就飞车
  （`DOC\static\ai-prompts.txt:330-347`：结构体必须 `Pack=1`、总大小 == `Ibytes`/`Obytes`、字段顺序 == 映射条目顺序）。

### 0.3 PDO 大小 / 映射配错：从站进不了 SafeOp，且错误码藏在 AL 里

- AL `0x0017` = 无效 SM 配置（SyncManager 的大小或方向与从站不匹配）。SM/FMMU 由主站按 ESI 在
  `PREOP → SAFEOP` 自动写寄存器（`DOC\docs\ethercat\beginner-guide\sm-fmmu.md:113-120`），**不是**用户逐条写的对象；
  你改了 PDO 分配/字节数，主站就会按新配置重算 SM——算错了就落在这个码上。
- AL `0x001D` / `0x001E` = 输出 / 输入配置与从站支持的不一致
- AL `0x0024` / `0x0025` = 输入 / 输出映射的索引、子索引、长度或顺序不对
  （以上 `DOC\docs\faq\error-codes.md:81,84,85,86,87`）
- 现象是「主站能启动、从站停在 SafeOp 进不了 OP」，很容易被误判成硬件坏。

### 0.4 改周期 / 看门狗：改小一点点就掉站

- `LoopCycle` 必须是**整数微秒**且落在 `[31, 10000] µs`，超了直接拒绝写入、保持原值
  （`ETH\Darra_EtherCAT_Drive\main\core\config\config_common.c:17216-17235`；
  门限定义 `...\core\diagnostics\diagnostics.c:3962,3965`）。
- PD 看门狗低于**拓扑安全下限**会被强制抬高：分支从站 5000 ms、环上 PDO 从站 400 ms——
  原生会按抬高后的值写硬件，但**对外返回 `FALSE` + last-error**，意思是「实际下发 ≠ 你请求的值」
  （`...\core\config\config_startup.c:16613-16620,16660-16705`）。
  只看返回值 `false` 就以为「没写」，是错的；只看「写了」就以为「按我写的值」，也是错的。**必须读回实际毫秒。**

---

## 1. 主站状态速查

| 状态 | 枚举值 | 邮箱（SDO） | 过程数据 | 能不能改配置 |
|---|---|---|---|---|
| `NONE` | 0x00 | — | — | 主站未建站/已关闭，什么都改不了 |
| `INIT` | 0x01 | 未起（SM0/SM1 未配） | 无 | 可以改「配置期」字段 |
| `PRE_OP` | 0x02 | 可用 | 无 | 唯一的**完整配置窗口**：DC、PDO 映射、启动 SDO、SM |
| `BOOT` | 0x03 | 仅 FoE 等引导服务 | 无 | 不是配置态，别在这里改参数 |
| `SAFE_OP` | 0x04 | 视从站而定（有些已死） | 输入有效、输出未生效 | 只能改不碰映射/同步的少量运行参数 |
| `OP` | 0x08 | 视从站而定（有些已死） | 双向有效 | 基本只允许 PDO 输出和「任意状态」字段 |

- 枚举与取值：`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Data\Type.cs:28-44`
- `master.State` 在未建站/读不到时返回 `EcState.None`：`...\CSharp\Master\State.cs:477-487`
- 状态机唯一公开入口：`master.SetState(EcState target, out string error)`：`...\CSharp\Master\State.cs:3489`

> **「全在 PRE_OP」是很多写门的真实判据。** 原生按**逐站 fresh 实测**的 AL 状态取最高基态，只有全部落在
> `INIT` 或 `PRE_OP` 才放行；任何一站 SafeOp/OP、无站地址、读不到新鲜应答，一律 fail closed
> （`...\core\config\config_common.c:1580-1655`，关键判据 `:1649`）。
> 也就是说：**只要有一个从站还在 OP，改 DC 的硬件写就进不去**——不是主站状态对了就行。

---

## 2. 状态 × 可改项矩阵（核心）

### 2.1 怎么读这张表

- **路径**：`query:writable` 的 `entries[].path`，`--write <path>=<value>` 用同一个字符串。**不要自创字段名。**
- **允许状态**：该路径的 `allowedStates`。`["ANY"]` = 任意状态（含主站未建站，视字段而定）。
- **生效时机**：`applyTiming`，四选一：`immediate` / `nextBuild` / `nextCycle` / `nextTransition`。
- **⚠** = 冻结契约的口径比原生写门更严，或该字段有「写了不生效」的已知事实，**必须看「注意」列**。

> **本表已按 2.13.16 实测 `query:writable`（52 项）校正**（2026-11-18，`192.168.3.120`）。
> 运行时仍以当次返回为准：命令是 `act:write;path=...;value=...`（GUI 命令通道），
> 与 CLI 的 `--write <path>=<value>` 用同一套 `path` 字符串。

### 2.2 主站级

| path | 类型/单位 | 允许状态 | 生效时机 | 改错的后果 | 回退办法 | 注意 / 源码判据 |
|---|---|---|---|---|---|---|
| `master.loopCycle` | uint / ns | `["INIT"]` ⚠ | `nextCycle` | 非整数微秒或超出 `[31,10000] µs` → 原生拒绝、保持原值；改小导致丢帧/掉 OP；与 DC 站 SYNC0 不成整数倍 → AL `0x001A/0x002D/0x0034` | 在同一个窗口写回原值；或改 DENI 重连 | ⚠ 原生写门实际是「全站 INIT/PRE_OP」（`config_common.c:17188` → `:1649`），契约对外只开 INIT。另：托管 setter 在**状态转换进行中会直接跳过**并打 warning（`CSharp\Master\Core.cs:1793-1797`），所以「写了没反应」先看是不是正在转换。判据：`Core.cs:1756-1832`、`config_common.c:17142-17260`、`diagnostics.c:3962,3965` |
| `master.dcCycle` | uint / ns | `["INIT"]` | `nextCycle` | 换 DC 时基会让所有 DC 站的 SYNC0 参考重算；DC 已武装时换 → 全环同步抖/掉 OP | 写回原值（同样要在未武装窗口） | native 拒绝条件：0 ns 无意义、>10 ms 超内核 RT 上限、**DC 已武装或无法证明未武装**时拒绝且保持原值（`CSharp\Master\Core.cs:1835-1867`，门在 `config_common.c:17026`） |
| `master.timeout.initToPreOp` | int / ms | `["INIT"]` | `nextTransition` | 改太小 → 慢从站被误判超时，转换失败；`0` = **不超时**（等于关掉保护，卡死也回不来） | 写回默认（ETG 默认 3000） | 只在**升级方向**被读取（`core\state\state_machine.c:6023`）；上限被钳到 30 min（`:6030-6036`）。负值在托管层直接抛 `ArgumentOutOfRangeException`（`MasterConfig.cs:467-469`） |
| `master.timeout.preOpToSafeOp` | int / ms | `["INIT","PRE_OP"]` | `nextTransition` | 同上；这个窗口要写启动 SDO + PDO 映射，太短会「配置写一半超时」 | 写回默认（10000） | `MasterConfig.cs:487-513`；`state_machine.c:6024` |
| `master.timeout.safeOpToOp` | int / ms | `["INIT","PRE_OP","SAFE_OP"]` | `nextTransition` | 太短 → DC PLL 还没锁就被判失败；太长 → 故障恢复慢 | 写回默认（5000） | `MasterConfig.cs:519-545`；`state_machine.c:6025` |
| `master.processDataWatchdogMs` | uint / ms | `["INIT","PRE_OP"]` | `nextTransition` | **低于拓扑安全下限会被抬高**（分支站 5000 / 环上 PDO 站 400），实际下发 ≠ 请求；太大 → 从站掉线后迟迟不报；`0` = 用从站默认 | 写回原值，或按读回的实际值调整上层超时判断 | 写入只是存进共享内存，**真正下发在进 OP / 热插拔恢复时逐站写寄存器**（`MasterConfig.cs:375-410`；`core\base\events.c:25589,25874`；`config_startup.c:16660-16705`）。`>6553` 托管层直接抛（`MasterConfig.cs:397-398`） |
| `master.pdiWatchdogMs` | int / ms | `["INIT","PRE_OP"]` | `nextTransition` | 设太大 → 从站主站断连后仍继续输出；设太小 → 正常抖动也触发 | 写回原值 | 同上；默认 `0`（禁用）是刻意的，历史事故是 1000 ms 让部分从站 AL `0x001F` 进不了 OP（`MasterConfig.cs:421-426`） |
| `master.mailbox.timeoutMs` | int / ms | `["ANY"]` | `immediate` | 太小 → SDO 频繁超时（`0x05040000` 类），启动参数批量写失败；太大 → 真故障要等很久才报 | 写回原值 | **纯托管字段**，不碰原生：邮箱事务在调用方没显式设超时时取本值（`MasterConfig.cs:355-373,687-696`；`Master\Abstractions\MailboxTransaction.cs:79`）。范围 1–60000 |
| `master.mailbox.retryCount` | int / 次 | — | — | — | — | **`writable:false`。赋值只打一条 ERROR 日志、不下发、不生效**：托管层没有「失败自动重投」的转发点，盲目重投会让非幂等邮箱服务（FoE/SoE/CoE 写）被重复执行（`MasterConfig.cs:698-723`，日志在 `:716-720`）。要重试请在调用方自己重试 |
| `master.pdoFilterThreshold` | uint / 帧 | `["ANY"]` | `immediate` | 调小 → 拔插瞬间疯狂报丢帧；调大 → 真丢帧要连续 N 拍才报，报警滞后 | 写回原值（默认 3） | 每周期被读：`core\base\events.c:12086,13792,14574`；`0` 时事件层按 3 处理（`events.c:2794`）。`MasterConfig.cs:261-291`（DLL 未就绪时写不进去并打 warning） |
| `master.hotSwapAutoRescanEnabled` | bool | `["ANY"]` | `immediate` | 关掉 → 插回站点不再自动发现，要手工 `HotSwapRebuild`；开着但没登记 optional 组 → 零开销（计时器根本不建） | 写回 `true` | 纯托管计时器，运行中赋值立即起作用（`MasterDiagnosticsInfo.HotSwapRescan.cs:41-68`） |
| `master.hotSwapAutoRescanIntervalMs` | int / ms | `["ANY"]` | `immediate` | 赋值**被夹紧到 `[100,60000]`**：写 10 会变 100，写 999999 会变 60000，不报错 | 写回原值 | `MasterDiagnosticsInfo.HotSwapRescan.cs:26-30,70-90`（夹紧在 `:80-82`） |
| `master.diagnostics.enabled` | bool | `["ANY"]` | `immediate` | 关掉只影响**可选统计**（帧计数/抖动/错误率）；WKC、周期、丢站记账属于基线档，**恒开、不受本开关影响** | 写回 `true` | `CSharp\Master\MasterDiagnosticsInfo.cs:786-800`；`core\diagnostics\diagnostics.c:562-579`（日志原文写明了生效范围） |
| `master.highResolutionTimer` | bool | `["ANY"]` | `immediate` | 关掉 → 1 ms 定时精度下降，周期抖动变大 | 写回 `true` | 进程级开关，Windows 上赋值即生效（`MasterConfig.cs:52-59`；`Core.cs:1869-1876`） |
| `master.frameHighPriority` | bool | `["ANY"]` | `immediate` | **Windows 上不生效**（native 明确「未实现 OS 层帧优先级提升」），改它只有心理作用 | 无需回退 | 值存在 `ec_State`，在 `SetNetwork` 才被消费：`core\state\state_machine.c:5571`；Windows 不支持的说明 `:5598`。`MasterConfig.cs:63-91` |
| `master.useUdp` | bool | `["ANY"]` | `immediate` | **标准 EtherCAT 从站不支持 UDP 帧**，开了整条总线直接不通（只适用于 EL6601/EL6614 这类网关） | 立刻写回 `false` | 运行时双 Socket 切换；UDP socket 必须在 `SetNetwork` 时就建好，否则切换返回失败：`core\protocol\udp_support.c:63-95`（`:77` 写标志）。`MasterConfig.cs:93-126` |
| `master.vlanId` | ushort | `["ANY"]`（**`writable:false` 只读**） | `immediate` | 大部分标准从站不支持 VLAN 帧；非零会让帧头从 14 字节变 18 字节，从站全不认 | 写回 `0` | 托管文档明写「**需要在 SetNetwork 之前设置**、仅 WDK 驱动模式生效」：`MasterConfig.cs:128-162`（范围 0–4095，越界抛）。发送侧在 `state_machine.c:21125-21136` |
| `master.vlanPriority` | byte | `["ANY"]`（**`writable:false` 只读**） | `immediate` | 需要先有非零 `vlanId` 才有意义；范围 0–7 | 写回 `0` | `MasterConfig.cs:164-195`（越界抛）；消费点同上 |
| `master.overlappingGroups` | bool | `["INIT","PRE_OP"]` | `nextTransition` | 开了但从站不支持 FMMU 逻辑地址重叠 → 过程数据整体错位（不报错）；标准 Beckhoff / 第三方从站**不要开** | 写回 `false`，重建主站 | 托管文档明写「仅在 INIT 或 PRE_OP 状态下设置」：`MasterConfig.cs:199-228`；帧构建时读取 `core\state\state_machine.c:17105` |
| `master.frameRepeatCount` | byte | `["ANY"]` | `immediate` | 仅对组内全部支持 FrameRepeat 的从站生效；设 2–3 会让总线负载成倍上涨 | 写回 `1` | 范围 1–3，越界抛（`MasterConfig.cs:295-324`）；周期路径每拍读（`core\base\events.c:13653,14238`） |
| `master.mutexProtection` | bool | — | — | — | — | **`writable:false`。原生固定 fail-closed 启用**：传 `false` 只打一条 warning，`mutex_protection` 仍写 1（`core\state\state_machine.c:24649-24663`）。`MasterConfig.cs:326-346` |

### 2.3 从站级

| path | 类型/单位 | 允许状态 | 生效时机 | 改错的后果 | 回退办法 | 注意 / 源码判据 |
|---|---|---|---|---|---|---|
| `slave[n].dc.assignActivate` | ushort | `["ANY"]`（**`writable:false` 只读**，写走 `slave[n].dc.mode`） | `nextTransition` | 写错使能位（例如该给 SYNC0 却给了别的位）→ 从站按错误同步模式武装：SYNC 信号不出来，进 OP 那一步超时掉回 SafeOp（AL `0x001A/0x002D/0x0034`） | 改回 ESI 声明值，或 `ConfigureDC(DcSyncMode.FreeRun)` 收回武装 | **C# 目前没有可写的 `assignActivate` 属性**：`slave.DcAssignActivate` 是只读落地镜像（`CSharp\Master\Slave\DC.cs:2011-2027`）。写路径是 `ConfigureDC(DcSyncMode, ...)`（`:1277`），由一个模式原子地推出使能位。ESI 声明值可读：`slave.EsiDcAssignActivate`（`Slave\Core.cs:372-400`） |
| `slave[n].dc.sync0CycleNs` | uint / ns | `["INIT","PRE_OP"]` | `nextTransition` | 必须 = `LoopCycle` 或为其**整数倍**；不是整数倍 → 数据未到达的同步没有意义，从站掉 OP | 写回原值；`0` = 卸下 SYNC0 武装（回 FreeRun） | 门：托管侧「全站 PreOp 才重放」`CSharp\Master\Slave\DC.cs:1020-1045`；原生逐站实测 `core\dc\dc_sync.c:624-700`。API：`DC.cs:1102,2398` |
| `slave[n].dc.sync1CycleNs` | uint / ns | `["INIT","PRE_OP"]` | `nextTransition` | 从站没有 SYNC1 能力（AssignActivate bit10 `0x0400`）却给了非零值 → 武装失败/无 SYNC1 输出 | 写回 `0` | `DC.cs:1269-1272`；SYNC1 使能位说明 `Slave\Core.cs:759-770` |
| `slave[n].dc.shiftNs` | int / ns | `["INIT","PRE_OP"]` | `nextTransition` | `0` = **字面 0 相位**（SYNC0 落在周期边界，不再回落 70%）；填错相位 → 从站在错误时刻采样，表现为同步错误或跟随误差大 | 传「未指定」（null）让它按 ESI → 70% 自动解析，或写回旧值 | 相位优先级：ESI 显式 > 用户显式（含 0/负值）> 默认「1 倍周期 + 70%」（`DC.cs:1085-1097`；`DOC\docs\quick-start\advanced\dc.md:44-54`）。**注意「写成功」只是派发成功**：`ConfigureDC` 返回 true 时硬件可能还没写（门关着就延后），必须读回 `DcSync0CycleNs` 确认 |
| `slave[n].startup.*` | 启动 SDO 列表 | `["INIT","PRE_OP"]` | `nextTransition` | 写错启动参数 → 在 `IP/PS/SO` 转换时被从站以 `0x08000022`（当前设备状态不允许）拒绝，整段转换连败；写坏设备参数 → 设备行为异常 | 删掉该条 / 改回原值；必要时用设备自己的恢复出厂对象 | 参数表本身是**纯托管列表**，`Add/Remove` 无状态门（`CSharp\Master\Slave\Startup.cs:540-620`）；真正执行在各状态转换：默认时机 `IP/PS/SO/OS/SP/PI` 见 `Startup.cs:130-152`。执行期被拒的实测：`core\config\highlevel.c:599-604` |
| `slave[n].pdo.output` | bytes | `["OP"]` | `nextCycle` | **非 OP 写进去不会报错，但会留在过程映像里**，等进 OP 第一拍原样发给从站——如果那是上一次的目标位置/控制字，使能瞬间就动 | 立刻写安全值（目标=实际、控制字=安全态），再复查 | **原生没有任何状态门**：`WriteSlaveOutputPdo` 只校验「长度 == `Obytes`」和从站号，然后把数据 memcpy 进输出映像（`core\state\state_machine.c:23653-23725`，长度校验 `:23711-23713`，memcpy `:23716`）。正因为没门，契约才把它收紧到「仅 OP」。API：`slave.PDO.Outputs`（`CSharp\Master\Slave\SlavePdo.cs:78-103`）、`WriteOutputPdo`（`Slave\PDO.cs:296-332`） |

### 2.4 只能走 SDO 通道的项（不在 `query:writable` 能力表里）

这几项没有 `path`：能写的走 `slave.CoE.SDOWrite(...)`，不能写的（SM/FMMU）只能改配置重建。
**状态判据照旧成立**，写错一样会把从站搞掉。

| 项 | 对象 | 允许状态 | 生效时机 | 改错的后果 | 回退办法 | 出处 |
|---|---|---|---|---|---|---|
| PDO 映射 | `0x1600–0x17FF`（Rx）/ `0x1A00–0x1BFF`（Tx） | **只 PRE_OP** | `nextTransition`（下一次 PreOp→SafeOp） | 在 SafeOp/OP 写 `0x1C12/0x1C13` → 从站 abort `0x08000022`；映射长度/顺序错 → AL `0x001D/0x001E/0x0024/0x0025`，停在 SafeOp 进不了 OP；**字节数对但顺序错不报错，读到的就是错位数据** | 重新按正确顺序写一遍，或从 DENI/ESI 重新加载 | `DOC\docs\ethercat\device-profiles\coe.md:288-313`（完整 PreOp 重映顺序）；AL 码 `DOC\docs\faq\error-codes.md:84-87`；结构体顺序约束 `DOC\static\ai-prompts.txt:330-347` |
| SM 配置（SM0–SM3 寄存器 + FMMU） | 由主站按 ESI/PDO 分配自动写，**没有用户 SDO 入口** | **不可在线改**（改了必须重建） | `nextBuild` | SM 大小/方向与从站不符 → AL `0x0017`，从站停在 PreOp/SafeOp；FMMU 逻辑地址错 → 过程数据整体错位（不报错） | 把 PDO 分配改回 ESI/DENI 的值，重建主站 | `DOC\docs\ethercat\beginner-guide\sm-fmmu.md:113-120`（`PREOP → SAFEOP` 时自动配置）；AL 码 `DOC\docs\faq\error-codes.md:81` |
| 普通从站参数（如 CiA 402 的 `0x607A` / `0x6060`） | 任意可写对象 | `PRE_OP` 最稳；`SAFE_OP/OP` **要看从站** | `immediate` | 在 OP 写不进去 → abort `0x08000022`（「SafeOp/OP 邮箱已死」是实测存在的一类设备：`core\ethercat\dc.c:5089`）；写错值 → 设备行为错（如模式切换失败） | 先读旧值再写，失败写回旧值；掉电保存类对象不要当测试对象 | 语义与 abort 判读见 `darra-ethercat-parameters` |

> **「OP 里到底能不能写 SDO」没有统一答案。** 有的伺服 OP 里照常响应 SDO，有的从站在 SafeOp/OP 邮箱已经不响应。
> **不要假设**：在 OP 里第一次写之前，先读一个只读对象（例如 `0x6041`）确认邮箱还活着；不行就降到 PRE_OP 写。

---

## 3. 三种下发方式（「尽可能减少修改」）

不要罗列 API。先判断这次改动属于哪一类。

### 3.1 单点写 —— 改一个独立字段

**判据**：这个字段的值不依赖别的字段，而且它的消费点不会因为「改了一半」而进入坏状态。

典型：`master.mailbox.timeoutMs`、`master.pdoFilterThreshold`、`master.diagnostics.enabled`、
`master.hotSwapAutoRescanEnabled`、`slave[n].pdo.output`。

```text
查 allowedStates → 写 → 读回（或看诊断字段）→ 记录
```

单点写也要**先记旧值**，否则失败时你连回滚成什么都不知道。

### 3.2 成组写 —— 几个值必须一起落地

**判据**：字段之间存在「中间态非法」的关系。

| 组 | 成员 | 为什么不能拆 |
|---|---|---|
| DC 武装 | `assignActivate` + `sync0CycleNs` + `sync1CycleNs` + `shiftNs` | 先写周期再写使能位，中间那一拍从站按**旧使能位 + 新周期**跑；反过来则按**新使能位 + 旧周期**跑。两种都是错节拍，都可能直接掉 OP |
| PDO 映射 | `0x1C12:00=0` → `0x1600:00=0` → 条目 → `0x1600:00=n` → `0x1C12:01` → `0x1C12:00=1` | 顺序错会写出「条目数已置位但条目还没写」的半套映射；并且只改 RxPDO 时**不要顺手清 `0x1C13`** |
| 启动 SDO 序列 | 同一对象的多步写（`SequenceId` + `SequenceStep`） | 中途插队会把后一步写在前一步之前；列表接口已经按序列标签区分，不要自己拼 |

DC 这一组在 SDK 里是**一次调用**完成的，并且是原子的——「要么全成要么全回滚，并留下失败原因与待生效意图」
（`CSharp\Master\Slave\DC.cs:1261-1266`，实现 `SwitchDcModeCore` `:1335`）。

```csharp
// 对：一次交出 SYNC0 / SYNC1 / 相位
slave.ConfigureDC(DcSyncMode.DcSynchron, sync0CycleNs: 1_000_000u, sync1CycleNs: 0u, shiftNs: null);

// 错：拆成两次，第二次没带周期 —— 默认 sync0CycleNs = 0，等于把刚配好的 SYNC0 又卸了
slave.ConfigureDC(1_000_000u);
slave.ConfigureDC(DcSyncMode.DcSynchron);   // sync0 默认 0 → 卸下武装
```

### 3.3 不该在线改 —— 改 DENI / 工程文件，再重连

**判据**（命中任一条就别在线改）：

- 改的是 **PDO 映射的内容或条数**，而你的程序已经用固定结构体 / 固定 `Ibytes`、`Obytes` 在读这份数据。
  映射一变，程序侧结构体也得跟着变，在线改等于让两侧对不上。（如果只是停机重配、程序侧同步改，那就按 2.4 在 PRE_OP 做。）
- 改的是 **SM 配置 / PDO 字节数**（这两项由主站按 ESI 自动写，没有在线改的入口）。
- 改的是**拓扑**（增删从站、换型号、换接线顺序）。
- 你**无法把主站安全降到 PRE_OP**（例如产线正在跑，不允许停）。
- 改完需要「同时换周期 + 换 DC 相位 + 换映射」——这已经不是改参，是换配置。

正确做法：改 DENI / 工程文件 → 停机 → 重新 `SetENI(...).Build()` → 重新走投产验收。
DENI 必须由真实扫描导出，不要手改正文（`darra-ethercat-commissioning` 第 10 步）。

### 3.4 改完怎么验证真的生效了

**按 `applyTiming` 选验证方式。只看返回值 = 没验证。**

| applyTiming | 含义 | 怎么验证 | 为什么不能只看返回值 |
|---|---|---|---|
| `immediate` | 立即（下一个事务/下一次读取就变） | 读回同一路径；纯托管字段（如 `mailbox.timeoutMs`）读回同值即可 | 原生 void 入口失败也返回 void |
| `nextCycle` | 下个周期（或下一拍） | 看诊断字段/过程数据的变化（如 `pdo.output` → 读 `Inputs` 看从站反馈的状态字/实际值） | 写进映像 ≠ 已发出；周期线程没跑就永远不到总线上 |
| `nextTransition` | 下次状态转换 | **必须真做一次转换**，再读落地镜像：`slave.DcSync0CycleNs` / `slave.DcAssignActivate` / `slave.Sync0Armed`；看门狗用 `slave.GetWatchdogConfig()` 读回实际毫秒 | DC 的 `ConfigureDC` 返回 true 只代表「已派发」，门关着时硬件根本没写 |
| `nextBuild` | 下次构建主站 | 重新 `Build()` 之后，从新实例读 | 这些字段在帧构建/`SetNetwork` 时才被消费 |

再加三条通用判据：

1. **看 AL 码**：转换后逐站 `slave.AlStatusCode == 0`，且 `slave.State == EcState.OP`。
2. **看 WKC**：`master.Diagnostics.WKC == master.Diagnostics.ExpectedWKC`，且 `ExpectedWKC != 0`。
3. **看诊断/日志里的「请求 vs 实际」**：看门狗会打印「请求 X ms，实际下发 Y ms」，`X != Y` 就是被安全下限抬了。

---

## 4. 拒绝码与处置

### 4.1 能力查询：`query:writable`

用户程序不该硬编码「什么状态能改什么」，应该问一次、缓存、在写之前再核对。回执 `data`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `protocol` | string | 固定 `"DARRAGUI-CLI-1"` |
| `entries` | 能力项[] | 见下表 |
| `stateVocabulary` | string[] | `["NONE","INIT","PRE_OP","BOOT","SAFE_OP","OP"]` |
| `currentState` | string | 当前主站状态（取值同上） |
| `currentStateSource` | string | `live` / `cached` / `not_measured` |
| `sampledAtMs` | long | 快照时刻 |

能力项字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `path` | string | 如 `master.loopCycle` / `slave[3].dc.sync0CycleNs` / `slave[3].pdo.output` |
| `group` | string | `master` / `slave` / `pdo` |
| `type` | string | `uint` / `int` / `bool` / `string` / `bytes` |
| `unit` | string | `ns` / `ms` / `count` / `""` |
| `writable` | bool | 只读项在这里就是 `false` |
| `allowedStates` | string[] | `["INIT"]…` 或 `["ANY"]` |
| `applyTiming` | string | `immediate` / `nextBuild` / `nextCycle` / `nextTransition` |
| `currentValue` | 任意 / null | 当前值 |
| `currentSource` | string | `live` / `cached` / `configuration` / `not_measured` |
| `min` / `max` | number / null | 取值范围 |
| `notes` | string | 该字段的坑（例如「改了不生效」「Windows 无效果」） |

写入入口：`--write <path>=<value>`（可重复）；`--set` 作为五个常用键的别名并存。

### 4.2 拒绝回执（固定形状）

```json
{"ok":false,"reason":{"code":"STATE_NOT_ALLOWED","detail":"..."},
 "data":{"path":"slave[3].dc.assignActivate","currentState":"OP",
         "allowedStates":["INIT","PRE_OP"],
         "hint":"先切到 PRE_OP 再改 DC 参数"}}
```

### 4.3 reason 码表

| code | 含义 | 怎么办 |
|---|---|---|
| `STATE_NOT_ALLOWED` | 当前状态不在 `allowedStates` 里 | 按 `data.hint` 先切状态。**切之前先算好回退**：切下去以后现场是停的，改完必须能切回来 |
| `PATH_UNKNOWN` | 路径不在能力表里（拼错、或该版本没收录） | 用 `query:writable` 拉全表核对路径拼写；不要猜字段名。注意：PDO 映射 / SM / 普通 SDO **本来就不在能力表里**，它们走 `slave.CoE.SDOWrite`，不是写回接口 |
| `PATH_READONLY` | 该路径存在但不可写 | 常见于 `master.mailbox.retryCount`、`master.mutexProtection`、以及所有 `DcAssignActivate` 这类落地镜像。看 `notes` 找替代写法（例如 DC 用 `ConfigureDC(mode,...)`） |
| `VALUE_OUT_OF_RANGE` | 值不合法 | 看 `data.min` / `data.max`，**不要自己截断后重试**（原生明确「设多少下发多少、超限拒绝、不静默夹取」） |
| `WRITE_VERIFY_FAILED` | 写成功但读回不一致 | 立刻回退到写之前的值；然后判断是不是 `applyTiming` 没到（`nextTransition` 的字段在转换前读回当然是旧值） |
| `SIGNATURE_BROKEN` | 改的是已签名 DENI，正文变了签名失效 | 有签名私钥就重签；没有就**不要输出「正文已改、签名是旧的」文件** |

**旧草案码与本表的对应**（避免看到别处的文档时对不上）：

| 旧码 | 现状 |
|---|---|
| `MASTER_NOT_BUILT` | 归入 `STATE_NOT_ALLOWED`，`data.currentState` = `"NONE"` |
| `REQUIRES_RESCAN` | 不是写拒绝码。需要重建主站的改动看 `applyTiming = nextBuild`，由调用方自己重建，不在这里拒绝 |

---

## 5. 安全下发流程

### 5.1 伪代码（所有字段通用）

```text
1. 读当前状态           master.State（NONE 就停：主站没建）
2. 查允许矩阵           query:writable → 找 path → 看 allowedStates / writable / applyTiming / min / max
3. 值本身校验           类型、范围、单位（ns / ms / count）不要搞混
4. 不满足状态 → 先切    记录原状态 → SetState(允许状态) → 确认真的到了
5. 记旧值               用于回滚（读不到旧值就不要写）
6. 写                   单点写 or 成组一次写
7. 读回验证             按 applyTiming 选验证方式（见 3.4）
8. 看诊断               AL 码、WKC、Sync0Armed
9. 恢复状态             切回原状态 → 确认全站在 OP
10. 记录                改了什么、从什么改成什么、什么时候、结果
```

### 5.2 C# 示例（用户程序里的写法）

下面这段是**用户程序里的一个常驻服务类**，不是演示脚本：有前置状态检查、读回验证、失败回滚、日志。
只用到真实存在的 API。

```csharp
using System;
using System.Linq;
using DarraEtherCAT_Master;   // DarraEtherCAT / EcState / DcSyncMode / SdoReadResult / SdoWriteResult

namespace YourApp.Runtime
{
    /// <summary>
    /// 在线改参入口：只负责「能不能改 / 怎么改才不炸 / 改完怎么确认」。
    /// 改什么值、什么时候改，由上层配方/工艺逻辑决定。
    /// </summary>
    public sealed class OnlineParameterWriter
    {
        private readonly DarraEtherCAT _master;
        private readonly Action<string> _log;
        private readonly object _gate = new object();   // 同一时刻只允许一个改参动作

        public OnlineParameterWriter(DarraEtherCAT master, Action<string> log)
        {
            _master = master ?? throw new ArgumentNullException(nameof(master));
            _log = log ?? (_ => { });
        }

        /// <summary>
        /// 改 PDO 周期。周期只能在「全站 INIT/PRE_OP」窗口改；OP 下必须先降到 PRE_OP。
        /// 成功后恢复原来的状态；任一步失败都回滚到旧周期。
        /// </summary>
        public bool TryChangeLoopCycle(uint newCycleNs, out string error)
        {
            error = null;
            lock (_gate)
            {
                if (_master.State == EcState.None)
                {
                    error = "主站未构建（State=None）";
                    return false;
                }
                if (newCycleNs == 0 || newCycleNs % 1000u != 0)
                {
                    error = $"周期必须是整数微秒（当前 {newCycleNs} ns）";
                    return false;
                }

                EcState original = _master.State;
                bool needRestore = false;

                if (original != EcState.Init && original != EcState.PreOp)
                {
                    if (!_master.SetState(EcState.PreOp, out string downError))
                    {
                        error = $"降到 PRE_OP 失败: {downError}";
                        _log($"[writeback] 改周期中止：{error}");
                        return false;
                    }
                    needRestore = true;
                }

                uint oldCycle = _master.Config.LoopCycle;
                try
                {
                    _master.Config.LoopCycle = newCycleNs;

                    // 读回：LoopCycle 的 getter 直接读 native 状态头，不会回显你写进去的值
                    uint readBack = _master.Config.LoopCycle;
                    if (readBack != newCycleNs)
                    {
                        _master.Config.LoopCycle = oldCycle;
                        error = $"读回不一致：期望 {newCycleNs} ns，实读 {readBack} ns（旧值已写回）";
                        _log($"[writeback] 改周期失败：{error}");
                        return false;
                    }

                    _log($"[writeback] LoopCycle {oldCycle} → {newCycleNs} ns");
                    return true;
                }
                catch (Exception ex)
                {
                    // 原生拒绝时托管层不一定抛（多数是记日志保持原值），所以这里只兜真异常
                    error = $"写 LoopCycle 异常: {ex.GetType().Name}: {ex.Message}";
                    _log($"[writeback] {error}");
                    try { _master.Config.LoopCycle = oldCycle; } catch (Exception) { /* 已在错误路径 */ }
                    return false;
                }
                finally
                {
                    if (needRestore)
                    {
                        if (!_master.SetState(original, out string upError))
                            _log($"[writeback] 恢复状态到 {original} 失败: {upError}（现场需人工确认）");
                    }
                }
            }
        }

        /// <summary>
        /// 写一条从站 SDO 参数：先读旧值 → 写 → 读回比对 → 不一致写回旧值。
        /// 适用：CiA 402 参数、厂商参数。不适用于 PDO 映射（那要先降到 PRE_OP 走映射序列）。
        /// </summary>
        public bool TryWriteSlaveParameter(int slaveNo, ushort index, byte subIndex,
                                           byte[] data, out string error)
        {
            error = null;
            lock (_gate)
            {
                if (_master.State == EcState.None)
                {
                    error = "主站未构建（State=None）";
                    return false;
                }
                if (slaveNo <= 0 || _master.Slaves == null || slaveNo > _master.Slaves.Count)
                {
                    error = $"从站号越界: {slaveNo}";
                    return false;
                }

                var slave = _master.Slaves[slaveNo - 1];   // Slaves 是 0 基数组，SlaveNum 是 1 基
                var coe = slave?.CoE;                       // CoE 是公开字段，可能是 null
                if (coe == null)
                {
                    error = $"从站 {slaveNo} 没有 CoE 邮箱";
                    return false;
                }

                // 1) 先读原值：既确认对象可读，也拿到回滚值
                byte[] before = coe.SDORead(index, subIndex, out SdoReadResult readDetail);
                if (before == null)
                {
                    error = $"读原值失败 0x{index:X4}:{subIndex:X2} abort=0x{readDetail.AbortCode:X8} wkc={readDetail.Wkc}";
                    _log($"[writeback] {error}");
                    return false;
                }

                // 2) 写
                if (!coe.SDOWrite(index, subIndex, data, out SdoWriteResult writeDetail))
                {
                    error = $"写失败 0x{index:X4}:{subIndex:X2} abort=0x{writeDetail.AbortCode:X8} wkc={writeDetail.Wkc}";
                    _log($"[writeback] {error}");
                    return false;   // 写失败时设备侧未改动，无需回滚
                }

                // 3) 读回比对 —— 「返回 true」不等于「值进去了」
                byte[] after = coe.SDORead(index, subIndex, out SdoReadResult verifyDetail);
                if (after == null || !after.SequenceEqual(data))
                {
                    _log($"[writeback] 从站 {slaveNo} 0x{index:X4}:{subIndex:X2} 读回不一致，写回旧值");

                    if (!coe.SDOWrite(index, subIndex, before, out SdoWriteResult rollbackDetail))
                        error = $"读回不一致，且回滚失败 abort=0x{rollbackDetail.AbortCode:X8}（设备可能处于中间态）";
                    else
                        error = "读回不一致，已回滚到原值";
                    return false;
                }

                _log($"[writeback] 从站 {slaveNo} 0x{index:X4}:{subIndex:X2} 写入并读回确认");
                return true;
            }
        }

        /// <summary>
        /// 成组改 DC：给 SYNC0 周期与相位。这几个值必须一次交出，不能分三次写。
        /// 返回 true 只代表「已派发」；要确认武装成功，必须在进 OP 之后再读 Sync0Armed。
        /// </summary>
        public bool TryApplyDc(int slaveNo, uint sync0CycleNs, int? shiftNs, out string error)
        {
            error = null;
            lock (_gate)
            {
                if (_master.State == EcState.None)
                {
                    error = "主站未构建（State=None）";
                    return false;
                }

                EcState original = _master.State;
                bool needRestore = false;
                if (original != EcState.Init && original != EcState.PreOp)
                {
                    if (!_master.SetState(EcState.PreOp, out string downError))
                    {
                        error = $"降到 PRE_OP 失败: {downError}";
                        return false;
                    }
                    needRestore = true;
                }

                try
                {
                    var slave = _master.Slaves[slaveNo - 1];
                    int? oldCycle = slave.DcSync0CycleNs;   // 落地镜像，用来判断到底写没写

                    if (!slave.ConfigureDC(DcSyncMode.DcSynchron, sync0CycleNs, 0u, shiftNs))
                    {
                        error = $"从站 {slaveNo} DC 配置未派发";
                        _log($"[writeback] {error}");
                        return false;
                    }

                    // 派发成功 ≠ 已落地：写门关着时原生只登记意图、不写 0x0980/0x09A0
                    int? landed = slave.DcSync0CycleNs;
                    if (landed != (int)sync0CycleNs)
                    {
                        error = $"DC 未落地：期望 SYNC0={sync0CycleNs} ns，镜像=" +
                                (landed.HasValue ? $"{landed.Value} ns" : "读不到") +
                                "（多半是全站没都在 PRE_OP，写门未开）";
                        _log($"[writeback] {error}");

                        if (oldCycle.HasValue)
                            slave.ConfigureDC((uint)Math.Max(oldCycle.Value, 0), 0u, null);  // 尽力回滚
                        return false;
                    }

                    _log($"[writeback] 从站 {slaveNo} SYNC0={sync0CycleNs} ns 已落地" +
                         (needRestore ? "；请在恢复 OP 后复查 Sync0Armed" : ""));
                    return true;
                }
                catch (Exception ex)
                {
                    error = $"DC 配置异常: {ex.GetType().Name}: {ex.Message}";
                    _log($"[writeback] {error}");
                    return false;
                }
                finally
                {
                    if (needRestore && !_master.SetState(original, out string upError))
                        _log($"[writeback] 恢复状态到 {original} 失败: {upError}（现场需人工确认）");
                }
            }
        }

        /// <summary>进 OP 之后的最终确认：SYNC0 真的武装了、没掉站。</summary>
        public bool VerifyDcArmed(int slaveNo, out string error)
        {
            error = null;
            var slave = _master.Slaves[slaveNo - 1];

            bool? armed = slave.Sync0Armed;          // 三态：true 已武装 / false 有判据的未武装 / null 读不到
            if (armed != true)
            {
                error = armed.HasValue
                    ? $"从站 {slaveNo} 未武装 SYNC0（Sync0Armed=false）"
                    : $"从站 {slaveNo} 的 Sync0Armed 读不到（不能当成未武装，也不能当成已武装）";
                return false;
            }

            if ((ushort)slave.AlStatusCode != 0 || slave.State != EcState.OP)
            {
                error = $"从站 {slaveNo} 状态异常: State={slave.State}, AL=0x{(ushort)slave.AlStatusCode:X4}";
                return false;
            }
            return true;
        }
    }
}
```

**这段代码刻意没做的事**（都是坑）：

- 没有在 OP 里直接改 DC 或周期——先降 PRE_OP。
- 没有把 `ConfigureDC` 的 `true` 当成「已生效」——读 `DcSync0CycleNs` 落地镜像。
- 没有在写失败时「重试三次碰运气」——邮箱/状态类失败重试会掩盖真因。
- 没有并发保护之外的队列——同一时刻只允许一个改参动作，避免两个线程交叉写同一个组。

---

## 6. 技能体边界

- **不替用户决定工艺参数值**：PID 增益、限位、目标速度、加减速、转矩限幅该设多少，是用户工艺的事。本文只保证「你决定要改的时候，不会因为时机/顺序/组合不对把从站搞掉」。
- **不替用户设计应用层逻辑**：什么时候该调参、配方怎么管、什么时候允许停机切 PRE_OP，都是用户程序自己的事。本文给的是**约束与判据**，不是流程模板——你的程序结构可以完全不一样（状态机、队列、事件驱动都行），只要遵守矩阵里的状态门、成组约束和验证判据。
- **不做参数整定**：不会告诉你「周期设 1 ms 还是 2 ms 更好」。只会告诉你「周期必须是整数微秒、在 31–10000 µs 内、和 DC 的 SYNC0 要成整数倍」。
- **不替代投产验收**：改完后的 WKC / 全站 OP / DC in-sync 验收标准在 `darra-ethercat-commissioning` 第 9 步。

---

## 7. 不要生成的写法

- 不看状态直接写 DC / 周期（`slave.ConfigureDC(...)` 在 OP 里调用看起来「成功」，其实没写）
- 把 `ConfigureDC` / `SDOWrite` 的返回值当成「已生效」
- 分开三次写 `assignActivate` / `sync0` / `shift`
- 在 OP 里改 PDO 映射 / SM 配置
- 在 `SAFE_OP` / 非 OP 状态写 `slave.PDO.Outputs`
- 写失败后 `catch { }` 吞掉，或无限重试
- 写之前不读旧值（失败时无法回滚）
- 自己给 `RetryCount` / `MutexProtection` 赋值并以为生效了
- 写 `master.frameHighPriority` 以为在 Windows 上能提升帧优先级
- `master.hotSwapAutoRescanIntervalMs = 10` 后以为真的是 10 ms（会被夹到 100）
- 把 `DcAssignActivate` 当可写属性（它是只读落地镜像）
- 手改 DENI 正文去「在线改配置」
- 只凭 `ok:true` 就记录「改好」（必须按 `applyTiming` 做读回/转换后验证）

---

## 8. 出处

### 8.1 状态与写门

| 事实 | 出处 |
|---|---|
| `EcState` 枚举（None/Init/PreOp/Boot/SafeOp/OP，0x10=Error 位） | `ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Data\Type.cs:28-44` |
| `master.State`（未建站返回 `None`） | `...\CSharp\Master\State.cs:477-487` |
| `master.SetState(EcState, out string)` | `...\CSharp\Master\State.cs:3489` |
| 原生主站配置写门（逐站 fresh 实测，全在 INIT/PRE_OP 才放行） | `ETH\Darra_EtherCAT_Drive\main\core\config\config_common.c:1580-1655`（判据 `:1649`） |
| DC 专用写门（同上语义，另一份实现） | `...\core\dc\dc_sync.c:624-700` |
| 托管侧 DC 重放门（只认 PreOp，INIT fail-closed） | `...\CSharp\Master\Slave\DC.cs:1020-1045` |

### 8.2 主站级字段

| 字段 | 出处 |
|---|---|
| `LoopCycle`（托管 setter / 转换中跳过 / 原生入口） | `...\CSharp\Master\Core.cs:1756-1832`（跳过门 `:1793`）；`config_common.c:17142-17260`；门限 `diagnostics.c:3962,3965` |
| `DcCycle`（DC 已武装拒绝换时基） | `...\CSharp\Master\Core.cs:1835-1867`；`config_common.c:17026` |
| 三档转换超时 | `...\CSharp\Master\MasterConfig.cs:454,487,519`；读取点 `core\state\state_machine.c:6023-6025`；30 min 上限 `:6030-6036` |
| PD / PDI 看门狗 | `MasterConfig.cs:375-446`；下发点 `core\base\events.c:25589,25874`；`core\config\config_startup.c:10252-10254,16610-16705` |
| 看门狗安全下限抬高（分支 5000 / 环 400） | `config_startup.c:16613-16620,16660-16705` |
| `MailboxConfig.TimeoutMs`（真接线） | `MasterConfig.cs:355-373,685-696`；`...\Master\Abstractions\MailboxTransaction.cs:40-81` |
| `MailboxConfig.RetryCount`（不生效，ERROR 日志） | `MasterConfig.cs:698-723`（日志 `:716-720`） |
| `FilterThreshold`（默认 3，0→3） | `MasterConfig.cs:261-291`；`core\base\events.c:2794,12086` |
| 热插拔自动重扫（默认 1000，夹紧 100–60000） | `...\Master\MasterDiagnosticsInfo.HotSwapRescan.cs:26-30,41-68,70-90` |
| `Diagnostics.Enabled`（只关用户档） | `...\Master\MasterDiagnosticsInfo.cs:786-800`；`core\diagnostics\diagnostics.c:562-579` |
| `HighResolutionTimer` | `MasterConfig.cs:52-59`；`Core.cs:1869-1876` |
| `FrameHighPriority`（Windows 未实现） | `MasterConfig.cs:63-91`；`core\state\state_machine.c:5571,5598` |
| `UseUdp`（运行时切换 + socket 就绪前提） | `MasterConfig.cs:93-126`；`core\protocol\udp_support.c:63-95` |
| `VlanId` / `VlanPriority`（SetNetwork 前、仅 WDK） | `MasterConfig.cs:128-195`；发送侧 `state_machine.c:21125-21136` |
| `OverlappingGroups` / `PackedMode`（仅 INIT/PRE_OP） | `MasterConfig.cs:199-259`；帧构建 `state_machine.c:17105-17112` |
| `FrameRepeatCount`（1–3，每周期读） | `MasterConfig.cs:295-324`；`core\base\events.c:13653,14238` |
| `MutexProtection`（固定启用，拒绝关闭） | `MasterConfig.cs:326-346`；`core\state\state_machine.c:24649-24663` |

### 8.3 从站级字段

| 字段 | 出处 |
|---|---|
| `ConfigureDC(uint,uint,int?)` / `ConfigureDC(DcSyncMode,...)` | `...\CSharp\Master\Slave\DC.cs:1102,1277,2398,2477` |
| DC 模式切换原子化（全成或全回滚 + 待生效意图） | `DC.cs:1261-1266,1335`；重放 `:976-1018,2533` |
| 相位优先级（ESI → 用户显式 → 70%） | `DC.cs:1085-1097`；`DOC\docs\quick-start\advanced\dc.md:44-54` |
| `DcAssignActivate`（只读镜像，不是写属性） | `DC.cs:2011-2027` |
| `DcSync0CycleNs` / `DcSync1CycleNs`（落地镜像） | `DC.cs:2028-2050` |
| `Sync0Armed`（三态） | `DC.cs:1710-1730` |
| ESI 声明的 AssignActivate | `...\CSharp\Master\Slave\Core.cs:372-400` |
| SYNC1 能力位（AssignActivate bit10 = 0x0400） | `Slave\Core.cs:759-770` |
| 启动 SDO 列表（纯托管 Add/Remove） | `...\CSharp\Master\Slave\Startup.cs:540-620` |
| 启动 SDO 各转换的默认写入时机 | `Startup.cs:130-152` |
| 启动 SDO 在错误状态被 `0x08000022` 拒 | `core\config\highlevel.c:599-604`；首次进入 PreOp 前应用 `:208` |
| `slave.PDO.Outputs` / `WriteOutputPdo` | `...\CSharp\Master\Slave\SlavePdo.cs:78-103`；`Slave\PDO.cs:296-332` |
| 输出写入**无状态门**（只校验长度，memcpy 进映像） | `core\state\state_machine.c:23653-23725`（长度 `:23711-23713`，memcpy `:23716`） |
| 输出短于/长于 `Obytes` → `SIZE_MISMATCH` | `state_machine.c:23711-23714`；`Obytes` 定义 `...\CSharp\Master\Slave\Core.cs:2744` |
| SDO 读写 detail 重载 | `...\CSharp\Master\Slave\CoE.cs:2320,2333,7230,7244` |
| `SdoReadResult` / `SdoWriteResult`（AbortCode / Wkc / ExpectedWkc） | `...\CSharp\Master\Data\Type.cs:574-633` |
| `slave.CoE` 是可为空的公开字段 | `...\CSharp\Master\Slave\Core.cs:144` |

### 8.4 文档

| 事实 | 出处 |
|---|---|
| 改 PDO 映射必须在 PreOp + 完整顺序 | `DOC\docs\ethercat\device-profiles\coe.md:282-313`（关键行 `:288`） |
| AL 0x0017 / 0x001D / 0x001E / 0x0024 / 0x0025 含义 | `DOC\docs\faq\error-codes.md:81,84,85,86,87` |
| AL 0x001A / 0x002D / 0x0034（同步类） | `DOC\docs\faq\error-codes.md:82,88,89` |
| SafeOp/OP 邮箱已死的实测（abort 0x08000022） | `ETH\Darra_EtherCAT_Drive\main\core\ethercat\dc.c:5089` |
| OP 中不重写 0x0980（会打乱 PLL） | `...\core\ethercat\dc.c:5097-5100` |

---

## 9. 查不到出处、只能推断的项（如实列出）

1. **`slave[n].dc.assignActivate` 是只读路径**：2.13.16 的 `query:writable` 明确给 `writable:false`（镜像 `Slave.DCActive`）。
   写 DC 用可写的 `slave[n].dc.mode`（背后是 `ConfigureDC(DcSyncMode, ...)`），单独的 assignActivate 写入会回 `PATH_READONLY`。
2. **`master.loopCycle` 契约只开 `INIT`**：原生写门实际接受 `INIT` + `PRE_OP`（`config_common.c:1649`）。实测 `query:writable` 给的就是 `["INIT"]`，把原生门如实写进「注意」列。**没有找到「契约为什么收紧到 INIT」的设计说明**，这是推断（更保险的配置窗口）。
3. **`master.vlanId` / `vlanPriority` 在 2.13.16 是只读**：`query:writable` 给 `writable:false`（notes 写「setter 只改共享内存，native 仅在 SetNetwork 建 socket 时消费」）。所以不是「INIT + nextBuild」，是根本不能在线写 —— 要改只能改 DENI / 重建。
4. **`slave[n].startup.*` 归到 `INIT/PRE_OP`**：启动 SDO 本身是纯托管列表，任何时候都能改；真正执行在各状态转换（`highlevel.c:208,599-604`）。「INIT/PRE_OP」是按「有效窗口」而非「写入被拒」推断的。
5. **`slave[n].pdo.output` 在非 OP 写入后的最终去向**：原生只 memcpy 进过程映像、无状态门（`state_machine.c:23716`）。
   「进 OP 第一拍会原样发出去」是按「周期线程发的是这份映像」推断的，**没有找到一条写着这句话的代码或注释**。
6. **`master.dcCycle` 的允许状态**：实测 2.13.16 `query:writable` 给 `["INIT"]` + `nextCycle`（不是 `INIT/PRE_OP` + `nextTransition`）。
7. **`query:writable` 已实现**（2.13.16 实测）：命令入口在 `Darra_EtherCAT_Master\命令通道\命令路由.动作.cs:1317`，写回执行在 `无头写回`；
   未建站时回 `NOT_CONNECTED`，建站后返回 52 项能力表（含 `allowedStates` / `applyTiming` / `currentValue` / `notes`）。
   `act:write` 支持 `path` / `value` / `valueB64` / `verify=0|1`。
8. **`processDataWatchdogMs` 的具体安全下限规则**：分支站 5000 ms / 环上 PDO 站 400 ms 来自源码注释（`config_startup.c:16613-16620`），
   但「哪些站算分支、哪些算环上 PDO」的判定在拓扑分类里，本文未展开；写死这些数字前请以 `GetWatchdogConfig()` 读回值为准。
