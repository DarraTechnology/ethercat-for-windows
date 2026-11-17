---
name: darra-ethercat
description: >
  写 Darra EtherCAT 主站程序时使用。覆盖 C#、Java、Python、C、C++、Rust：
  DENI 初始化、进 OP、PDO 映射、SDO、CiA 402、DC。C# 与 Python 各给一份完整可跑的骨架
  （选卡 → 建站 → 进 OP → 周期回调 → SDO → Close），其余四种语言给入口差异。
  写代码前先读 https://ethercat.darra.xyz/ai-prompts.txt ，API 以那份为准，不要另造接口。
  触发词：EtherCAT、Darra、DENI、进 OP、CiA 402、CiA402、CSP、CSV、CST、写主站、主站程序、
  PDO、SetState、扫从站、C# 主站、Python 主站、EtherCATMaster、DarraEtherCAT、LoopCycle、周期、ConfigureDC。
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
- Rust：`cargo add darra-ethercat-master`（crates.io 上就有）。离线环境用下载页的 `.crate` 源码包解出后走 path 依赖；`.zip` 是含运行库的完整树。Rust 1.70+

语言包地址在下载页，不要另造链接。

驱动只走官方安装包，一个 exe，不单独下驱动：

https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe

说明页：https://ethercat.darra.xyz/doc/downloads

已装过旧版：**直接再跑一次同一个安装包就是升级**，不用先卸载、不用先重启。安装器会按驱动状态自己处理已装版本（先停旧驱动，再删旧驱动与旧程序文件，然后装本次版本）。只有真的要卸掉时才走 `--silent --uninstall`。把升级拆成「卸载 → 重启 → 安装」三步是错的。

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

## C# 完整可跑

从选卡到退出，一份能直接编译运行的最小主站。缺的那一步往往是 `Close()`，别省。

```csharp
using System;
using System.Linq;
using System.Runtime.InteropServices;
using DarraEtherCAT_Master;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
struct InPdo  { public ushort StatusWord; public int ActualPosition; }

[StructLayout(LayoutKind.Sequential, Pack = 1)]
struct OutPdo { public ushort ControlWord; public int TargetPosition; }

class Program
{
    static void Main()
    {
        // 1. 选卡：挑有从站的那块（Name 形如 \Device\NPF_{GUID}）
        var nic = DarraEtherCAT.GetNetworkInfo(needSlavesNum: true)
            .FirstOrDefault(n => n.SlaveNum > 0);
        if (nic == null) { Console.WriteLine("没有扫到从站的网卡"); return; }

        // 2. 建主站：Build() 只能调一次，必须看 result.Success
        var result = new DarraEtherCAT()
            .SetENI(@"config.deni")     // DENI 由配置工具导出
            .SetNetwork(nic)            // 后写的网口生效
            .Build();
        if (!result.Success) { Console.WriteLine(result.Message); return; }

        DarraEtherCAT master = result;
        try
        {
            var slave = master.Slaves[0];          // master.Slaves 从 0 开始

            // 3. 周期与 DC：必须在 SetState(OP) 之前
            master.Config.LoopCycle = 1_000_000;   // 单位 ns，这里 1 ms
            master.ConfigureDC(1_000_000);         // 与 LoopCycle 一致或为其整数倍

            // 4. 进 OP
            if (!master.SetState(EcState.OP, out string err)) { Console.WriteLine(err); return; }

            // 5. 读身份对象：0x1018:01 是任何从站都有的 VendorID
            byte[] data = slave.CoE.SDORead(0x1018, 0x01);
            if (data == null) Console.WriteLine("SDO 读失败: " + slave.CoE.LastSdoError);
            else Console.WriteLine($"VendorID = 0x{BitConverter.ToUInt32(data, 0):X8}");

            // 6. 周期回调里只读写 PDO 字段
            bool aligned = false;
            int next = 0;
            master.Events.ProcessDataCyclicSync += (masterIndex) =>
            {
                ref readonly InPdo input = ref slave.PDO.InputsMapping<InPdo>();
                ref OutPdo output = ref slave.PDO.OutputsMapping<OutPdo>();

                if ((input.StatusWord & 0x6F) == 0x27)          // OperationEnabled
                {
                    if (!aligned) { next = input.ActualPosition; aligned = true; }
                    output.ControlWord = 0x000F;
                    output.TargetPosition = next;               // 每周期推进你的轨迹
                }
                else
                {
                    output.ControlWord = 0x0006;                // 未使能：停机命令
                    output.TargetPosition = input.ActualPosition; // 未使能时目标 = 实际
                    aligned = false;
                }
            };

            Console.WriteLine("运行中，回车退出");
            Console.ReadLine();
        }
        finally
        {
            master.Close();     // 必须：不调的话网卡不归还，下次绑定失败
        }
    }
}
```

`master.Start()` 在 C# 里可以省略：`SetState(OP)` 已经建立 PDO owner，再调一次按幂等返回 `true`
（六个 SDK 的 `Start()` 语义一致，重复调用不重复启动）。

## Python 完整可跑

包名与导入名是两个概念：`pip install darra-ethercat-master`，代码里 `import darra_ethercat`。
Python 3.12，64 位。

```python
import ctypes
from darra_ethercat import EtherCATMaster, EcState

class InPdo(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("status_word", ctypes.c_uint16),
                ("actual_position", ctypes.c_int32)]

class OutPdo(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("control_word", ctypes.c_uint16),
                ("target_position", ctypes.c_int32)]

with EtherCATMaster() as master:              # 退出 with 自动 close()
    master.set_eni("config.deni").build()     # DENI 由配置工具导出
    master.set_state(EcState.OP)
    master.start()                            # Python 要显式起 PDO 周期线程
    print(f"发现 {master.slave_count} 个从站")

    slave = master.slaves[0]
    vendor = slave.coe.sdo_read_value(0x1018, 0x01, dtype='u32')
    if vendor is None:
        print(f"SDO 读失败: {slave.coe.last_sdo_error}")
    else:
        print(f"VendorID = 0x{vendor:08X}")

    inputs = slave.pdo.inputs_mapping(InPdo)     # 进 OP 后映射一次
    outputs = slave.pdo.outputs_mapping(OutPdo)
    next_position = inputs.actual_position       # 轨迹起点 = 当前位置，不跳变

    def on_pdo_cycle(master_index):
        if (inputs.status_word & 0x6F) == 0x27:          # OperationEnabled
            outputs.control_word = 0x000F
            outputs.target_position = next_position      # 每周期推进你的轨迹
        else:
            outputs.control_word = 0x0006                # 未使能：停机命令
            outputs.target_position = inputs.actual_position

    master.on_pdo_cycle(on_pdo_cycle)   # 挂周期回调，不要自己起线程 sleep 自旋
    input("运行中，回车退出")
```

没有 DENI 时走 `master.set_network(r"\Device\NPF_{GUID}")`，它返回扫描到的从站数：
`0` 是实测空总线，网卡打开/绑定失败抛 `RuntimeError`，**不会折算成 0 个从站**。

## 语言入口对照

功能对齐，入口按各自语言惯例，**不要把 C# 的写法套到别的语言上**：

| 语言 | 装包 | 建主站 | 进 OP |
|---|---|---|---|
| C# | `dotnet add package Darra.EtherCAT.Master`，`using DarraEtherCAT_Master;` | `new DarraEtherCAT().SetENI(p).Build()` → 看 `result.Success` | `master.SetState(EcState.OP, out err)` |
| Python | `pip install darra-ethercat-master`，`from darra_ethercat import EtherCATMaster, EcState` | `EtherCATMaster().set_eni(p).build()`（`build()` 返回自身） | `master.set_state(EcState.OP)` + `master.start()` |
| Java | Maven `xyz.darra:darra-ethercat-master`（JDK 11+） | `EtherCATMaster.create().setENI(p).build()` → 看 `r.success`，`r.master` 是 `AutoCloseable` | `master.setState(EcState.OP)` + `master.start()` |
| C | `darra_ethercat_c-win-x64.zip`，`#include "ethercat.h"` | `Initialize` → `SetNetwork` → `deni_load` / `xml_apply_config` | `SetStateSequence(m, EC_STATE_OPERATIONAL, 10000)` → `Start(m)` |
| C++ | `darra_ethercat_cpp-win-x64.zip`，`#include "ethercat.hpp"`，C++17 | `darra::dll_t dll; darra::EtherCATMaster master(dll);` 再 `SetENI(p).Build()`（返回 bool） | `master.SetState(darra::EcState::OP)` → `master.Start()` |
| Rust | `cargo add darra-ethercat-master` | `EtherCATMaster::builder().set_eni(p).build()?.master` | `master.set_state(EcState::Operational)?` + `master.start()` |

Rust 枚举成员是 `EcState::Operational`，不是 `OP`；C# 反过来。这一条弄错编译就过不去。

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

C# 读用 `slave.CoE.SDORead(idx, sub)`（返回原始字节，失败返 null，先判空），再用 `BitConverter.ToUInt16` / `ToInt32` 按对象宽度取值；写用 `slave.CoE.SDOWrite(idx, sub, bytes)`（返回 bool）。C# 的 `CoEInstance` 没有索引器，`ObjectEntry` 也没有 `Value` 属性、没有泛型 `GetValue` 方法。字节数必须对上寄存器宽度。

伺服在进 OP 之后调用一次 `Enable()`。不要放进同步回调。`Enable()` 只有到 OperationEnabled 才返回 true。故障先复位，不要把故障当成已使能。

`FaultReset()` 会阻塞。同步回调里用 `FaultResetStep(0)` 再 `FaultResetStep(1)`。

CSP / CSV / CST 要在 `SetState(OP)` 之前配 DC。`ConfigureDC` 的周期与 `Config.LoopCycle` 一致，或为其整数倍。

`shiftNs == null` 是没指定相位。`0` 就是 0，不要当成没写。

武装看 `slave.Sync0Armed`。null 是答不出来，不要写成 false。不要用 `0x0980 == 0x0300` 判断已武装。

## 周期与实时

- `master.Config.LoopCycle` 单位是**纳秒**。1 ms 写 `1_000_000`。
- 实时运行时最低支持 31 µs；Windows 上推荐不低于 125 µs（`125_000`），更小没有意义 —— 应用层做不到更高频写入。
- `ConfigureDC(ns)` 与 `LoopCycle` 一致，或为其整数倍。CSP / CSV / CST 必须在 `SetState(OP)` **之前**配 DC。
- 文档给的 DarraRT 帧抖动是**平均 1.2 µs / 最大 4.5 µs**。那是驱动指标，不是你的应用抖动；你的实际抖动以现场实测与超期计数为准。
- 不要自己起 `while (true)` 线程定节拍。把读写挂到 SDK 的 PDO 周期回调，由总线周期定节拍。
- 回调里禁止 SDO、`Thread.Sleep`、文件 I/O、等锁、打日志、刷新界面 —— 任何阻塞都会拖垮实时节拍。
- C# 的 `MutexProtection` 默认 `true`，SDK 自动给每次 PDO 读写加锁；改成 `false` 就由你自己负责并发。
- 长跑前先明确：事件都在后台线程触发，UI 必须切回自己的线程（WinForms `Invoke` / WPF `Dispatcher`）。

## 常见坑（C# / Python）

| 现象 | 真因 | 正确做法 |
|---|---|---|
| `NullReferenceException` 在 `master.SetState` | `Build()` 失败时 `result.Master` 是 null，代码只拿了 `.Master` | 先判 `result.Success` 再取主站 |
| PDO 读出来的值全错位 | `struct` 少写 `Pack = 1`，或有引用类型字段 | `[StructLayout(LayoutKind.Sequential, Pack = 1)]` + 只放定宽值类型 |
| 结构体大小对不上 | 字段顺序 / 字节数与 DENI 里的 PDO 映射不一致 | 比对 `slave.Ibytes` / `slave.Obytes`，不一致就别启动 PDO |
| Python 能建站但数据不动 | 忘了 `master.start()` | `set_state(OP)` 之后显式 `start()` |
| Python `set_eni(...)` 之后什么都没发生 | 忘了链式 `build()` | `master.set_eni(p).build()` |
| C# `SDORead` 返回 null 后 `BitConverter` 崩 | 失败/WKC=0 返回 `null`，不是空数组 | 判空；原因看 `slave.CoE.LastSdoError` |
| Python `struct.unpack` 崩在 `None` | `sdo_read` 失败/WKC=0 返回 `None` | 判空；`SDO_PROTOCOL_TIMEOUT` 是邮箱没回来，**不是对象不存在** |
| 事件里取错从站 | 事件回调的 `slaveIndex` 是 1-based，`master.Slaves` 是 0-based | `master.Slaves[slaveIndex - 1]` |
| 程序退出后下次绑卡失败 | 没调 `Close()` | 退出/异常路径都 `finally { master.Close(); }` |

## 退出

结束时调用 `master.Close()`。不调的话网卡不归还。

## 时序

1. `Build()`，并检查成功
2. 订阅事件
3. 设周期，配置 DC
4. `SetState(OP)`
5. `Start()` 起 PDO 周期（Python / Java / C / C++ / Rust 必调；C# 可省，幂等）
6. `InitializePdoOffsets()`，再设操作模式
7. `Enable()` 一次
8. 在周期回调里写 PDO
9. `Close()`

## 不要生成的写法

- `Build().Master` 不检查 `result.Success`
- PDO 用 class，或大小、字段顺序和 DENI 不一致
- 同步回调里做 SDO、Sleep、打日志、刷新界面
- 事件下标不减 1
- CSP 目标位置只写一次
- 在 OP 之前 `Enable()`
- 自己再包一层状态切换重试
- Python 忘了 `build()` 或 `start()`
- 编造下载地址、包名、端口或安装步骤
