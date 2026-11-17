---
name: darra-verify
description: >
  装完 Darra EtherCAT 运行时之后，系统性确认它到底活着没有。分六层（L0 安装事实 → L1 SDK 就位 →
  L2 SDK 能加载 → L3 网卡能枚举 → L4 总线能扫 → L5 可选：进 OP 并读从站身份对象），
  每层给判据、给命令、给结论话术，最后输出一段机器可读 JSON（adapters[] / scan_state / slave_count / sdk_version）。
  扫描结论严格三态：null = 没量到，0 = 实测空口（EmptyBus），N > 0 = 实测 N 个从站。
  没有从站也能跑，空口是正常结论。默认不证明实时性能；L5 需要 DENI 与真从站。
  触发词：验证 / 怎么确认装好了 / 装完能跑吗 / 有没有装好 / 自检 / 跑通没有 / 检查环境 /
  冒烟测试 / smoke test / verify / 健康检查 / 装完怎么确认 / 扫不到从站 / 空口 / 三态。
---

# 装完之后，系统性确认它活着

装完不要只说「应该装好了」。按 L0 → L5 一层层往下走，每层给出**可复述的判据**，最后落到一段能引用的 JSON。

```text
L0 安装事实   →  退出码 / 是否需要重启
L1 SDK 就位   →  安装目录下六语言 SDK 与 C# 程序集在不在
L2 SDK 能加载 →  程序集版本读得到、类型能实例化
L3 网卡能枚举 →  系统网卡清单与 EtherCAT 能力/链路/占用
L4 总线能扫   →  逐口快扫，严格三态结论
L5 进 OP（可选）→  有 DENI + 真从站时，进 OP 并读 0x1018:01
```

**能讲到哪一层，取决于你实际跑到哪一层。** 只跑完 L4，就别对实时性能、长跑稳定性发表结论。
L5 跑通了，才可以额外说「进 OP 成功，身份对象读得到」。

## 六层判据

| 层 | 判据 | 通过的样子 | 不通过先查 |
|---|---|---|---|
| L0 | 安装器退出码 | `0` = 已生效；`3010` = 已成功、**重启后**才生效 | 见 [`darra-runtime-install`](../darra-runtime-install/SKILL.md) 的退出码表 |
| L1 | 安装目录下 `SDK\SDK_CSharp\DarraEtherCAT.dll` 等文件存在 | 六种语言的 SDK 目录都在 | 安装目录是否用了 `--path` 改过；安装是否被 1603 / 1604 中断 |
| L2 | `typeof(DarraEtherCAT).Assembly` 能取到版本 | `sdk_version` 是正常版本号 | 包没还原、架构不对、Runtime 缺失 |
| L3 | `GetNetworkAdapters()` 返回非空清单 | 至少有一张 `EtherCatCapable = true` 的物理有线网卡 | 网卡是否被禁用；是否只有无线/虚拟网卡 |
| L4 | 逐口 `NicScanState` | `HasSlaves`（≥1 站）或 `EmptyBus`（实测 0 站） | 全是 `NotMeasured` / `Unsupported` / `Failed` 时按 `State` 查 |
| L5 | `SetState(OP)` 返回 true 且 `SDORead(0x1018, 0x01)` 非 null | 进 OP 成功、VendorID 读得到 | 从站拓扑与 DENI 是否一致；从站是否支持 CoE |

L0–L4 不需要从站也能跑完，是**任何机器都能做的自检**。L5 是可选加码，需要 `config.deni` 与真从站。

## 1. 先确认前提

- 已经装好 Darra EtherCAT 运行时。没装先回去走安装技能：[`darra-runtime-install`](../darra-runtime-install/SKILL.md)
- Windows x64，管理员权限（SDK 的环境要求就是管理员，普通权限跑不出可信结果）。
- 机器上有没有从站都行。**没有从站也是有效结论**，不需要为了"验证"去接设备。

## 2. L0：安装这一趟算不算成功

只认**安装器退出码**，不要凭「装完了」的感觉：

| 退出码 | 判断 | 下一步 |
|---|---|---|
| `0` | 本次已生效 | 直接往下走 |
| `3010` | 成功，但**重启后才生效** | **先去重启**，再看后面的层。没重启就测，读到的可能是旧驱动 / 旧文件 |
| 其它 | 安装没成功 | 回安装技能按退出码处理，不要在这一层继续猜 |

`3010` 是成功码不是失败。它有两档，两档都不用重跑安装包：① 本趟已装完，重启生效；② 驱动本趟停不下来，
安装器已安排开机换入，重启自动收尾。

重启后确认真的重启过，别用「能连上」代替：

```powershell
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
```

## 3. L1：SDK 文件就位

官方安装包把六种语言的 SDK 释放到安装目录的 `SDK\` 下（默认 `C:\DARRA\EtherCAT_Master\SDK\`）：

```text
SDK/
├── SDK_CSharp/
├── SDK_C/
├── SDK_Cpp/
├── SDK_Python/
├── SDK_Java/
└── SDK_Rust/
```

```powershell
$sdk = 'C:\DARRA\EtherCAT_Master\SDK'   # 用过 --path 就换成实际安装目录
Get-ChildItem $sdk
Test-Path "$sdk\SDK_CSharp\DarraEtherCAT.dll"
```

`Test-Path` 为 `True` = C# 运行库在位；其它语言按各自目录里的文件确认。

版本口径：SDK 版本与安装包一致，当前下载页标注 `2.13.16`（以 https://ethercat.darra.xyz/doc/downloads 为准）。
读到别的版本时先确认装的是哪个包，不要假定自己拿到的是最新版。

> 走公共包管理器（NuGet / pip / Maven / cargo）时，`SDK\` 目录不是必需条件 —— 那条路径不依赖安装目录。

## 4. L2：建工程、读版本

.NET 版本要求（C# SDK 概述）：.NET Standard 2.0 类库，.NET Framework 4.6.1+ 与 .NET 6–8 已验证；net9 / net10 要 `UseAppHost=false` 并用 `dotnet app.dll` 跑，否则改用 net8。
所以这里直接选 net8.0：

```
dotnet new console -n DarraVerify -f net8.0
cd DarraVerify
dotnet add package Darra.EtherCAT.Master
```

装不装得上 net8 SDK 看用户机器。只有 net9 / net10 时按上面那条说明改工程，别硬扛。

## 5. L2 + L3 + L4：一段程序一次拿全

命名空间是 `DarraEtherCAT_Master`，主站类是 `DarraEtherCAT`（和站内 C# 示例一致）。
整份文件替换，别只贴一半：

```csharp
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Encodings.Web;
using System.Text.Json;
using DarraEtherCAT_Master;

class Program
{
    static void Main()
    {
        var report = new Dictionary<string, object?>();
        try
        {
            var scan = DarraEtherCAT.QuickScan().ToDictionary(r => r.Name);
            report["adapters"] = DarraEtherCAT.GetNetworkAdapters().Select(a =>
            {
                scan.TryGetValue(a.Name, out var row);
                return (object)new
                {
                    name = a.Name, description = a.Description, mac = a.Mac,
                    link_status = a.LinkStatus.ToString(), ethercat_capable = a.EtherCatCapable,
                    scan_state = row != null ? row.State.ToString() : (a.EtherCatCapable ? "NotScanned" : "Unsupported"),
                    slave_count = row != null ? row.SlaveCount : null,
                    native_code = row != null ? row.NativeCode : (int?)null,
                    error = a.Error
                };
            }).ToList();
        }
        catch (Exception ex)
        {
            report["adapters"] = new List<object>();
            report["error"] = ex.GetType().Name + ": " + ex.Message;
        }
        report["sdk_version"] = typeof(DarraEtherCAT).Assembly.GetName().Version?.ToString(3) ?? "unknown";
        var opts = new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        Console.WriteLine(JsonSerializer.Serialize(report, opts));
    }
}
```

这段做的事：`QuickScan()` 拿逐口结论，`GetNetworkAdapters()` 拿网卡的 MAC / 描述，两张表按 `Name` 对上，最后整段当 JSON 打出来。
它**不建主站、不切状态、不碰总线以外的任何设置**，所以不需要从站也能跑完。

## 6. 读这段 JSON 的字段

在管理员终端里：

```
dotnet run
```

输出是一段 JSON，直接原样贴给用户（就是结论，不用再加工）。字段口径：

| 字段 | 怎么读 |
|---|---|
| `sdk_version` | NuGet 包程序集版本，用来确认装的是哪一版 SDK |
| `adapters[].scan_state` | 本轮结论，取值来自 SDK 的 `NicScanState`：`HasSlaves` / `EmptyBus` / `OccupiedByMaster` / `NotMeasured` / `NotScanned` / `Unsupported` / `Aborted` / `Failed` |
| `adapters[].slave_count` | `null` = 没量到；`0` = 实测空口；`>= 1` = 实测站数 |
| `adapters[].native_code` | SDK 原始码：实测站数 / `0` 空口 / `-2` 未测量 / `-3` 主站占用 |
| `adapters[].error` | 该网卡为什么不能用、哪个字段没取到；空串 = 没异常 |
| 顶层 `error` | 非空 = 枚举或快扫整体失败（SDK 没加载起来之类），把原文给用户 |

## 7. L5（可选）：进 OP 并读身份对象

只有三条同时满足才做这一步：① 手上有一个 `config.deni`（配置工具扫描真从站后导出）；
② 从站真的接在这台机器上；③ L4 已经扫到 `HasSlaves`。缺一条就别跑 —— 跑了也说明不了问题。

```csharp
using System;
using System.Linq;
using DarraEtherCAT_Master;

class Program
{
    static int Main(string[] args)
    {
        // 1. 选那张确实挂有从站的网卡
        var nic = DarraEtherCAT.GetNetworkInfo(needSlavesNum: true)
            .FirstOrDefault(n => n.SlaveNum > 0);
        if (nic == null) { Console.WriteLine("L5 FAIL: 没有扫到从站的网卡"); return 2; }

        // 2. 用 DENI 建站
        var result = new DarraEtherCAT()
            .SetENI(args[0])          // 传入 config.deni 的路径
            .SetNetwork(nic)
            .Build();
        if (!result.Success) { Console.WriteLine("L5 FAIL: Build 失败 - " + result.Message); return 3; }

        DarraEtherCAT master = result;
        try
        {
            // 3. 进 OP
            if (!master.SetState(EcState.OP, out string err))
            { Console.WriteLine("L5 FAIL: 进 OP 失败 - " + err); return 4; }

            // 4. 读身份对象 0x1018:01（任何从站都必有的标准对象）
            byte[] data = master.Slaves[0].CoE.SDORead(0x1018, 0x01);
            if (data == null)
            {
                Console.WriteLine("L5 FAIL: SDO 读 0x1018:01 - " + master.Slaves[0].CoE.LastSdoError);
                return 5;
            }
            uint vendorId = BitConverter.ToUInt32(data, 0);
            Console.WriteLine($"L5 OK: slaves={master.SlaveCount} vendor=0x{vendorId:X8}");
            return 0;
        }
        finally
        {
            master.Close();          // 不调网卡不归还
        }
    }
}
```

跑法（管理员终端，参数是 DENI 路径）：

```
dotnet run -- "C:\EtherCAT\config.deni"
```

退出码就是结论：`0` = 进 OP 成功且身份对象读得到；`2`–`5` = 卡在哪一步。

没有 DENI 时不要用这一步「凑」一个通过。改走 `SetEsiFiles` + `EnableAutoStartup` 让 SDK 从 ESI 生成配置，
细节见 [`darra-ethercat`](../darra-ethercat/SKILL.md)。

L5 成功只能说明：**主站能进 OP，且从站对象字典读得通**。它仍然不证明周期抖动、硬实时隔离与长跑稳定性。

## 8. 按结果决定下一句说什么

**有 `HasSlaves`（`slave_count` ≥ 1）**
扫描通了。可以继续进 OP、读从站，见 https://ethercat.darra.xyz/doc/quick-start/from-sdk 。

**只有 `EmptyBus`（`slave_count` = 0）**
网卡可用，总线上当前确实没有从站。这是**正常且有意义的结论**，不是失败，也不是装坏了。
可以告诉用户：SDK 能扫、这个口是空的；要接设备就接线后再跑一遍。

**全是 `NotMeasured` / `OccupiedByMaster` / `NotScanned` / `Unsupported` / `Aborted` / `Failed`，一个 `EmptyBus` 都没有**
这是**没量到**，不是"没有从站"。按 `scan_state` 和 `native_code` 说清楚原因：
`OccupiedByMaster` = 本机已有主站占着这个口；`NotMeasured` = 没量到；`NotScanned` = 这一轮没送扫；
`Unsupported` = 这个口不能当 EtherCAT 主口；`Aborted` = 被中断；`Failed` = 底层失败，原始码看 `native_code`。

**顶层 `error` 非空**
SDK 没加载起来或整体枚举失败，把异常类型和消息原文给用户，先解决加载问题，别去猜从站。

## 9. 不要做的事

- 不要把 `null` 当 0。`null` 是"没量到"，`0` 是"扫过了、确实空"，两者不能互相冒充。
- 不要把"没量到"说成"没有从站"。这两句话在排查时指向完全不同的方向。
- 不要说"已验证实时性能""硬实时没问题"。L0–L4 只证明 SDK 能加载、网卡能扫、三态结论正确；L5 也只多证明「能进 OP、SDO 通」。
- 不要自动改机器设置、不要绑网卡、不要装或重装驱动。验证就是只读地扫一遍（L5 也只读一个身份对象）。
- 不要跳过 L0：`3010` 没重启就去测，测的是旧驱动 / 旧文件。
- 不要编 API。这份文件里没写的接口，先查 https://ethercat.darra.xyz/doc/sdk/csharp/master/constructors 和 https://ethercat.darra.xyz/ai-prompts.txt 。
- 不要把 `adapters` 里的 `Unsupported` 当成"驱动没装好"的证据：那只是说这个口不能当 EtherCAT 主口。
