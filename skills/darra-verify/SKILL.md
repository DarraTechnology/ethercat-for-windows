---
name: darra-verify
description: >
  装完 Darra EtherCAT 运行时之后，验证 SDK 到底能不能用：新建 C# 控制台工程、加 NuGet 包、
  列出网卡、逐口快扫，输出一段机器可读 JSON（adapters[] / scan_state / slave_count / sdk_version）。
  扫描结论严格三态：null = 没量到，0 = 实测空口（EmptyBus），N > 0 = 实测 N 个从站。
  没有从站也能跑，空口是正常结论。只证明 SDK 能加载、网卡能扫、结论三态正确，
  不证明实时性能，也不证明从站能进 OP。
  触发词：验证 / 怎么确认装好了 / 装完能跑吗 / 有没有装好 / 自检 / 测试一下 / 冒烟测试 /
  smoke test / verify / test / 扫不到从站 / 空口 / 三态。
---

# 装完之后自己验证

这个技能只做一件事：在用户机器上跑一个小程序，拿到一段能引用的结论 —— SDK 能不能加载、网卡能不能扫、扫出来的三态对不对。

它不是演示程序，也不是性能测试。跑完你能说的只有一句话的范围：**SDK 加载正常，网卡枚举正常，扫描结论是三态里的哪一态。**
再往上的"抖动多大 / 是不是硬实时 / 从站能不能进 OP"，这条路径证明不了，不要顺着往下说。

## 1. 先确认前提

- 已经装好 Darra EtherCAT 运行时。没装先回去走安装技能：[`darra-runtime-install`](../darra-runtime-install/SKILL.md)
- Windows x64，管理员权限（SDK 的环境要求就是管理员，普通权限跑不出可信结果）。
- 机器上有没有从站都行。**没有从站也是有效结论**，不需要为了"验证"去接设备。

## 2. 建工程、加包

.NET 版本要求（C# SDK 概述）：.NET Standard 2.0 类库，.NET Framework 4.6.1+ 与 .NET 6–8 已验证；net9 / net10 要 `UseAppHost=false` 并用 `dotnet app.dll` 跑，否则改用 net8。
所以这里直接选 net8.0：

```
dotnet new console -n DarraVerify -f net8.0
cd DarraVerify
dotnet add package Darra.EtherCAT.Master
```

装不装得上 net8 SDK 看用户机器。只有 net9 / net10 时按上面那条说明改工程，别硬扛。

## 3. 换成下面这份 Program.cs

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

## 4. 跑，然后把 JSON 原样给用户

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

## 5. 按结果决定下一句说什么

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

## 6. 不要做的事

- 不要把 `null` 当 0。`null` 是"没量到"，`0` 是"扫过了、确实空"，两者不能互相冒充。
- 不要把"没量到"说成"没有从站"。这两句话在排查时指向完全不同的方向。
- 不要说"已验证实时性能""硬实时没问题"。这条路径只证明 SDK 能加载、网卡能扫、三态结论正确。
- 不要自动改机器设置、不要绑网卡、不要装或重装驱动。验证就是只读地扫一遍。
- 不要编 API。这份文件里没写的接口，先查 https://ethercat.darra.xyz/doc/sdk/csharp/master/constructors 和 https://ethercat.darra.xyz/ai-prompts.txt 。
- 不要把 `adapters` 里的 `Unsupported` 当成"驱动没装好"的证据：那只是说这个口不能当 EtherCAT 主口。
