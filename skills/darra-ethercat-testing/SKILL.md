---
name: darra-ethercat-testing
description: >
  验证自己写的 Darra EtherCAT 主站程序是否正确时使用。先跑通官方开源案例排除环境，
  再按「扫到 → 进 OP → WKC 满 → PDO 合理 → 周期稳 → 异常可捕获」逐级断言。
  含 C# / Python 最小测试片段、「没量到 vs 实测空口」判据、常见假绿与证据收集。
  触发词：EtherCAT 测试、主站验证、自检、扫从站、进 OP、WKC、PDO、soak、假绿、SlaveCount null、EmptyBus。
---

# Darra EtherCAT 测试验证

这份 skill 只回答一件事：**怎么证明自己写的主站程序是对的**。
它假设你已经有能跑的主站程序（C# 或 Python），现在要判定它对不对；不覆盖安装和驱动。

## 先读规则

写测试代码之前读：

- https://ethercat.darra.xyz/ai-prompts.txt
- C# https://ethercat.darra.xyz/doc/sdk/csharp
- Python https://ethercat.darra.xyz/doc/sdk/python

API 名称、状态机、扫描口径以这份为准。本文只在「判定」上补充，不另造接口。

## 第一步：官方案例先跑通

目的不是抄代码，是**先把环境从变量里排除**。官方案例都跑不通时，你写的程序再对也测不出来。

### 拿案例

- 公开仓：`https://github.com/DarraTechnology/Ethercat_Master`
- 示例在仓根 `Windows/CSharp/<项目>/`（文档站各案例页链接即此路径）
- 本机源码仓里的对应目录：`Darra_EtherCAT_开源案例\Windows\CSharp\`（相对 `Darra_EtherCAT_Master` 仓根）

```powershell
git clone https://github.com/DarraTechnology/Ethercat_Master.git
cd Ethercat_Master
```

克隆不带 `bin/`。Ezi-SERVO2 随附两份开发台架的 `config.deni`（换台架不可用），其它案例不随附；示例目录不含厂商 ESI。自己的台架必须用 GUI 扫描后导出 DENI、导入自己的 ESI，不能手写 DENI。

### 九个案例

| 项目 | 从站 | 用途 |
|---|---|---|
| `HCFA_X3E_QuarterTurn` | HCFA X3E 伺服 | 默认 CiA 402 案例。**500 µs**；1 ms 下 cyclic WKC 会一直是 0、进不了 OP |
| `Ezi-SERVO2_CSP_PP` | Ezi-SERVO2 伺服 | 单轴最小完整例程（CSP + PP） |
| `STF-EC_CSP_PP` | MOONS' STF-EC 步进 | 带最小控制台 `EtherCATRestore`，推荐先跑 |
| `STF-EC_ECam` | MOONS' STF-EC 步进 | 电子凸轮 |
| `STF-EC_SyncAxis` | MOONS' STF-EC 步进 | 同步轴 |
| `Panasonic_CNC_Interpolation` | 松下 A6B 伺服 | 多轴插补 |
| `Panasonic_ConveyorSync` | 松下 A6B 伺服 | 传送带同步 |
| `FurutaPendulum` | GCAN-8200 + GC1602 + GR-EC01 | 倒立摆 |
| `RobotToolChanger` | 六轴 CiA 402 + 工具位 | 换枪盘 |

### 零硬件冒烟：`--ui-audit`

任意案例加 `--ui-audit`，它只在后台搭界面并跑程序化 UI 自检，报告含 `RESULT: PASS` / `RESULT: FAIL`（部分案例控制台末尾另打 `AUDIT RESULT: ...`）。以退出码为准：0 = PASS。

下面每个命令块都默认从仓根开始；需要切换目录的会在块内注明。

```powershell
# 在仓根执行
.\Windows\CSharp\STF-EC_CSP_PP\bin\Debug\STF_EC_CSP_PP.exe --ui-audit
```

跑之前先编译（MSBuild 命令见下一节）。

它不建主站、不碰总线。只能证明工程能编、依赖齐全、能启动、界面自检能过；**不能替代任何 EtherCAT 验证**。

### 有硬件的最小闭环：EtherCATRestore 控制台

`STF-EC_CSP_PP\EtherCATRestore\EtherCATRestore\` 是不依赖 WinForms 的最小控制台：加载同一份 DENI，逐级推到 PreOp → SafeOp → OP，之后每 1 秒打印各轴状态字 / 错误码 / 实际位置，只读，不驱动电机。

```powershell
# 在仓根执行：最小控制台（需要 .NET 8 SDK）
dotnet run --project .\Windows\CSharp\STF-EC_CSP_PP\EtherCATRestore\EtherCATRestore\EtherCATRestore.csproj

# 完整 WinForms 工程：进项目目录执行；老式 csproj 必须 MSBuild + x64，不要用 dotnet build
cd .\Windows\CSharp\STF-EC_CSP_PP
& "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" `
  .\STF-EC_CSP_PP.csproj /restore /p:Configuration=Debug /p:Platform=x64
```

MSBuild 路径按本机 VS 安装调整。DENI 默认读 exe 同目录，也可以用第一个参数指定。以管理员权限运行。

### 跑通判据

- 初始化后打印 `主站初始化完成, 从站数量: N`，N 等于实际从站数
- 依次出现 `→ PreOp 完成` → `→ SafeOp 完成` → `→ OP 完成`
- 每秒打印 `轴i: SW=... Err=... Pos=...`，数值随总线变化

跑通说明：安装包、SDK、网卡、DENI、ESI、拓扑这条链路可用，目标机具备进 OP 的能力。
**不说明**：你的程序对、PDO 映射对、WKC 满、周期稳。这些要用下面的六级自检。

案例也跑不通时先修环境（DENI 里的网口与实际接线是否一致、ESI 与固件是否匹配、从站是否上电、是否管理员），不要先怀疑自己的代码。

## 六级自检（按顺序，前一级不过不要测后一级）

| 级别 | 全部满足才算过 | 失败先看 |
|---|---|---|
| 1 扫到 | 有网口结论为 `HasSlaves` 且站数等于期望 N；完整扫描的从站号连续 1..N | 每口 `State` / `NativeCode` |
| 2 进 OP | `SetState(OP)` 返回 true；**逐站**状态位 `& 0x0F == 0x08`；耗时 ≤ 5000 ms；真 OP 判定成立 | 每站 AL Status / AL Status Code |
| 3 WKC 满 | `ExpectedWKC > 0` 且 `WKC == ExpectedWKC`（精确相等） | 差额、逐站 `WcContributed` |
| 4 PDO 合理 | 输入快照长度 ≥ `Ibytes`；输出写入长度 == `Obytes`；值在物理量程内；陈旧输入被识别 | 长度、陈旧输入标志（C# / Python 各自接口） |
| 5 周期稳 | soak 期间周期计数单调增；掉站秒数 0；WKC 亏空秒数 0；抖动 < 1 个总线周期 | 每秒采样、掉站事件 |
| 6 异常可捕获 | 注入故障后测试必须判 FAIL，并带错误码；进程不崩、不吞异常 | 注入点、AbortCode、AL 码 |

### 1. 能不能扫到

- C#：`DarraEtherCAT.QuickScan()` 看每口结论；要完整列表用 `StandardScan(adapter, secondary, out outcome)`。`outcome == ScanOutcome.Success` 只代表没失败，还要判列表 `Count`（`StandardScan` 的 0 站是 `EmptyBus`）。
- Python：`EtherCATMaster.quick_slave_count(adapter)` 返回原生码；要列表用 `scan_slaves(dll, adapter)`。
- 从站号必须连续 1..N。跳号 = 拓扑不完整，按 FAIL 处理，不要用「总数对得上」糊过去。

### 2. 能不能进 OP

- C#：`master.SetState(EcState.OP, out string err)`，失败必须报 `err`，不要在外面再包一层重试把失败吞掉。
- 逐站判：状态位 = 原始 AL Status `& 0x0F`，等于 `0x08` 即 OP；`0x18`（OP + Error）也算到位，Error 位只记录、不作判定依据。
- 「主站说 OP」不等于「从站在 OP」。C# 用 `master.Diagnostics.RealOpTruth` 一次取主站结论 + 逐站结论；`RealOp == true` 才叫真 OP。
- `RealOpTruth` 的「必需站」= 非可选且配置了过程数据。没有 PDO 的从站不计入 `RequiredCount`；这类台架要另外确认它的 AL 状态，不能因为 `RealOp == true` 就默认全站到位。
- 产品承诺任何状态切换 ≤ 5 s。超过 5 s 还没到位 = 未达判据。

### 3. WKC 满不满

- 判据是**精确相等**：`ExpectedWKC > 0 && WKC == ExpectedWKC`。不要写 `WKC > 0`，也不要写 `actual >= expected`。
- 差额 = `ExpectedWKC - WKC`。有差额说明有从站没在贡献；逐站看 `WcContributed`，`NotContributed` = 该站此刻没响应，不是主站故障。
- 冗余副口 `0xFFFF` = 本拍无实测（未知），不是 0，也不是满额。
- **绝不下调 `ExpectedWKC` 迁就劣化总线**。降期望让数字对上 = 掩盖故障。

### 4. PDO 值合不合理

- 输入快照长度 ≥ `slave.Ibytes`（小于 = 截断），输出写入长度 == `slave.Obytes`；字段顺序等于 DENI 里的 PDO 映射顺序。
- 读输入快照后先判长度，再判值域。值域来自 ESI / 设备手册 / 工艺量程，不来自「看起来不是 0」。
- 输入映像陈旧必须识别：C# 从站离线时零拷贝输入入口抛 `PdoInputStaleException`（映像是掉站前最后一帧）；Python 看 `slave.pdo.is_input_frame_stale`（`try_get_inputs_ptr()` 返回 `None`）。捕获后把该轴标为不可信，**不要把上一拍的旧值当实时值继续断言**。
- CiA 402 至少核对 statusword 是否进入预期状态（如 OperationEnabled）和 error code 是否为 0；不要只打印不判定。

### 5. 周期稳不稳

- 短测至少 10 分钟；交付前按文档要求做 24 小时压力测试。
- 每秒采样：周期计数是否前进、每站是否仍在 OP、`WKC` 对照 `ExpectedWKC`、丢帧/掉站计数。
- 判据参考官方测试台：掉站秒数 0、WKC 亏空秒数 0、主站在 OP 的秒数达到台架门槛（Python 台架 = 总时长 − 5；C# 台架 = 90%）、邮箱成功率 ≥ 99%、抖动 < 1 个总线周期。
- 只跑 10 秒没报错不等于稳。

### 6. 异常能不能被捕获

逐项注入，确认测试**判 FAIL 且带得出错误码**，而不是进程崩了或异常被吞：

- 读不存在的 SDO 对象 → `AbortCode` 应为 `0x06020000`（对象不存在），不是静默返回空
- 拔掉一个从站 → `slave.IsLost` / `SlaveOffline` 事件 / `WcContributed != Contributed`，其它站继续跑
- 非法状态跳转 → `SetState` 返回 false 且 `err` / `last_state_error` 有逐站原因
- 故障注入后如果测试仍然 PASS，说明断言根本没测到点子上

## 「没量到」和「实测空口」

扫描结果有三种身份，测试里必须分开写：**没量到**、**实测空口**、**实测 N 站**。不许把 `null` 当 0。

### C#

| 你拿到的 | 类型 | 含义 | 能否判空口 |
|---|---|---|---|
| `NicQuickScanRow.SlaveCount` | `int?` | `null` = 没量到；`0` = 实测空口 | 必须配合 `State` |
| `NicQuickScanRow.State` | `NicScanState` | `HasSlaves` = 实测有站；`EmptyBus` = 实测空口；其余均不是空口结论 | 是（快扫首选） |
| `ScanOutcome` | `ScanOutcome` | `Success` = 扫描完成（`ScanSlaves` 下 0 站也可能是 `Success`）；`StandardScan` 把 0 站细化成 `EmptyBus`。判空口要用 `EmptyBus` 或列表 `Count` | 是（配合 count） |
| `QuickSlaveCount(adapter)` | `int` | `>= 0` 是从站数（`0` = 实测空口）；`< 0` 是没量到 / 主站占用 / 失败 | 能判 0 站；负码不是 0 |
| `master.SlaveCount` | `int` | 建站后从站表长度，**永远不是 null** | 不能 |

关键：`master.SlaveCount` 是 `int`（`Slaves?.Count ?? 0`）。Build 失败、配置没加载时它同样是 0。**0 只代表「当前从站表为空」，不代表「实测空口」**。判空口只能在建站前看 `QuickScan` / `StandardScan` / `QuickSlaveCount` 的结论。

`NicScanState` 和 `NicScanStatus` 是两个不同的枚举，数值也不同，不要混用：
`NicScanState.EmptyBus = 1` / `NotMeasured = 3`；`NicScanStatus.IdleNoSlave = 1` / `NotMeasured = 0`。

### Python

| 你拿到的 | 类型 | 含义 |
|---|---|---|
| `NetworkInfo.slave_num` | `Optional[int]` | `None` = 没量到；`0` = 实测空口；配合 `scan_status` 区分原因 |
| `NicScanStatus` | 枚举 | `NOT_MEASURED` / `IDLE_NO_SLAVE` / `FOUND` / `OCCUPIED_BY_MASTER` |
| `quick_slave_count(adapter)` | `int` | `>= 0` 是从站数；`< 0` 是原生错误码原值 |
| `scan_slaves(...)` 返回值 | `List` | 空列表 = 扫描跑完且总线上确实 0 个从站 |
| `ScanOutcome` | 枚举 | `SUCCESS = 0` 只表示「扫描已执行」，**不表示扫到了站** |
| `master.slave_count` | `int` | 永远不是 `None` |

Python 没有 `NicScanState`，不要照抄 C# 名字。`ScanOutcome.SUCCESS` + 空列表 = 实测空口；这是正常结论，但在「台架应该有站」的测试里必须判 FAIL。

### 三条硬规则

- 禁止 `count ?? 0`、`count or 0`、`int(x)` 把 `null` / `None` 折成 0。
- 报告里三种结论分开写，证据里带上原始 `NativeCode` / `scan_status`。
- 台架上明明有从站却得到空口 = FAIL，不是 SKIP，也不是 UNPROVEN。

## 断言怎么写才算有效

- 判定只有四种：`PASS` / `FAIL` / `SKIP` / `UNPROVEN`。`UNPROVEN` 不算过；`SKIP` 只能用于「设备确实不具备该能力」，并写明缺什么。
- 先固定期望值：从站数 N、`ExpectedWKC`、PDO 量程由配置 / ESI / 手册决定；`ExpectedWKC` 可经诊断属性读取，但不得由 actual 反推或下调。
- 一条断言只测一件事。不要用「程序没崩」「打印了 OK」当断言。
- 每条断言输出一行：`ID | 判定 | 结论 | 证据`。证据必须含：从站号、对象 `index:sub`、实测值、期望值、耗时（有则写）。
- 失败必须能定位：带原始 AL Status、AL Status Code、SDO AbortCode、WKC 对照。
- 不允许为了让结果变绿放宽判据；把 FAIL 改判 SKIP / UNPROVEN 需要独立证据。

证据行示例：

```text
L2-OP   | PASS | 6/6 站进入 OP        | slave=1..6 raw AL=0x08; elapsed=812ms
L3-WKC  | FAIL | WKC 不足             | actual=10 expected=12 deficit=2; slave[5].WcContributed=NotContributed
L5-PDO  | PASS | 输入长度与值域正常   | slave=1 Ibytes=8 read=8 statusword=0x0637
```

弱断言和强断言的差别：

| 弱（不要写） | 强（要写） |
|---|---|
| 程序跑完没退出 | 6/6 站状态位 `0x08`，`RealOp == true`，耗时 ≤ 5000 ms |
| WKC 不为 0 | `ExpectedWKC > 0` 且 `WKC == ExpectedWKC` |
| 读到 PDO 了 | 输入长度 ≥ `Ibytes`，输出长度 == `Obytes`，值在量程内 |
| 扫描有结果 | 站数 == N，且从站号连续 1..N |
| SDO 没抛异常 | `Ok == true`、数据长度 == 4、`AbortCode == 0`、值等于期望 |

## 最小测试片段（C#）

```csharp
using System;
using System.Linq;
using DarraEtherCAT_Master;

static class Smoke
{
    static int Main()
    {
        const int ExpectedSlaves = 6;
        const string DeniPath = @"config.deni";

        // 1) 扫描：先分清「没量到」和「实测空口」
        var rows = DarraEtherCAT.QuickScan();
        var hit = rows.FirstOrDefault(r => r.State == DarraEtherCAT.NicScanState.HasSlaves);
        if (hit == null)
        {
            bool empty = rows.Any(r => r.State == DarraEtherCAT.NicScanState.EmptyBus);
            throw new Exception(empty
                ? "实测空口：扫描跑过，总线上确实 0 个从站"
                : "没量到：没有任何网口给出 HasSlaves / EmptyBus 结论");
        }
        if (hit.SlaveCount != ExpectedSlaves)
            throw new Exception($"扫描到 {hit.SlaveCount} 站，期望 {ExpectedSlaves}");

        // 2) 建主站（DENI 里的网口必须就是上面命中的网口）
        var build = new DarraEtherCAT().SetENI(DeniPath).EnableAutoStartup().Build();
        if (!build.Success) throw new Exception($"Build 失败: {build.Message}");
        var master = build.Master ?? throw new Exception("Build 成功但没有 Master 实例");
        if (master.SlaveCount != ExpectedSlaves)
            throw new Exception($"建站后 {master.SlaveCount} 站，期望 {ExpectedSlaves}");

        // 3) 进 OP，并逐站核对真实状态；主站 State 不算证据
        if (!master.SetState(EcState.OP, out string err))
            throw new Exception($"进 OP 失败: {err}");

        // RealOpTruth 按总线周期刷新：轮询最多 3 秒，不要只读一拍
        var truth = master.Diagnostics.RealOpTruth;
        var settle = System.Diagnostics.Stopwatch.StartNew();
        while (settle.ElapsedMilliseconds < 3000)
        {
            truth = master.Diagnostics.RealOpTruth;
            if (truth.RealOp && truth.RealOpCount == truth.RequiredCount) break;
            System.Threading.Thread.Sleep(50);
        }
        if (!truth.RealOp || truth.RealOpCount != truth.RequiredCount)
            throw new Exception($"假 OP: {truth.DetailText}");

        // 4) WKC 必须精确相等
        var diag = master.Diagnostics;
        if (!(diag.ExpectedWKC > 0 && diag.WKC == diag.ExpectedWKC))
            throw new Exception(
                $"WKC {diag.WKC}/{diag.ExpectedWKC}，差额 {diag.ExpectedWKC - diag.WKC}");

        // 5) SDO 身份读取：状态、长度、值都要断言
        var slave = master.Slaves[0];
        var coe = slave.CoE ?? throw new Exception("该从站没有 CoE");
        var data = coe.SDORead(0x1018, 1, out SdoReadResult r);
        if (!r.Ok || data == null || data.Length != 4)
            throw new Exception(
                $"SDO 0x1018:01 失败 abort=0x{r.AbortCode:X8} wkc={r.Wkc}/{r.ExpectedWkc}");

        uint vendorId = BitConverter.ToUInt32(data, 0);
        if (vendorId == 0) throw new Exception("VendorId == 0");

        master.Close();
        Console.WriteLine("PASS");
        return 0;
    }
}
```

要点：`SdoReadResult` 的成功标志是 `.Ok`，不是 `.Success`。`master.Slaves` 是 0 基列表，`SlaveNum` / 事件里的下标是 1 基。`master.Close()` 必须执行；实际测试放到 `try/finally`。测试进程以管理员权限运行，否则扫描 / 建站会因权限失败，不要误判成空口。

## 最小测试片段（Python）

```python
import time

from darra_ethercat import EtherCATMaster, EcState

EXPECTED_SLAVES = 6
ADAPTER = r"\Device\NPF_{...}"          # 从 get_network_info / quick_slave_count 拿到的网口名
DENI = r"C:\EtherCAT\MyProject.deni"

# 1) 扫描：>= 0 才是站数，< 0 是没量到/占用/失败，不要把负码当 0
n = EtherCATMaster.quick_slave_count(ADAPTER)
if n < 0:
    raise RuntimeError(f"没量到：原生错误码 {n}")
if n == 0:
    raise RuntimeError("实测空口：扫描跑过，总线上确实 0 个从站")
if n != EXPECTED_SLAVES:
    raise AssertionError(f"扫描到 {n} 站，期望 {EXPECTED_SLAVES}")

# 2) 建主站：set_eni 返回 self，可链式；构建结果用 deconstruct 取
master = EtherCATMaster().set_eni(DENI).enable_auto_startup().build()
_, result = master.deconstruct()
if not result.get("success"):
    raise RuntimeError(f"Build 失败: {result}")
if master.slave_count != EXPECTED_SLAVES:
    raise AssertionError(f"建站后 {master.slave_count} 站，期望 {EXPECTED_SLAVES}")

# 3) 进 OP：失败要带逐站证据
if not master.set_state(EcState.OP):
    raise RuntimeError(f"进 OP 失败: {master.last_state_error}")

# 真 OP 按总线周期刷新：轮询最多 3 秒
truth = master.diagnostics_info.real_op_truth
deadline = time.time() + 3.0
while time.time() < deadline:
    truth = master.diagnostics_info.real_op_truth
    if truth.real_op and truth.real_op_count == truth.required_count:
        break
    time.sleep(0.05)
if not truth.real_op or truth.real_op_count != truth.required_count:
    raise AssertionError(f"假 OP: {truth.detail_text}")

# 4) WKC 精确相等
diag = master.diagnostics_info
if not (diag.expected_wkc and diag.wkc == diag.expected_wkc):
    raise AssertionError(
        f"WKC {diag.wkc}/{diag.expected_wkc}，差额 {diag.wc_deficit}")

# 5) SDO 身份读取：detail=True 才拿得到 abort_code / wkc
slave = master.slaves[0]                 # slaves[0] = 第 1 台
r = slave.coe.sdo_read(0x1018, 1, detail=True)
if not r.ok or r.data is None or len(r.data) != 4:
    raise AssertionError(
        f"SDO 0x1018:01 失败 abort=0x{r.abort_code:08X} wkc={r.wkc}")

vendor_id = int.from_bytes(r.data, "little")
if vendor_id == 0:
    raise AssertionError("VendorId == 0")

master.close()
print("PASS")
```

要点：`set_state` 只返回 `bool`，失败原因在 `last_state_error`。`slave.coe.sdo_read` 默认返回 `bytes`（失败返回 `None`），要错误码必须 `detail=True`。`master.close()` 必须执行；实际测试放到 `try/finally`。测试进程以管理员权限运行（可用 `is_running_as_admin()` 先自检）。

## 常见假绿

1. **进程没退出就判过**。主站空转、从站掉线、PDO 全是旧值，进程都活得好好的。必须断言状态、WKC、PDO、时间窗口。
2. **`catch { }` 吞掉异常**。任何失败路径都要记异常类型、消息、堆栈和上下文；测试里吞异常等于把 FAIL 改成 PASS。
3. **拿缓存当实时**。C# 的 `slave.State` 是缓存值；`AlStatusMirror == 0` 表示未采样/未知，不是 INIT。要真相用 `RealOpTruth` 或实读链。
4. **`actual >= expected` 冒充 WKC 满**。判据是精确相等。多出来的贡献和少了贡献都要能解释。
5. **把 `null` 折成 0**。`count ?? 0`、`or 0` 会把「没量到」伪装成「空口」，这是最典型的假绿。
6. **把 Python 的 `ScanOutcome.SUCCESS` 当成「扫到站」**。它只表示扫描执行过；空列表 + SUCCESS = 实测空口。
7. **只测第一站 / 只测一次**。多站台架必须逐站判；状态和 WKC 必须在时间窗口内持续判。
8. **拿旧二进制跑新代码**。改了源码但跑的是旧 DLL，结论全部作废。跑前核对 SDK 版本和文件哈希，跑后确认新行为/日志真的出现。
9. **用 Debug 件的结果宣布 Release 可用**。日志级别、优化、加壳都会变；Release 件要用同一套断言重跑。
10. **`master.State == OP` 就当所有从站在 OP**。主站状态和从站真实状态是两回事，必须逐站判。

## 出错时收集什么

按这个顺序收，够定位就不用再猜：

1. **复现信息**：SDK / Core 版本、语言与版本、Windows 版本、目标机、命令、退出码、完整 stdout。
2. **扫描证据**：每个网口的 `Name`、`State`、`SlaveCount`（含 null 原样）、`NativeCode`、`scan_status`。
3. **逐站证据**：从站号、原始 AL Status（含状态位与 Error 位）、AL Status Code、`IsLost`、`WcContributed`、`Ibytes` / `Obytes`。
4. **主站证据**：`WKC` / `ExpectedWKC` / 差额、`RealOpTruth`（`RealOp`、`Reason`、`RequiredCount`、`RealOpCount`、`DetailText`）。
5. **SDO 证据**：`index:sub`、`Ok`、`AbortCode`、`Wkc` / `ExpectedWkc`、读到的长度和值。
6. **时序证据**：每次状态切换的开始/结束时间与耗时；soak 期间每秒的周期计数、OP 站数、WKC。
7. **日志**：
   - C# SDK：`events.log` 在 exe 同目录，10 MB 轮转到 `events.log.1`，1 秒 flush（读完等 1 秒再读，或按会话头对齐）
   - 默认只保留 Error/Fatal（Warning/Message 静音）；状态转换和掉站的逐条证据用 SDK 事件自己记录（`StateChanged` / `SlaveStateChanged` / `SlaveOffline` / `PDOFrameLoss`），不要指望日志里有明细
   - Python：未调用 `init_events_log(path)` 时，`events.log` 写在进程当前目录
   - GUI：`%TEMP%\DarraRT_Debug_*.txt`、exe 同目录的 `startup_trace.log` / `crash_log.txt`
   - 安装/卸载异常：`%ProgramData%\Darra\EtherCAT\install.log`
8. **对照**：同一台架、同一从站、同一配置下，官方案例的结论与你的程序结论是否一致。不一致时先查自己的程序。

## 不要写的测试

- 不写 `try { ... } catch { }`；至少记录并判 FAIL
- 不用固定的 `Sleep` 一次就下结论；轮询状态位 / WKC 并设超时
- 不在 PDO 同步回调里做 SDO、日志刷屏、UI 刷新
- 不把 `null` / `None` 写成 0 站
- 不为通过下调 `ExpectedWKC`，不篡改 `actual`
- 不只测一台从站、不只测一次状态切换
- 不用「进程还在」当验收
- 不在开发机上跑硬件测试；开发机只编译，运行到专用测试机

## 出处（核对用）

以下是给审阅者的源码核对信息；对外发布版可删掉本节。

路径相对 `Darra_EtherCAT_Master` 仓根。

**C# SDK**

| API | 出处 |
|---|---|
| `DarraEtherCAT.QuickScan` | `Darra_EtherCAT_ClassLibrary/CSharp/Master/Static/Network.cs:1527` |
| `NicScanState`（8 个成员） | `.../Master/Static/Network.cs:1886` |
| `NicQuickScanRow.SlaveCount`（`int?`） / `.State` | `.../Master/Static/Network.cs:1936` / `:1939` |
| `QuickSlaveCount(string)` | `.../Master/Static/Network.cs:2097` |
| `StandardScan(..., out ScanOutcome)` | `.../Master/Static/Network.cs:2777` |
| `ScanOutcome`（含 `EmptyBus = 2`） | `.../Master/Static/Network.cs:2909` |
| `master.SlaveCount` | `.../Master/Core.cs:1887` |
| `master.Slaves` | `.../Master/Core.cs:1358` |
| `master.Diagnostics` | `.../Master/Core.cs:315` |
| `SetState(EcState)` / `SetState(EcState, out string)` | `.../Master/State.cs:3480` / `:3489` |
| `master.Close()` | `.../Master/State.cs:2445` |
| `EcState` | `.../Master/Data/Type.cs:28` |
| `SdoReadResult`（`Ok` / `Data` / `AbortCode` / `Wkc`） | `.../Master/Data/Type.cs:574` |
| `slave.CoE` | `.../Master/Slave/Core.cs:144` |
| `slave.ErrorCode` | `.../Master/Slave/Core.cs:177` |
| `slave.Ibytes` / `slave.Obytes` | `.../Master/Slave/Core.cs:1301` / `:2744` |
| `slave.IsLost` | `.../Master/Slave/Core.cs:1328` |
| `slave.State`（缓存值） | `.../Master/Slave/Core.cs:3136` |
| `slave.WcContributed` | `.../Master/Slave/Core.cs:3192` |
| `slave.AlStatusMirror` | `.../Master/Slave/Core.cs:3213` |
| `CoEInstance.SDORead(..., out SdoReadResult)` | `.../Master/Slave/CoE.cs:2333` |
| `Diagnostics.WKC` / `.ExpectedWKC` | `.../Master/MasterDiagnosticsInfo.cs:2378` / `:2384` |
| `Diagnostics.RealOpTruth` | `.../Master/MasterDiagnosticsInfo.cs:3634` |
| `MasterRealOpTruth.RealOp` / `.RequiredCount` / `.RealOpCount` / `.DetailText` | `.../Master/MasterDiagnosticsInfo.cs:3960` 起 |
| `SetENI` / `EnableAutoStartup` / `Build` / `BuildResult` | `.../Master/Initialise.cs:133` / `:175` / `:639` / `:272` |
| 默认日志级别 `ErrorsOnly` | `.../Master/Logging/Logging.cs:18-25` |
| `events.log` 位置与轮转 | `.../Master/Logging/Logging.cs:2261-2265` |

**Python SDK**

| API | 出处 |
|---|---|
| `EcState` | `Darra_EtherCAT_ClassLibrary/Python/darra_ethercat/data/types.py:65` |
| `EtherCATMaster.set_eni` / `.enable_auto_startup` / `.build` / `.deconstruct` | `.../darra_ethercat/master/core.py:1001` / `:1104` / `:1114` / `:1207` |
| `master.slave_count` / `.slaves` / `.diagnostics_info` | `.../master/core.py:625` / `:678` / `:959` |
| `master.set_state` / `.last_state_error` / `.close` | `.../master/core.py:1845` / `:1670` / `:383` |
| `EtherCATMaster.quick_slave_count`（静态） | `.../master/core.py:2993` |
| `MasterDiagnosticsInfo.wkc` / `.expected_wkc` / `.wc_deficit` | `.../master/diagnostics.py:1037` / `:1133` / `:632` |
| `MasterDiagnosticsInfo.real_op_truth` | `.../master/diagnostics.py:1582` |
| `MasterRealOpTruth`（`real_op` / `required_count` / `real_op_count` / `detail_text`） | `.../master/real_op.py:110-123` |
| `Slave.coe` / `CoE.sdo_read` / `SdoReadResult` | `.../slave/core.py:2755` / `:559` / `:396` |
| `SlavePdo.is_input_frame_stale` / `try_get_inputs_ptr` | `.../slave/slave_pdo.py:312` / `:296` |
| `Slave.state` / `.al_status_code` / `.is_lost` | `.../slave/core.py:3429` / `:3438` / `:3891` |
| `NicScanStatus` / `ScanOutcome` | `.../statics/network.py:19` / `:50` |
| `NetworkInfo.slave_num`（`Optional[int]`） | `.../statics/network.py:188` |
| `scan_slaves` / `quick_slave_count` | `.../statics/network.py:454` / `:566` |
| `is_running_as_admin` | `.../statics/authorization.py:256` |
| `events.log` 默认写当前目录 | `.../darra_ethercat/logging/logging.py:353` |

**案例与测试规范**

| 事实 | 出处 |
|---|---|
| 九个案例、八 NuGet 一 ProjectReference、克隆不带 bin（Ezi 例外带 2 份开发台架 DENI） | `Darra_EtherCAT_开源案例/README.md:7-11`、`:54-66`、`:90-96` |
| `--ui-audit` 只自检界面、不连总线、exit 0 仅 PASS | `Windows/CSharp/STF-EC_CSP_PP/Program.cs:12-66`、`Ui/MainForm.Audit.cs:13-30` |
| 最小控制台用法与输出 | `Windows/CSharp/STF-EC_CSP_PP/README.md:214-226`、`EtherCATRestore/EtherCATRestore/Program.cs:80-119` |
| 老式 csproj 必须 MSBuild + x64 | `Windows/CSharp/STF-EC_CSP_PP/README.md:198-206` |
| HCFA 必须 500 µs | `Darra_EtherCAT_开源案例/README.md:7` |
| 无软件仿真器 | `Darra_EtherCAT_开源案例/COMMISSIONING.md:5` |
| 四判定与证据格式 | `测试项目/CORE_TEST_SPEC.md:7-22`、`:176`、`:190` |
| OP ≤ 5 s、WKC 精确相等 | `测试项目/TEST_SDK_CSharp/Program.cs:20628-20696`、`:20699-20723`；`测试项目/TEST_SDK_Python/sdktest.py:1566` |
| 扫描结论、null 与空口口径 | `云端/ethercat-doc/docs/sdk/csharp/master/constructors.md:390-395`、`:409-413`、`:426`、`:437`、`:505` |
| 真 OP 判定、稳定性判据 | `云端/ethercat-doc/docs/sdk/csharp/master/diagnostics.md:362-374`；`云端/ethercat-doc/docs/faq/stability.md:106-117`；`测试项目/TEST_SDK_Python/sdktest.py:4944`、`:5111-5117`；`测试项目/TEST_SDK_CSharp/Program.cs:7915-7917`、`:8245` |
| 进不了 OP 的排查顺序 | `云端/ethercat-doc/docs/faq/error-codes.md:98-103` |
