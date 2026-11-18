---
name: darra-download
description: >
  从零拿到 Darra EtherCAT Master 的 Windows 安装包。覆盖：官网下载页与固定直链（下载不需要账号）、
  当前发布版本与版本号规则、约 700 MB 安装包的下载与断点续传、SHA256 校验（期望值从 `.sha256` 直链取，
  不抄固定值）、拿不到时的替代路径，最后输出一段 JSON 契约（ok / version / path / bytes / sha256 / source / next）。
  只负责「从零到拿到安装包」，不负责安装：装、卸、升级、退出码与装后验证交给 darra-runtime-install。
  触发词：下载 / 下载安装包 / 安装包在哪 / 哪里下载 / 我要试用 / 试用 / 评估版 / 获取安装包 /
  官网下载 / 直链 / 断点续传 / 校验安装包 / 包多大 / 什么版本 / 离线包 / download / installer / setup.exe。
---

# 拿到 Darra EtherCAT 安装包

## 这份技能体负责哪一段

**技能体是为用户的程序服务的，最终要落到用户实现用户自己的程序。**

所以这份技能体是用户开始写自己程序的第一步：先把运行时和 SDK 拿到机器上，后面用户在自己的工程里引用 SDK、写自己的主站程序。

它**不生成用户的应用程序**。它只保证三件事：

1. 拿到的安装包是**对的**（官方地址、字节数对得上、SHA256 对得上）；
2. 装上的运行时是**活的**（这一步交给 `darra-runtime-install`）；
3. SDK 能在**用户的工程里**被引用，并跑通一次扫描（这一步交给 `darra-verify` 和用户的工程）。

拿到安装包之后交给 [`darra-runtime-install`](../darra-runtime-install/SKILL.md)；装完交给用户的工程。

## 什么时候用这份

用户说的是「下载」「安装包在哪」「我要试用」「怎么获取」「包多大」「什么版本」这类**还没开始装**的问题时，用这份。

用户说「装一下」「卸载」「升级」时，直接去 `darra-runtime-install`，不要在这里绕一圈。

---

## 1. 先判断要哪个版本

| 用户要的 | 有没有公开包 | 说明 |
|---|---|---|
| **Windows 硬实时版** | 有 | 这是唯一公开交付的版本，一个安装包装齐运行时、驱动、GUI 和六语言 SDK |
| Linux 版 | 没有 | 官方口径是「尚未公开发布」，没有公开下载也没有评估版本。**不要暗示能下到 Linux 包，也不要编 Linux 安装命令** |

版本号规则：

- 三段数字 `主.次.构建`，例如 `2.13.16`。
- **公开下载地址不带版本号**，永远指向当前发布版；下到的文件名固定是 `Darra-EtherCAT-Setup.exe`。
- 安装包内部的版本号才是真值：下载后读文件版本（`(Get-Item $o).VersionInfo.FileVersion`，见第 4 节），或装完看卸载项（见 `darra-runtime-install` 第 6 节）。
- 文件名里带 `-test` 的是内部测试包，不在公开下载里。**对外只说正式包**，不要拿 `-test` 包当正式版交付。

当前发布版本：**2.13.16**（2026-11-17 发布）。这个数字会随下次发布变化，**以官网下载页表格为准**，不要把它当常量写死进自动化脚本。

## 2. 要账号吗，要授权吗

**下载本身不需要账号**：直链公开，不登录也能直接下（2026-11-18 实测无 Cookie、无 Token 拿到 200）。

需要授权的是**运行**，不是下载：

- 未激活可以免费评估：**每次开机、驱动启动后 2 小时内可用**，到期停止总线通信。同一次开机内重开程序不重新计时，重新开机后重新给满 2 小时。
- 需要长期运行时，正式授权在购买页购买：<https://shop.darra.xyz/ethercat>
- 授权、报价、内网镜像这类问题：<support@darra.xyz>

## 3. 去哪拿

**官网下载页**（人看的入口：版本表格 + 命令行参数/退出码说明）：

```
https://ethercat.darra.xyz/doc/downloads/
```

> 页面本身**不写包大小和 SHA256**（只有 `.sha256` 直链）。字节数从直链 HEAD 的 `Content-Length` 取，
> 哈希从 `.sha256` 取。
>
> 注意：`https://ethercat.darra.xyz/downloads` 会 **301** 跳到 `https://ethercat.darra.xyz/doc/downloads/`
> （`/doc/downloads` 无尾斜杠是 308），不是 404。脚本直接用带 `/doc/` 的地址即可。

**安装包固定直链**（脚本用这个）：

```
https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe
```

**校验文件直链**（同一地址加 `.sha256`）：

```
https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe.sha256
```

包大小：**735,489,640 字节**（约 701.4 MiB，2026-11-18 01:50 UTC 重打包后的当天值）。
**不要把这个数写死进脚本** —— 同版本重打包会变（本次就从 728,333,928 变成 735,489,640）。
每次用下面第 4 节的 HEAD 取当天 `Content-Length` 作为期望字节数。

不要拼带版本号的文件名（`Darra-EtherCAT-Setup-2.13.16.exe` 这种）。带版本号的名字不在公开下载位上，拼出来是 404。

## 4. 下载并校验

下载（Windows 10 1803 起自带 `curl.exe`，支持断点续传）：

```powershell
$u = 'https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe'
$o = Join-Path $env:USERPROFILE 'Downloads\Darra-EtherCAT-Setup.exe'
curl.exe -L --fail --retry 3 -C - -o $o $u
```

`-C -` 是断点续传：网断了重跑同一条命令会接着下，不会从头来。

下完先看字节数（期望值来自下载前 HEAD 的 `Content-Length`），再算哈希：

```powershell
$head     = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $u
$expectedBytes = [int64]$head.Headers['Content-Length']      # 本次的期望字节数，别写死
$expected = ((New-Object Net.WebClient).DownloadString("$u.sha256") -split '\s+')[0].ToUpper()
$actual   = (Get-FileHash -Algorithm SHA256 $o).Hash
$bytes    = (Get-Item $o).Length

"expectedBytes = $expectedBytes"
"bytes         = $bytes"
"size_match    = $($bytes -eq $expectedBytes)"
"expected      = $expected"
"actual        = $actual"
"match         = $($actual -eq $expected)"
```

> 如果用 `Invoke-WebRequest` 取 `.sha256` 而不是 `Net.WebClient.DownloadString`：响应体是 **`byte[]`**，
> 先 `[Text.Encoding]::UTF8.GetString($r.Content)` 再按空白切分（实测 2.13.16，直接 `.Trim()` 会报
> 「[System.Byte] 不包含名为 Trim 的方法」）。

版本号（填 JSON 的 `version`，不要从文件名猜）：

```powershell
(Get-Item $o).VersionInfo.FileVersion   # 2.13.16.0 -> 版本写 2.13.16
```

**期望值的来源只有一个：同一目录下的 `.sha256` 直链。** 本文里出现的具体哈希只是 2026-11-18 的快照，不是常量 —— 每次下载都要重新取一次。在 Darra 内部环境还可以拿发布清单 `SHA256SUMS.txt` 交叉核对，但对外只认 `.sha256` 直链。

哈希对不上怎么办（按顺序走，不要跳步）：

1. **先看字节数**。不等于本次 HEAD 的 `Content-Length`（2026-11-18 快照 735,489,640）就是没下完或被截断 —— 用 `-C -` 续传或重下，不要拿去装。
2. 字节数对、哈希不对：**删掉重下**（`Remove-Item $o`）。断点续传出来的文件可能拼了两次不同版本，续传救不了。
3. 重下两次还不对：**停手**。把 `expected` / `actual` / 字节数 / URL 四项一起告诉用户，不要「先装看看」。这通常意味着中间有代理改写了响应，或者拿到了内网缓存的旧件。
4. 用户手上已有离线副本（别人拷的、内网镜像来的）：**一样要过这条哈希**。来源不重要，哈希对不上就是不能用。

## 5. 拿不到时的替代路径

按顺序试，每一步都保留证据（HTTP 状态码、返回体的前 200 字节）：

1. **换直链重试**：`curl.exe -L --fail --retry 3 -o $o $u`，去掉 `-C -` 重来一次。Cloudflare 偶发挑战页时，浏览器打开官网下载页点「下载」也能拿到同一个文件。
2. **换网络**：公司代理 / 网关可能拦 `.exe`。换手机热点或另一条出口试一次。
3. **内网镜像**：向 Darra 索取内网镜像地址。拿到镜像件后**仍然用公开的 `.sha256` 校验** —— 哈希是唯一判据，镜像地址不是。
4. **找人**：<support@darra.xyz>，写清楚三件事 —— 要的版本（例如 `2.13.16`）、平台（Windows x64）、卡在哪一步（附 HTTP 状态码或报错原文）。
5. **要买的**：采购与授权走 <https://shop.darra.xyz/ethercat>，下载问题不要混进采购流程。

## 6. 输出契约

拿到包（并且校验通过）之后，**最后一条输出必须是这段 JSON**，不要用散文描述代替：

```json
{
  "ok": true,
  "version": "2.13.16",
  "path": "C:\\Users\\me\\Downloads\\Darra-EtherCAT-Setup.exe",
  "bytes": 735489640,
  "sha256": "B317985FBE4D41DC1AA3BCFED5706474B26232CA61F1B7E5496310C6D369D63D",
  "source": "https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe",
  "next": "darra-runtime-install"
}
```

| 字段 | 含义 |
|---|---|
| `ok` | 只有「下载完成 + 字节数对 + 哈希对」三条同时成立才是 `true` |
| `version` | 从安装包自身读到的版本，不是从文件名猜的 |
| `path` | 本地绝对路径，后续技能体直接用它 |
| `bytes` | 实际字节数（成功时应等于**本次下载前 HEAD 到的** `Content-Length`；2026-11-18 快照 735,489,640） |
| `sha256` | 实测哈希，大写十六进制 |
| `source` | 实际使用的下载 URL |
| `next` | 固定 `darra-runtime-install` |

失败时也输出 JSON，不要吞掉：

```json
{
  "ok": false,
  "reason": "hash_mismatch",
  "version": null,
  "path": "C:\\Users\\me\\Downloads\\Darra-EtherCAT-Setup.exe",
  "bytes": 735489640,
  "sha256": "（实测值）",
  "source": "https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe",
  "next": "darra-runtime-install"
}
```

`reason` 只用这几个值：`download_failed` / `size_mismatch` / `hash_mismatch` / `no_public_build`（用户要 Linux 时）/ `blocked_by_gateway` / `cancelled`。

**不要在校验没通过时输出 `ok: true`。** 下游技能体会直接拿 `path` 去装，装一个哈希不对的包比不装更糟。

## 7. 实测（2026-11-18，测试机 192.168.3.120，Windows 10 19045 x64）

| 项 | 实测值 |
|---|---|
| URL | `https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe` |
| HTTP | `200`，`Content-Type: application/octet-stream`，`Accept-Ranges: bytes`（支持续传） |
| 字节数 | `735,489,640` |
| 下载耗时 | 发布当天 `35 s`（约 `19.9 MB/s`，公网直连）；2026-11-18 下午复测时链路中途停滞（两次分别停在 528 MB / 543 MB）。速度随出口波动，`35 s` 不是承诺 |
| SHA256（前 16 位） | `B317985FBE4D41DC…` |
| 实测 SHA256 | `B317985FBE4D41DC1AA3BCFED5706474B26232CA61F1B7E5496310C6D369D63D` |
| `.sha256` 直链 | 返回 `b317985f…d369d63d  Darra-EtherCAT-Setup.exe`；与磁盘上官方安装包实测 SHA256 完全一致（735 MB 算完 1.1 s） |
| 断点续传 | 造一个 1,000,000 字节半截文件再 `curl -C -`：请求头 `Range: bytes=1000000-`，服务端 `206 Partial Content`，`Content-Range: bytes 1000000-735489639/735489640` |
| 包内版本证据 | 文件版本 `2.13.16.0`；包内清单含 `SDK\SDK_CSharp\Darra.EtherCAT.Master.2.13.16.nupkg` |
| 交叉核对 | 与 Darra 内部发布位同一份文件（字节数、哈希完全一致） |

## 8. 不要做的事

- 不要拼带版本号的下载地址（公开位只有固定名）。
- 不要把本文的哈希抄进脚本当常量（会随版本变），每次从 `.sha256` 取。
- 不要在校验没过时说「先装看看」。
- 不要承诺 Linux 公开包。
- 不要把下载问题混进授权/采购流程，反之亦然。
- 下载完不要在机器上留一堆副本；一个路径，写进 JSON 的 `path`。
