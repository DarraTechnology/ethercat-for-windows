---
name: darra-runtime-install
description: >
  把 Darra EtherCAT 运行时装上 / 卸掉 / 升级的完整契约。覆盖：安装包来源与免账号下载、
  版本号规则、SHA256 校验（期望值从 `.sha256` 直链取）、装前三件事（系统 / 管理员 / 网卡是否被别的主站占）、
  静默安装与卸载命令、退出码判读（3010 = 操作成功但需重启生效）、升级直接覆盖安装、
  装完看目录结构 / 日志 / 三处版本号确认「装的是不是这一次的版本」，以及下载被挡 / 哈希不对 /
  安装器报错 / 装完扫不到从站四种失败的处置。
  触发词：安装 / 装一下 / 帮我装 / 部署 / 静默安装 / silent install / install / setup / 安装包 /
  卸载 / 卸载重装 / 重装 / 升级 / upgrade / 3010 / 需要重启吗 / 重启后生效 / 管理员 / 管理员权限 /
  rt-masters / 实时核预留 / 预留核 / sha256 / 校验和 / 退出码 / 自动安装 / 装完在哪 / 日志在哪。
---

# 装上 / 卸掉 / 升级 Darra EtherCAT 运行时

这个技能只做一件事：把 Darra EtherCAT 运行时按官方安装器装好、卸掉或升级。

参数、退出码、目录结构都以这份文件为准，不要自己加参数，也不要猜。

先记住一句话：**这个包会安装实时驱动，还可能预留实时核。动手之前必须跟用户说清楚，拿到确认再执行。**

## 0. 交接：包从哪来

如果上游技能体 [`darra-download`](../darra-download/SKILL.md) 已经跑过，直接拿它 JSON 里的 `path` 和 `sha256`，不要重下。

如果没有，本文第 1、2 节就是「去哪拿 + 怎么验」，照着做一遍即可。

---

## 1. 去哪拿

| 拿法 | 地址 | 要账号吗 |
|---|---|---|
| 官网下载页（人看） | <https://ethercat.darra.xyz/doc/downloads/> | 不要 |
| 安装包固定直链（脚本用） | `https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe` | 不要 |
| 校验文件直链 | `https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe.sha256` | 不要 |

- 公开直链不登录、不带 Token 也能下（2026-11-18 实测 200）。
- `https://ethercat.darra.xyz/downloads` 是 **301**，跳到 `https://ethercat.darra.xyz/doc/downloads/`，不是 404；脚本直接用带 `/doc/` 的地址。
- 包大小：**735,489,640 字节**（约 701.4 MiB，2026-11-18 01:50 UTC 重打包）。**只做当天参考** ——
  每次下载前用 HEAD 取 `Content-Length` 作为期望值，别把 735,489,640 写死进脚本。
- 当前发布版本：**2.13.16**（2026-11-17）。这个数字会变，**以官网下载页表格为准**。
- 文件名固定是 `Darra-EtherCAT-Setup.exe`，**不带版本号**。不要拼 `Darra-EtherCAT-Setup-2.13.16.exe` 这种名字 —— 公开下载位没有它，拼出来是 404。

**版本号规则**：三段数字 `主.次.构建`（例如 `2.13.16`）。公开地址永远指向当前发布版；真实版本要从安装包自身读（见第 6 节），不要从文件名猜。文件名带 `-test` 的是内部测试包，不在公开下载里，**不要当正式版交付**。

**授权**：下载不要账号，运行才要授权。未激活可免费评估：**每次开机、驱动启动后 2 小时内可用**，到期停止总线通信（同一次开机内重开程序不重新计时，重新开机后再给满 2 小时）。长期运行在 <https://shop.darra.xyz/ethercat> 购买。授权/报价/镜像问题走 <support@darra.xyz>。

## 2. 先验再装

下载（Windows 10 1803 起自带 `curl.exe`，`-C -` 支持续传）：

```powershell
$u = 'https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe'
$o = Join-Path $env:USERPROFILE 'Downloads\Darra-EtherCAT-Setup.exe'
curl.exe -L --fail --retry 3 -C - -o $o $u
```

校验（**期望值每次从 `.sha256` 直链现取，不要把哈希写死进脚本**）：

```powershell
$expected = ((New-Object Net.WebClient).DownloadString("$u.sha256") -split '\s+')[0].ToUpper()
$actual   = (Get-FileHash -Algorithm SHA256 $o).Hash
$bytes    = (Get-Item $o).Length

"bytes    = $bytes"
"expected = $expected"
"actual   = $actual"
"match    = $($actual -eq $expected)"
```

判断链，按顺序走：

1. **字节数不对**（≠ 本次 HEAD 的 `Content-Length`；2026-11-18 快照 735,489,640）→ 没下完或被截断，`-C -` 续传或重下。不要拿去装。
2. **字节数对、哈希不对** → 删掉重下（`Remove-Item $o`）。续传可能拼了两个不同版本，续传救不了。
3. **重下两次还不对** → 停手。把 `expected` / `actual` / 字节数 / URL 一起给用户。这通常是代理改写了响应，或拿到了内网缓存的旧件。
4. **别人给的离线副本** → 一样过这条哈希。来源不重要，哈希不对就是不能用。

本文里出现的具体哈希（`0B0CC70C9E358D90…`）只是 2026-11-18 的快照，不是常量。

## 3. 装之前看三件事

**① 系统版本**

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture
```

要求：**Windows 10 / 11，x64**。32 位系统没有包。

顺带确认两个运行库：

```powershell
# .NET Framework 4.7.2 起：Release 值 >= 461808
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release

# Visual C++ Redistributable x64：应能看到一条 2015-2022 或更新的 x64
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName -like '*Visual C++*Redistributable*' |
  Select-Object DisplayName, DisplayVersion
```

缺 VC++ 运行库时程序启动会提示；.NET Framework 低于 4.7.2 先装运行库再装主程序。

**② 管理员权限**

```powershell
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
```

`False` 就先提权再跑。静默安装没有管理员权限会直接失败（退出码 1）。

**③ 网卡有没有被别的 EtherCAT 主站占着**

```powershell
Get-NetAdapter -Physical | Select-Object Name, InterfaceDescription, Status, MacAddress
```

选中要跑总线的那张**物理有线网卡**（Intel / Realtek 这类），再看它上面绑了什么协议：

```powershell
Get-NetAdapterBinding -Name '<上面选中的网卡名>' |
  Select-Object DisplayName, ComponentID, Enabled
```

（`Get-NetAdapterBinding` **没有 `-ComponentType` 参数**，Win10 19045 / PowerShell 5.1 上会直接报
「找不到与参数名称 ComponentType 匹配的参数」。要看被隐藏的绑定项再加 `-AllBindings`。）

要求：

- 这张口是**物理有线**口，不要用无线网卡，也不要用 USB 网卡（USB 网卡最容易出「扫不到从站」，能不用就不用）。
- 这张口上**没有别家 EtherCAT 主站协议**绑着；机器上也没有别家主站服务在跑。有就先解绑或换一张口。
- 这张口之后要被主站**独占**。别拿它当上网口，也别忘了先记下它的网卡名 —— 后面选口、排障都要用。

> 远程会话（WinRM / 计划任务）里 `Get-NetAdapter` 可能报「拒绝访问」，这是 CIM 的会话限制，不是网卡坏了。换这条等价命令：
> ```powershell
> Get-WmiObject Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' |
>   Select-Object NetConnectionID, Name, MACAddress, NetEnabled
> ```

## 4. 先说清楚，拿到确认

动手前对用户说明：

- 要安装 / 升级 / 卸载 Darra EtherCAT 运行时（官方安装包，一次常规软件安装）。
- 会替换机器上的实时驱动；如果带 `--rt-masters`，还会预留对应的实时核。
- 装完可能需要重启才生效。

用户没有确认就不要执行。不许「先装上再说」。**不建议装在日常开发机上**，尤其是用 USB 网卡的笔记本；生产机 / 现场机更合适。

## 5. 安装 / 卸载 / 升级

**安装**（装没装过旧版都是同一条命令，不用先查、不用先卸）：

```powershell
.\Darra-EtherCAT-Setup.exe --silent --install
```

**升级** = 再跑一次上面这条。安装器会按机器上的驱动状态自己处理已装版本：先停旧驱动，再删旧驱动与旧程序文件，然后装本次版本。**不要拆成「卸载 → 重启 → 安装」三步。**

**卸载**（只在用户明确要求时执行）：

```powershell
.\Darra-EtherCAT-Setup.exe --silent --uninstall
```

可选参数，只在需要时加：

| 参数 | 作用 |
|---|---|
| `--path DIR` | 指定安装目录（默认 `C:\DARRA\EtherCAT_Master`） |
| `--no-rt-optimize` | 跳过实时优化 |
| `--rt-masters 1..4` | RT 主站数，也就是预留的实时核数，装完记在机器上 |

`--rt-masters` 只收 1 到 4 的整数。缺值、不是整数、超出范围，安装器**直接失败**（退出码 1639），不会用默认值兜底。不要把它改成 1 再试，先跟用户确认要几个。

没有 `--repair`（加了会被拒）；`--resume` 不是对外参数（那是安装器自己重启后收尾用的）。**别编参数。**

> **实测（2026-11-18，2.13.16）：未知开关不会被拒绝。** `--silent --install --no-such-flag` 会被当成正常安装
> 执行完（退出码 `3010`，真的重装了一遍）。也就是说拼错开关**不会有 1639 报错**，只会静默按有效参数安装。
> 1639 只覆盖「已知参数但值不合法」（`--rt-masters` 缺值/非整数/越界、`--repair`）。
> 所以每条命令都要逐字对照本节，不能靠退出码发现拼写错误。

### 退出码

| 退出码 | 含义 | 下一步 |
|---|---|---|
| `0` | 成功 | 进第 6 节验证 |
| `1` | 失败（未分类异常，或没有管理员权限） | 确认管理员权限 + 包完整性，重试一次；还失败就如实告诉用户 |
| `1602` | 用户取消，动作没有执行 | 问用户还要不要装，不要自动重装 |
| `1603` | 执行中出错（含磁盘空间不足、临时目录写不进去） | 查磁盘空间和权限，处理后再跑 |
| `1604` | 卸载没做全，机器上还剩文件 | 如实告诉用户还剩什么，按提示处理或联系 <support@darra.xyz> |
| `1618` | 另一个安装 / 卸载事务正在跑 | 等它结束再重试，不要同时开几个安装器 |
| `1622` | 日志写不进去，动作已停手 | 先解决磁盘空间、目录写权限，再重跑 |
| `1639` | 命令行参数对这个动作不可用（`--rt-masters` 值不合法也算这个） | 按上面的命令重写，不要自己加参数 |
| `3010` | **操作成功，重启后生效** | 不是失败。见下方 |

**`3010` 单独说**：

- 两档都算成功：① 本趟已装完，重启后生效；② 驱动本趟停不下来，安装器已安排好开机换入，重启后自动收尾，**不必再跑安装包**。
- 告诉用户「已安装成功，需要重启后生效」，**重启时机由用户决定，脚本不要自动重启**。
- 重启前确认三件事：现场程序 / 工程已保存；没有正在跑的总线任务；用户同意这个时间点重启。
- `3010` 没重启之前**不要做任何功能验证** —— 那一步测到的是旧驱动 / 旧文件。

## 6. 装完看什么

**① 目录结构**（默认安装根 `C:\DARRA\EtherCAT_Master`）

```text
C:\DARRA\EtherCAT_Master\
├─ Darra_EtherCAT_Master.exe          GUI 主程序
├─ Darra_EtherCAT_Master.exe.Config
├─ Darra.Core.dll
├─ ESI\                               设备描述文件（.xml）
├─ SDK\
│   ├─ SDK_C\<版本目录>\              C SDK（bin / include / lib / examples）
│   ├─ SDK_Cpp\<版本目录>\            C++ SDK
│   ├─ SDK_CSharp\                    Darra.EtherCAT.Master.<版本>.nupkg
│   ├─ SDK_Java\                      .jar / sources / javadoc / .pom
│   ├─ SDK_Python\                    .whl（CPython 3.12，win_amd64）
│   └─ SDK_Rust\                      .crate + bin\
├─ events.log
├─ core.log
├─ startup_trace.log
└─ crash_log.txt
```

桌面上的「Darra EtherCAT Master」快捷方式指向 `Darra_EtherCAT_Master.exe`；没有快捷方式就直接从安装目录启动。

**② 日志在哪**

都在安装根目录：

| 文件 | 装了什么 |
|---|---|
| `events.log` | 主程序运行事件：启动、扫描、状态变化、警告。排障先看这个 |
| `core.log` | 主站核心诊断输出 |
| `startup_trace.log` | 启动各阶段的耗时记录，用于判断启动慢在哪 |
| `crash_log.txt` | 只有发生未处理异常时才写；没有这个文件是好事 |

**③ 怎么确认装的是这一次的版本，而不是一份旧的**

三处必须互相一致，**缺一处都不算确认**：

```powershell
# a) 程序文件版本
(Get-Item 'C:\DARRA\EtherCAT_Master\Darra_EtherCAT_Master.exe').VersionInfo.FileVersion

# b) 系统的卸载项（安装器登记的权威版本）
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
  Where-Object DisplayName -eq 'Darra EtherCAT Master' |
  Select-Object DisplayName, DisplayVersion, InstallLocation

# c) SDK 目录名（带版本）
Get-ChildItem 'C:\DARRA\EtherCAT_Master\SDK\SDK_C' -Directory | Select-Object -ExpandProperty Name
```

期望结果（2026-11-18，2.13.16）：`2.13.16.0` / `Darra EtherCAT Master  2.13.16  C:\DARRA\EtherCAT_Master` / `darra_ethercat_c-2.13.16-win-x64`。

三处对不上（例如目录里同时有 2.13.15 和 2.13.16 的 SDK 目录）说明是残留混合版本 → **再跑一次覆盖安装**，不要手工删目录、不要手工拼文件。

**④ 跑得起来吗**

装完（`3010` 的话重启完）再做功能验证，按 [`darra-verify`](../darra-verify/SKILL.md) 的 L0–L5 走。最小判据是「能扫一次总线，三态结论正确」。

## 7. 失败了怎么办

### A. 下载被网关挡

表现为 `curl` 非 0 退出、HTTP 403/407、或者下回来是个 HTML 页面（字节数远小于 728,333,928）。按 [`darra-download`](../darra-download/SKILL.md) 第 5 节的顺序试：换直链重试 → 换网络 → 内网镜像（仍用公开 `.sha256` 校验）→ 找 <support@darra.xyz>。

### B. 哈希不对

**停手，不要装。** 按第 2 节的判断链：先看字节数 → 删掉重下 → 两次不对就带着 `expected` / `actual` / 字节数 / URL 找用户或支持。装一个哈希不对的包比不装更糟。

### C. 安装器报错

先读退出码（第 5 节的表），再按这个顺序查：

1. **是不是管理员**（`1` / `1603` 最常见的原因）。
2. **磁盘空间够不够**（装完约 0.91 GB / 371 个文件，安装过程还要临时解包，安装根所在盘建议至少留 3 GB；`1603` / `1622` 都要看这条）。
3. **是不是有另一个安装器在跑**（`1618`）—— 等它结束，不要并行。
4. **参数是否合法**（`1639`）—— `--rt-masters` 只能是 1..4 的整数。
5. 以上都排除、重试一次仍失败：把**退出码 + 完整命令行 + 安装根路径 + 磁盘剩余空间**四样交给用户，并联系 <support@darra.xyz>。**不要靠反复重装去碰运气。**

### D. 装完扫不到从站

先分清是哪种「扫不到」，三态不能混：

| 观测 | 含义 | 怎么办 |
|---|---|---|
| 扫描返回 `null` / 「没量到」 | 这一轮**没测成**（网卡不支持、没选对、被占用、异常） | 看 SDK 返回的原生码：`-2` 未测量、`-3` 主站占用。查网卡是否选对、是否被别的主站占着 |
| 扫描返回 `0` | **实测空口**，总线上确实没有从站 | 这是正常结论，不是装坏了。查网线、从站电源、A/B 口方向 |
| 扫描返回 `N > 0` 但进不了 OP | 站扫到了，状态上不去 | 转 [`darra-ethercat-troubleshooting`](../darra-ethercat-troubleshooting/SKILL.md) |

另外三条高频原因，按顺序排除：

1. **`3010` 之后没重启** → 先重启再测，没重启测的是旧驱动。
2. **选错网卡** → 多张口时逐口扫；无线 / 虚拟 / USB 网卡先排除。
3. **网卡被别的主站占着** → 换一张物理有线口，或解绑别家协议后重试。

**不要用「反复重装」当排障手段。** 装完扫不到，先看日志和三态，再动手。

## 8. 不要做的事

- 不要猜带版本号的安装包文件名，只用固定直链。
- 不要把升级拆成「卸载 → 重启 → 安装」：升级直接覆盖安装。
- 不要自动重启用户的机器。
- 不要在日常开发机上装。
- 不要编造参数（`--repair` 不存在，`--resume` 不是对外参数）。
- 不要在校验和不符时装。
- 不要在没告诉用户的情况下装。
- 不要手工删安装目录、手工拷 DLL、手工绑网卡来「修」安装问题 —— 装卸只走安装器。
- 不要在 `3010` 未重启时给「装好了、能用」的结论。

## 9. 实测

**下载与校验（2026-11-18，测试机 192.168.3.120，Windows 10 19045 x64）**

| 项 | 实测值 |
|---|---|
| 直链 HTTP | `200`，`application/octet-stream`，`Accept-Ranges: bytes` |
| 字节数 | `735,489,640`（2026-11-18 01:50 UTC 重打包后的当天值） |
| 下载耗时 | 发布当天 `35 s`（约 `19.9 MB/s`）；同日下午复测链路中途停滞，速度随出口波动 |
| SHA256 前 16 位 | `B317985FBE4D41DC…` |
| 实测 SHA256 | `B317985FBE4D41DC1AA3BCFED5706474B26232CA61F1B7E5496310C6D369D63D` |
| `.sha256` 直链 | `b317985f…d369d63d`，与磁盘上官方安装包实测哈希一致 |
| 包内版本证据 | 文件版本 `2.13.16.0`；包内清单含 `SDK\SDK_CSharp\Darra.EtherCAT.Master.2.13.16.nupkg`、`darra_ethercat_c-2.13.16-win-x64` |
| 哈希计算耗时 | `1.1 s`（735 MB） |

**装机后的目录与版本（同一台测试机上已装的 2.13.16）**

| 项 | 实测值 |
|---|---|
| 安装根 | `C:\DARRA\EtherCAT_Master` |
| 主程序 | `Darra_EtherCAT_Master.exe`，FileVersion `2.13.16.0` |
| 卸载项 | `Darra EtherCAT Master`，DisplayVersion `2.13.16`，InstallLocation `C:\DARRA\EtherCAT_Master` |
| SDK 目录 | `SDK_C` / `SDK_Cpp` / `SDK_CSharp` / `SDK_Java` / `SDK_Python` / `SDK_Rust` |
| C# SDK | `SDK\SDK_CSharp\Darra.EtherCAT.Master.2.13.16.nupkg` |
| 日志 | `events.log` / `core.log` / `startup_trace.log` / `crash_log.txt` |
| 安装占用 | `0.91 GB` / `371` 个文件（`C:\DARRA\EtherCAT_Master`） |
| 系统要求实测 | Windows 10 19045 x64、管理员、.NET Framework Release `533325`、VC++ 2015-2022 x64 均在位 |
| 安装退出码实测 | `%ProgramData%\Darra\EtherCAT\install.log` 记录安装 `退出码: 3010 (操作成功, 重启后生效)`；卸载 `退出码: 0 (成功)` |
| 参数校验实测 | `--rt-masters 9` / `--rt-masters`（缺值）/ `--repair` 均返回 `1639`，未执行任何安装动作 |
| 未知开关实测 | `--silent --install --no-such-flag` **不报错**，正常安装并以 `3010` 结束 |

> 退出码不是照抄文档：`0` / `3010` 来自测试机 `%ProgramData%\Darra\EtherCAT\install.log` 的真实记录
> （2026-11-18 09:06 卸载 → `0`；09:08 安装 → `3010`），`1639` 与「未知开关被忽略」是当天对同一安装包的实跑结果。
> 其余码（1602 / 1603 / 1604 / 1618 / 1622）本次没有构造出对应场景，语义以官方下载页的命令行说明为准，本文只照抄，不改写。
