---
name: darra-ethercat
description: >
  写 Darra EtherCAT 主站程序时使用。覆盖 C#、Java、Python、C、C++、Rust：
  DENI 初始化、进 OP、PDO 映射、SDO、CiA 402、DC。写代码前先读
  https://ethercat.darra.xyz/ai-prompts.txt ，API 以那份为准，不要另造接口。
  触发词：EtherCAT、Darra、DENI、进 OP、CiA 402、CiA402、CSP、CSV、CST、写主站、主站程序、PDO、SetState、扫从站。
---

# Darra EtherCAT

写主站程序时用这份 skill。没写在这里、也没写在下面那份规则文件里的安装器、端口、接口，不要编。

## 先读规则

生成或修改代码之前，读取：

https://ethercat.darra.xyz/ai-prompts.txt

API 名称、初始化顺序、状态机、PDO、SDO、CiA 402、DC、扫描结论，都以这份为准。读不到就停，不要凭记忆补接口。

文档：

- C# https://ethercat.darra.xyz/doc/sdk/csharp
- Java https://ethercat.darra.xyz/doc/sdk/java
- Python https://ethercat.darra.xyz/doc/sdk/python
- C https://ethercat.darra.xyz/doc/sdk/ccpp
- C++ https://ethercat.darra.xyz/doc/sdk/cpp
- Rust https://ethercat.darra.xyz/doc/sdk/rust
- 下载 https://ethercat.darra.xyz/doc/downloads
- 从 SDK 开始 https://ethercat.darra.xyz/doc/quick-start/from-sdk

用户没指定语言时用 C#。

## 安装

SDK 包：

- C#：`dotnet add package Darra.EtherCAT.Master`，`using DarraEtherCAT_Master;`
- Java：Maven `xyz.darra:darra-ethercat-master`，JDK 11+。依赖按包内说明引入。
- Python：`pip install darra-ethercat-master`（Python 3.12，64 位）。`from darra_ethercat import EtherCATMaster, EcState`
- C：`darra_ethercat_c-win-x64.zip`，`#include "ethercat.h"`
- C++：`darra_ethercat_cpp-win-x64.zip`，`#include "ethercat.hpp"`，C++17
- Rust：`darra-ethercat-master.crate`，不在 crates.io。解出后用 path 依赖。Rust 1.70+

语言包地址在下载页，不要另造链接。

驱动只走官方安装包，一个 exe，不单独下驱动：

https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe

说明页：https://ethercat.darra.xyz/doc/downloads

已装过旧版：先卸载，重启，再装新版。装完建议再重启一次。不要跳步。

静默安装只用安装包自己的参数：`--silent --install` 或 `--silent --uninstall`，可选 `--path DIR`、`--no-rt-optimize`、`--rt-masters 1..4`。`--rt-masters` 缺值、不是整数或超出 1 到 4，直接失败，不要改成 1。

公开安装包是 Windows 的。Linux 未公开发布，不要写 Linux 安装命令。

不建议在日常开发机上装这个包做实验。

## 配置

DENI（`.deni` / `.xml`）是完整配置：网口、从站、PDO、DC、启动参数。配置工具导出。有 DENI 时不要再 `SetEsiFiles`。

没有 DENI 时才用 ESI，并打开自动启动配置。

## 初始化

C# 必须看 `result.Success`，不要只拿 `.Master`：

```csharp
var result = new DarraEtherCAT()
    .SetENI(@"config.deni")
    .Build();
if (!result.Success) { Console.WriteLine(result.Message); return; }
var master = result.Master;
```

`Build()` 只能调用一次。`SetENI` 和 `SetNetwork` 都写时，后写的网口生效。

其他语言入口：

- Java：`EtherCATMaster.create().setENI(path).build()`，看 `r.success`，再取 `r.master`
- Python：`EtherCATMaster().set_eni(path).build()`
- C++：`darra::EtherCATMaster master(dll);` 然后 `SetENI(path).Build()`
- Rust：`EtherCATMaster::builder().set_eni(path).build()?.master`
- C：`deni_load` → `Initialize` → `xml_apply_config` → `SetNetwork` → `SetStateSequence` → `Start`

细节以规则文件里的对照表为准，不要把 C# 的写法套到别的语言上。

## 扫描

要区分「没量到」和「实测空口」时用 `QuickScan` / `StandardScan`，不要用只有 0 和正整数的计数字段下结论。

`SlaveCount == null` 是没量到。`0` 是实测空口。空口只看 `NicScanState.EmptyBus` 或 `ScanOutcome.EmptyBus`。不要把 null 写成 0 站。

## 状态机

顺序是 Init → PreOp → SafeOp → OP。

```csharp
bool ok = master.SetState(EcState.OP, out string err);
```

C# 枚举是 `EcState.OP`，不是 `Operational`，也不是 `Run`。Rust 才是 `EcState::Operational`。

不要在外面再包一层重试。切换失败就报 `err`，不要改期望值凑成功。

SDO 从 PreOp 起可用。OP 里改 PDO 映射会被拒。

## PDO

C# 结构体必须是 `struct`，加上 `[StructLayout(LayoutKind.Sequential, Pack = 1)]`。

输入大小等于 `slave.Ibytes`，输出等于 `slave.Obytes`。字段顺序等于 DENI 里的 PDO 映射顺序。

```csharp
ref MyInput input = ref slave.PDO.InputsMapping<MyInput>();
ref MyOutput output = ref slave.PDO.OutputsMapping<MyOutput>();
```

`master.Slaves` 从 0 开始。事件里的 `slaveIndex` 从 1 开始，用 `Slaves[slaveIndex - 1]`。

`ProcessDataCyclicSync` 里只读写 PDO。不要在里面做 SDO、Sleep、文件、界面刷新、等锁。

CSP / CSV / CST 的目标值在这个回调里每周期写。不要在回调外写一次就算完。

事件不在 UI 线程。WinForms 用 `Invoke` / `BeginInvoke`，WPF 用 `Dispatcher`。

## SDO 与伺服

先判断 `slave.CoE`、`slave.CoE.CiA402` 是不是 null。

C# 读用 `.Value`。写用 `.Bytes` 或 `SDOWrite`，不要给 `.Value` 赋值。字节数必须对上寄存器宽度。

伺服在进 OP 之后调用一次 `Enable()`。不要放进同步回调。`Enable()` 只有到 OperationEnabled 才返回 true。故障先复位，不要把故障当成已使能。

`FaultReset()` 会阻塞。同步回调里用 `FaultResetStep(0)` 再 `FaultResetStep(1)`。

CSP / CSV / CST 要在 `SetState(OP)` 之前配 DC。`ConfigureDC` 的周期与 `Config.LoopCycle` 一致，或为其整数倍。

`shiftNs == null` 是没指定相位。`0` 就是 0，不要当成没写。

武装看 `slave.Sync0Armed`。null 是答不出来，不要写成 false。不要用 `0x0980 == 0x0300` 判断已武装。

## 退出

结束时调用 `master.Close()`。不调的话网卡不归还。

## 时序

1. `Build()`，并检查成功
2. 订阅事件
3. 设周期，配置 DC
4. `SetState(OP)`
5. `InitializePdoOffsets()`，再设操作模式
6. `Enable()` 一次
7. 在周期回调里写 PDO
8. `Close()`

## 不要生成的写法

- `Build().Master` 不检查 `result.Success`
- PDO 用 class，或大小、字段顺序和 DENI 不一致
- 同步回调里做 SDO、Sleep、打日志、刷新界面
- 事件下标不减 1
- CSP 目标位置只写一次
- 在 OP 之前 `Enable()`
- 自己再包一层状态切换重试
- 编造下载地址、包名、端口或安装步骤
