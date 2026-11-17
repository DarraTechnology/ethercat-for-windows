---
name: darra-ethercat-commissioning
description: >
  从零到第一台电机转起来的 Darra EtherCAT 现场投产流程。按现场顺序走十步：
  接线 → 选网口 → 确认从站在线 → 核对拓扑 → 配 PDO → 配 DC → 进 OP → 首动 → 验收 → 固化成 DENI。
  每一步给「做完怎么算过」的判据，以及「做错了会怎样」的安全后果。讲的是现场投产操作，
  不是写主站代码；写代码用 darra-ethercat 技能。API 以
  https://ethercat.darra.xyz/ai-prompts.txt 为准。
  触发词：现场调试 / 投产 / commissioning / 接线 / 菊花链 / 选网口 / 扫描从站 / 扫不到从站 /
  空口 / 没量到 / 拓扑 / 从站位置 / PDO 配置 / RxPDO / TxPDO / DC 配置 / SYNC0 / 参考从站 /
  进 OP / SafeOp / AL 状态码 / CiA 402 / 使能 / 首动 / 电机转起来 / WKC / 验收 / 导出 DENI。
---

# Darra EtherCAT 现场投产：从零到第一台电机转起来

这份技能只讲现场顺序。写主站程序看 [darra-ethercat](../darra-ethercat/SKILL.md)；装运行时看 [darra-runtime-install](../darra-runtime-install/SKILL.md)。现场涉及的 SDK 接口、参数、状态机名称，一律以 https://ethercat.darra.xyz/ai-prompts.txt 为准，不要凭记忆补接口。

> **出处前缀**：`ETH\` = `A:\c\Darra\Darra_EtherCAT_Master\`；`DOC\` = `ETH\云端\ethercat-doc\`。
> 本文所有 `文件:行` 按这个前缀展开；SDK 源码在 `ETH\Darra_EtherCAT_ClassLibrary\CSharp\`。

三条硬顺序，先记住：

1. 先核对拓扑，再使能。
2. 先 0 速度 / 0 增量，再小行程。
3. 任一步判据不过，停在原地修，不带病往下走。

## 总览

| 步骤 | 目标 | 一句话判据 |
|---|---|---|
| 1 接线 | 主站口 → 从站 IN/OUT 逐台串下去 | 上电正常；扫描站数 = 实际台数，顺序 = 接线顺序 |
| 2 选网口 | 一块独立物理有线口专跑 EtherCAT | 自检通过，扫描能扫到站 |
| 3 扫从站 | 分清有站 / 空口 / 没量到 / 扫描失败 | 结论落在明确一格，不把 null 当 0 |
| 4 核拓扑 | 扫描顺序、位置、父站、入口与实物一致 | 逐站身份、站号、父站、入口全对得上 |
| 5 配 PDO | RxPDO/TxPDO 的索引、条目、字节数与 ESI/手册一致 | `Ibytes`/`Obytes` 精确相等，结构体顺序一致 |
| 6 配 DC | 参考从站自动选定，SYNC0 与 LoopCycle 同周期或整数倍 | `Sync0Armed==true`，同步窗口 InSync |
| 7 进 OP | Init→PreOp→SafeOp→OP 每步都过 | 主站和全部从站 OP，AL=0 |
| 8 首动 | 0x06→0x07→0x0F 使能；先 0 速度再小行程 | 使能到 OperationEnabled，位置不漂，小行程可控 |
| 9 验收 | WKC、OP、DC、报警、掉站全过 | 九项清单全绿，缺一项不算跑通 |
| 10 固化 | 导出 DENI，下次直接加载 | 只加载 DENI 也能到 OP，站序/身份一致 |

---

## 1. 硬件接线

### 做什么

**菊花链主链路**（顺序决定从站编号）：

```text
主站专用网口 → 从站1 IN（A 口 / P0）→ 从站1 OUT（B 口 / P1）
             → 从站2 IN → 从站2 OUT → … → 最后一台 OUT
```

- 每台从站**从 IN 进、从 OUT 出**；丝印可能是 `IN/OUT`、`X2A/X2B`、`P0/P1`，以从站手册为准。
- **线型末端**：最后一台 OUT 留空，不接设备。EtherCAT 由末端从站端口内部折返，现场**不要外接终端电阻，也不要把普通交换机/路由器串进链里**。
- **冗余环**：最后一台 OUT 接第二块网卡（主站冗余口）。只有成环才有保护；纯线型即使配了两块网卡，也没有第二条路径。
- **分支**：只能用支持分支的从站/分支器，按该设备手册接线；不要用普通交换机随便分叉。

**线缆与接头**：

- 超五类或六类以太网电缆；现场用屏蔽网线 + 工业级 RJ45 接头。
- 两设备之间最长 100 m；避免与强电电缆并行布线。
- 每段两端卡扣到位，链路中间不串家用路由/交换机。

**上电顺序**（现场默认；电源时序以驱动器手册为准）：

1. 急停/STO 先接好并验证有效；机械处于安全位，人离开运动区。
2. 先上 24 V 控制电源和主站 PC，确认从站面板/链路灯正常。
3. 再上驱动器主电源（动力电）。此时未使能，电机不应动作。
4. 最后启动主站工具/程序，扫描。

### 做完怎么算过

- 逐段核对：主站口 → 第 1 台 IN，第 1 台 OUT → 第 2 台 IN，……，末端 OUT 留空或接冗余口；没有反接、没有多余分支。
- 上电后每台从站电源/链路指示正常，第一台 IN 口有 Link。
- 最终以第 3 步扫描为准：站数 = 实际台数，顺序 = 接线顺序。**线缆好坏不靠万用表猜，以扫描结论为准。**

### 做错了会怎样

- IN/OUT 反接、末端串交换机：扫描 0 站或拓扑错乱；线型中间断一处，断点后面所有从站都不可达。
- 带电插拔总线、带电改线：掉站、端口错误，甚至损坏端口；先断电，或确认该站支持热插拔再操作。
- 上电顺序错、急停/STO 未验证：上电瞬间电机可能动作，人员受伤。

**出处**：`ETH\Darra_EtherCAT_开源案例\COMMISSIONING.md:11-17`（菊花链与专用网卡）、`:21-27`（上电/管理员）；`DOC\docs\ethercat\overview.md:82-98`（线/树/星、100 m、标准连接器）、`:152-153`（末端从站自动折返）；`DOC\docs\ethercat\prerequisites.md:20-32`（网卡、超五类/六类）；`DOC\docs\faq\stability.md:117`（屏蔽网线、工业 RJ45）；`DOC\docs\faq\redundancy.md:20,42`（末端 OUT 接第二网卡；纯线型无冗余保护）；`DOC\docs\faq\error-codes.md:185-191`（线型中间断开、从站上电）。

---

## 2. 选择网口

### 做什么

1. 选**一块独立物理有线网口**专跑 EtherCAT。不要用 Wi-Fi、虚拟网卡、VPN 虚拟适配器、蓝牙/回环/隧道；不推荐 USB 转以太网。
2. 主站与这块口的**绑定由官方安装包完成**。GUI 提示「未绑定网卡，请运行安装器修复绑定」时，重跑官方安装包修复；不要手工绑定、不要手工替换文件。
3. 这块口**不要再拿上网、开共享、做桥接**；要联网另接一块网卡。管理网与主站口分开。
4. Realtek 口按厂商工具关闭 RSS、节能和 offload——否则可能出现「链路 Up 但扫不到从站」。
5. GUI 和测试程序**以管理员身份运行**。
6. 把从站厂商的 ESI XML 放进 GUI 的 `ESI` 目录，启动扫描时自动匹配。

### 做完怎么算过

- GUI「加载网卡」里能看到这块物理口，MAC/描述正常，链路 Up。
- 点顶部「自检」通过，显示「✓ 自检通过, 驱动与网卡可用」，没有「协议未绑定任何网卡」。
- 下一步扫描能扫到从站。

### 做错了会怎样

- 用 Wi-Fi/虚拟/USB 口：GUI 直接判为非有线口，或者链路 Up 但扫 0 站；USB 热插拔还会换网卡实例，绑定随之失效。
- 与上网共用：系统协议栈和非 IP 实时帧互相干扰，表现为丢帧、扫不到、周期抖动。
- 手工绑定/手工换文件：绑定状态与设备实例不一致，重启后失效，严重时整机网络不可用。只走安装包。

**出处**：`ETH\Darra_EtherCAT_开源案例\COMMISSIONING.md:21-27`（专用网卡、关 RSS/offload、管理员）；`DOC\docs\quick-start\from-master-tools.md:70-79`（主网口/冗余网卡/扫描）、`:33-35`（ESI 目录）；`DOC\docs\ethercat\prerequisites.md:20-32`（网卡型号）；`DOC\docs\faq\error-codes.md:51,187-189`（必须选物理网口）；`ETH\Darra_EtherCAT_Master\页面事件\其他页面\加载网卡.cs:968`（未绑定提示）、`:2109`（非有线口不能作主口）；`ETH\Darra_EtherCAT_Master\Main.Designer.cs:1072`（顶部「自检」按钮）；`ETH\Darra_EtherCAT_Master\功能实现\自检向导.cs:53-58`（自检通过口径）；`ETH\内部文档\兼容性与已知问题_Windows11.md:241-262`（有线 802.3、不用虚拟/USB、管理网分开）；`DOC\static\skills\darra-ethercat-windows\SKILL.md:263-265`（专用口不跑上网/共享/桥接）。

---

## 3. 确认从站在线（扫描）

### 做什么

1. 主界面左侧点「切换」打开「加载网卡」。文档站写「选择网卡」，**实际按钮文字是「切换」**。
2. 选「主网口」；有冗余设计才选「冗余网卡」。
3. 点「扫描从站」，看结果表：序号、从站名称、厂商ID、产品代码、版本号、配置地址、别名地址。
4. 已建主站后的重扫，用主界面顶部「扫描」。

### 三态 + 成功，必须分清

| 结论 | SDK 判据 | GUI 现象 | 含义 |
|---|---|---|---|
| 有站 | `ScanOutcome.Success` / `NicScanState.HasSlaves`；`SlaveCount >= 1` | 「发现 N 个从站」，表格有行 | 正常，进第 4 步 |
| 空口 | `ScanOutcome.EmptyBus` / `NicScanState.EmptyBus`；`SlaveCount == 0` | 「未发现从站」（灰字），弹窗提示当前网口未发现从站 | 扫过了，总线上确实 0 站；**不是链路坏，也不是没量到** |
| 没量到 | `SlaveCount == null`；`OccupiedByMaster` / `NotMeasured` / `NotScanned` / `Unsupported` / `Aborted` / `Failed` | 按原因显示：网口被占用、未就绪、网卡不在池、链路未连接、非有线口、扫描收口 | 没有有效读数，**不能写成 0 站** |
| 扫描失败 | `ScanOutcome.Failed` / `OpenFailed` / `Open*` 负码；或 `QuickScan` 抛异常 | 「扫描失败(错误码 N): 原因」 | 通讯/开卡失败，按原因修 |

补充：

- `QuickSlaveCount` 返回**负数是原因码，不是站数**（例如 -2 未测量、-3 主站占用）。
- 本机已有主站占着这个口时，扫描按设计跳过，这是 `OccupiedByMaster`，不是空口。
- 0 站本身不判定链路故障；但线型中间断开确实会让断点后的从站全部不可达。先分清「空口」和「断链」，再看线。

### 做完怎么算过

- 结论落在上表某一格，并且能说出依据（`ScanOutcome`/`NicScanState`/GUI 原文），不是「大概 0 站」。
- 有站时 N = 实际台数；空口/没量到/失败都不往下走。
- 空口时先确认从站是否上电、是否插在这个口，不要急着换线/换从站。
- 没量到/失败时按 GUI 原因处理：占用→关占用程序；未绑定→重跑安装包；链路 down→查线；非有线口→换物理口。

### 做错了会怎样

- 把 `null` 当 0：去查从站/换线，永远修不好。
- 把空口当故障：误换硬件，现场白折腾。
- 把扫描失败当空口：忽略通讯/开卡问题，后面全部白做。

**出处**：`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Static\Network.cs:1527`（QuickScan）、`:1886`（NicScanState 八态）、`:1932-1936`（`SlaveCount` 可空：null=没量到，0=实测空口）、`:2777`（StandardScan）、`:2824-2825`（0 站=EmptyBus）、`:2909`（ScanOutcome）；`DOC\static\ai-prompts.txt:289-295`（三态铁律与 StandardScan）；`ETH\Darra_EtherCAT_Master\页面事件\其他页面\加载网卡.Designer.cs:106`（主网口）、`:115`（冗余网卡）、`:197`（扫描从站）；`ETH\Darra_EtherCAT_Master\Main.Designer.cs:6130`（实际按钮「切换」）、`:1928`（实际按钮「扫描」）；`ETH\Darra_EtherCAT_Master\页面事件\其他页面\加载网卡.cs:1187`（不能把不能开卡写成未发现从站）、`:2442-2448`（稍候再试不等于未发现）、`:2498-2509`（占用/未就绪/网卡不存在/链路 down/非有线）、`:2518`（扫描失败文案）、`:2542-2547`（空口文案）、`:2852`（发现 N 个从站）；`ETH\Darra_EtherCAT_Master\Main.cs:3596`（0 站不判定链路故障）；`DOC\static\skills\darra-ethercat-windows\SKILL.md:279-295`（三个扫描入口与负值语义）。

---

## 4. 核对拓扑

### 做什么

1. **扫描顺序就是菊花链顺序**：`ScannedSlaveInfo.Index` 从 1 开始编号，与 EtherCAT 惯例一致；案例文档也写明「从站编号 = 菊花链顺序」。
2. 逐站对铭牌/ESI：名称、VendorID、ProductCode、RevisionNumber、SerialNumber 与实物一致。
3. GUI 看位置：从站「信息」页有「位置」字段（从站在网络中的位置）；「拓扑」组有设备类型、上级设备、入口、出口、下级设备。
4. GUI 看拓扑图：主界面「诊断」页的拓扑画布画主站 `M`、端口 `0/1`、从站框；悬停显示 `S{n}` 与 `父站: S{parent}.P{port}`。
5. 代码里对位置：
   - `master.Slaves[i]` 是 **0 基数组**；`SlaveNum` / `Index` 是 **1 基**。
   - `ParentStation`：父从站索引（1 基），`0` = 父节点是主站。
   - 扫描结果 `ParentIndex`、`EntryPort`、`ParentPort`、`ActivePorts` 与接线一一对应。
   - **事件回调里的 `slaveIndex` 是 1 基**，取 `Slaves[slaveIndex - 1]`。

### 做完怎么算过

- 扫描列表按顺序逐站与实物对得上：第 `i` 个 `Index=i` 就是链上第 `i` 台。
- 第一台父站 = 主站（`ParentIndex`/`ParentStation = 0`）；后一台的父站 = 前一站。
- 每台的入口端口 = 实际插的口（P0/P1…）；分支拓扑的每个分支父站/入口都对。
- Vendor/Product/Revision 与铭牌、ESI 一致；没有多站、少站、错型号。
- 任一项对不上：停，回第 1 步查线/查站号，不要继续配 PDO/使能。

### 做错了会怎样

- 站号错位 → 轴映射错（点 X 动 Y）、PDO 数据写到错误从站 → 撞机。
- 拓扑与 DENI 不一致 → 进不了 OP，或者进 OP 后数据错位。
- 用别的机器的 DENI → fail closed 或 OP 失败，不要靠改配置硬凑。

**出处**：`ETH\Darra_EtherCAT_开源案例\COMMISSIONING.md:31-34`（从站编号=菊花链顺序）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Static\Network.cs:3527`（Index 从 1 开始）、`:3136-3182`（ScannedSlaveInfo、ParentIndex、Topology、ActivePorts/EntryPort/ParentPort）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Slave\Core.cs:136`（SlaveNum）、`:1309`（Index）、`:2774`（ParentStation，0=主站）；`DOC\static\ai-prompts.txt:325-327`（数组 0 基、事件 1 基）；`ETH\Darra_EtherCAT_Master\功能实现\Info.cs:243`（位置）、`:421-469`（拓扑：上级/入口/出口/下级）；`ETH\Darra_EtherCAT_Master\功能实现\TopologyView.cs:494-503`（S{n}/父站）、`:1250-1257`（主站 M/端口/从站）；`ETH\Darra_EtherCAT_Master\页面事件\其他页面\加载网卡.cs:819-865`（扫描列：序号/名称/厂商/产品/版本/配置地址/别名地址）。

---

## 5. 配置 PDO

### 先读 ESI/手册，不要猜

确认这台从站的 **RxPDO**（主站→从站，输出）与 **TxPDO**（从站→主站，输入）的索引、条目、每项字节数、总字节数。

现场两个已验证的口径：

- 禾川 X3E：RxPDO `0x1600` = **9 B**（`6040` 2 + `6060` 1 + `607A` 4 + `60B8` 2）；TxPDO `0x1A00` = **25 B**（`603F` 2 + `6041` 2 + `6064` 4 + `6061` 1 + `60B9` 2 + `60BA` 4 + `60F4` 4 + `60FD` 4 + `213F` 2）。
- 松下 MINAS A6B：默认 RxPDO `0x1600` = **9 B** / TxPDO `0x1A00` = **23 B**（案例口径）。

ESI 有 PDO 时，GUI 从 ESI 读取；只有 ESI 为空才回退到运行时对象字典。**ESI 版本必须与设备固件匹配**；Revision 不匹配时典型症状是 AL=0x001E 被拒。

### GUI 怎么设

1. 打开从站的「FMMU/SM」页，按「输入」「输出」两表勾选 PDO；数据来源是 ESI。
2. 勾选/取消只记录到「启动计划」，**本次不下发设备**；下次 PreOp→SafeOp 才写入。改完必须走一次状态转换，否则等于没改。
3. 「启动」页可查看/编辑状态转换时写入的 SDO 参数；「开始自动配置」可生成启动参数（可勾选「写入PDO分配」「写入PDO配置」）。

### 代码怎么设（需要显式重映时）

在 **PreOp** 下用 SDO 重映（以松下单 PDO 为例）：

```text
0x1C12:00 = 0
0x1C12:01 = 0x1600
0x1C12:00 = 1
0x1C13:00 = 0
0x1C13:01 = 0x1A00
0x1C13:00 = 1
```

- 每次 `SDOWrite` 看返回值；不要只看「没抛异常」。
- OP 下改 PDO 映射会被拒（`0x08000022`），要回 PreOp。
- 写完后用 `slave.Ibytes` / `slave.Obytes` 和结构体大小自检；对不上就不要进 SafeOp。
- C# 结构体必须是 `struct` + `[StructLayout(LayoutKind.Sequential, Pack = 1)]`，字段顺序 = PDO 条目顺序，总大小精确等于 `Ibytes`/`Obytes`。

### 做完怎么算过

- `slave.Obytes` == RxPDO 字节和；`slave.Ibytes` == TxPDO 字节和；两者都 > 0。
- 结构体 `Pack=1`，字段顺序逐项一致，总大小精确相等（无隐式填充）。
- 进 SafeOp 不报 AL `0x001D` / `0x001E` / `0x0024` / `0x0025`。
- GUI 改了 PDO 的，确认「启动计划」里能看到，并且已经过一次 PreOp→SafeOp。

### 做错了会怎样

- 字节数对不上 → 进不了 SafeOp/OP（AL `0x001D`/`0x001E`）。
- 字节数对但顺序/偏移错 → 读到的状态字/实际位置是别的字段，值看起来「有变化」，一使能就飞车/撞机。
- 结构体没 `Pack=1` → 隐式 padding 让后面全错位。
- OP 改映射 → 被拒；忽略失败强行跑 → 配置与实际不一致。
- GUI 勾了没走状态转换 → 以为改了，实际还是旧映射。

**出处**：`DOC\docs\examples\hcfa-x3e-csp.md:40-47`（X3E PDO 9/25 B 与逐项字节）、`:36`（0x60C2）；`ETH\Darra_EtherCAT_开源案例\COMMISSIONING.md:50-54`（A6B 默认 0x1600 9B / 0x1A00 23B、不可手写 DENI）；`ETH\Darra_EtherCAT_开源案例\Windows\CSharp\Panasonic_CNC_Interpolation\MainForm.cs:1247-1270`（PreOp 重映 0x1C12/0x1C13 与尺寸自检）；`DOC\static\ai-prompts.txt:330-351`（struct/Pack=1/大小/字段顺序）、`:396`（OP 改 PDO 映射被拒）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Slave\Core.cs:1301,2744`（Ibytes/Obytes）；`ETH\Darra_EtherCAT_Master\功能实现\SMFMMU.cs:1125,1176`（从 ESI 构建可选 PDO）、`:1396-1398`（ESI 有 PDO 时不再扫 OD/0x1C12）、`:732,746`（勾选只进启动计划，状态转换才下发）；`ETH\Darra_EtherCAT_Master\功能实现\Startup\Startup.cs:1995`（同义提示）；`ETH\Darra_EtherCAT_Master\Main.Designer.cs:6166-6183`（开始自动配置、写入PDO分配/写入PDO配置）；`ETH\Darra_EtherCAT_Master\功能实现\State.cs:1097`（ESI Revision 不匹配，典型 AL=0x001E）；`DOC\docs\ethercat\beginner-guide\sm-fmmu.md:113-120`（SM/FMMU 由主站按 ESI 自动配置）；`DOC\docs\faq\device-troubleshooting.md:16-26`（厂商差异、ESI 版本、Startup/DC 差异）；`DOC\docs\faq\error-codes.md:80-92`（AL 0x0017/0x001D/0x001E/0x0024/0x0025）。

---

## 6. 配置 DC

### 先判断能不能配

- `slave.HasDC`（ESC 硬件能力）和 `slave.HasEsiDcSync`（ESI 是否声明 DC-Sync0）**都为 true 才配 SYNC0**。
- 只看 `HasDC` 会给「硬件说支持、ESI 没声明」的站强写 SYNC0，从站可能拒绝进 OP 且不给错误码。
- 不支持/没声明：按 FreeRun 或 SM 同步跑，知道精度会下降；不要硬配。

### 谁做参考从站

- 参考从站由**主站自动选定**。GUI 的 DC 页只读显示「参考时钟从站索引」；SDK 只读 `master.Diagnostics.DcReferenceClockSlave`（配 `DcReferenceClockSlaveKnown`）。
- `ConfigureDC` 没有「参考从站」参数；不要试图手工指定。

### 周期与 SYNC0

- 先设 `master.Config.LoopCycle = N`，读回确认 == N。
- `ConfigureDC(N)`：SYNC0 周期与 LoopCycle **一致，或为其整数倍**。「数据未到达的同步没有意义」。
- 过采样设备才允许 SYNC0 < LoopCycle，且要设备硬件与 PDO 映射专门支持；普通项目不要这么配。
- GUI：DC 页「SYNC0周期(×PDO)」填**倍率**（默认 1 = 1×PDO 周期），不是填 ns；「偏移(%周期)」首次保留默认 70%（等价于自动默认值 70%）；清空则按 ESI 显式 > 用户显式 > 70% 解析。
- **偏移填 0 = 字面 0 相位**，从站会报同步错误（AL `0x002C`）并掉出 OP；首次调试不要填 0。
- DC 配置要在 **PreOp** 做；GUI 运行中只读。

### CSP 额外一条

`0x60C2` 插补周期必须与 `LoopCycle` 同值，在 **SafeOp（映射完成）后**写入并读回；PreOp 写会被 SM 重配清掉。500 µs = `0x60C2:01 = 50`、`:02 = -5`。

### 做完怎么算过

- `slave.Sync0Armed == true`。三态：`true`=已武装；`false`=有判据的未武装（含无 DC 能力站）；`null`=读不到。**不要把 null 折成 false。**
- `GetSyncWindowStatus()` 对 DC 从站 `Applicable=true` 且 `InSync=true`，`DiffNs` 在窗口内。
- `master.GetMaxSyncDifference()` / `MaxSyncDifferenceNs` 不是 `null`，也不是 `-1`（-1=确定没有 DC-active 站）。
- `0x1C32` / `0x1C33` = **2**（DC 模式）；FreeRun 下 InSync 恒 false，不代表已同步。
- CSP 的 `0x60C2` 读回 == 期望值。

### 做错了会怎样

- SYNC0 与 LoopCycle 非整数倍/相位错 → AL `0x001A` / `0x002D` / `0x0034`，掉 OP，运动抖动/跟随误差。
- 偏移 0 → AL `0x002C` 掉 OP（GUI 有确认门）。
- 强配 ESI 未声明 DC 的站 → 拒绝进 OP，且没有可读错误码，容易被误判成别的问题。
- `0x60C2` 不等于 LoopCycle → 驱动器按错误节拍解释目标位置，速度被缩放/跟随误差大。

**出处**：`DOC\docs\examples\hcfa-x3e-csp.md:100-113`（HasDC + HasEsiDcSync、只看 HasDC 的风险）、`:117-129`（0x60C2 与读回）；`DOC\docs\quick-start\advanced\dc.md:14-34`（GUI DC 页、DcSyncMode、SYNC0、参考钟）、`:44-54`（相位优先级、0 是字面 0）、`:56-65`（同步窗口）；`DOC\docs\sdk\csharp\master\dc.md:60-70`（1ms 配置、SYNC0 与 LoopCycle 一致或整数倍、过采样例外）；`DOC\static\ai-prompts.txt:507-527`（ConfigureDC、shiftNs 三态、Sync0Armed、同步校验、0x1C32/0x1C33）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Slave\DC.cs:1102,1277,2398,2477`（ConfigureDC 无参考从站参数）、`:1710`（Sync0Armed 三态）、`:1793`（GetSyncWindowStatus）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\MasterDiagnosticsInfo.cs:2025-2032`（参考钟只读）；`ETH\Darra_EtherCAT_Master\功能实现\DC.cs:1368`（运行中只读，PreOp 设置）、`:221`（读取参考时钟从站索引）、`:3593-3609`（偏移 0 的 AL 0x002C 警告）；`ETH\Darra_EtherCAT_Master\Main.Designer.cs:3429-3464`（SYNC0 倍率、偏移默认 70%）。

---

## 7. 进 OP

### 首次调试分步切，不要直接点 OP

- 顺序：Init → PreOp → SafeOp → OP。
- SDK 的 `SetState(OP)` 会自动链式完成，但首次调试建议逐步调用，知道卡在哪一步。
- **不要在外面再包一层重试**：`SetState` 自带每步 5 s 超时，失败只续跑失败步，不整段重跑。

### 每步判据与常见失败

| 步骤 | 这一步在做什么 | 通过判据 | 常见失败 |
|---|---|---|---|
| Init | 寄存器/SII，识别身份 | 能读 Vendor/Product/Revision；配置地址分配 | 拓扑/供电/从站故障 |
| PreOp | 邮箱通信、SDO、PDO 映射 | SDO 能读 `0x1018`；PDO 映射写入成功 | 邮箱配置/ESI 不匹配 |
| SafeOp | SM2/SM3/FMMU、启动参数、DC 参数；输入有效，输出保持安全值 | `slave.State == SafeOp`；`Ibytes > 0` 且输入在刷新；输出仍未生效 | AL `0x0017` / `0x001D` / `0x001E` / `0x0024` / `0x0025` |
| OP | DC PLL 锁定；输出有效 | `master.State == OP`；所有从站 `State == OP`；`IsLost=false`；`AlStatusCode=0` | AL `0x001A` / `0x002D` / `0x0034` / `0x001B` |

### 失败怎么读

- `SetState(OP, out err)` 的 `err` 会带实测聚合状态和逐站 AL 码，例如「停留在 安全操作 的从站 3, AL=0x001F」。先看这个，不要重装。
- AL 码读不到写「AL 未知(无应答)」，这和从站明确回了 AL 码是两回事。
- 常见 AL：`0x0017` SM 配置；`0x001D`/`0x001E` 输出/输入配置；`0x0024`/`0x0025` 输入/输出映射；`0x001A`/`0x002D`/`0x0034` 同步/DC；`0x001B` SM 看门狗超时；`0x0003` 无效设备设置（耦合器缺模块）。

### 做完怎么算过

- `master.SetState(EcState.OP, out err)` 返回 true，且读回 `master.State == EcState.OP`。
- 所有 `master.Slaves[i].State == EcState.OP`；`IsLost` 全 false；`AlStatusCode` 全 0；`SlaveCount` = 实际台数。
- 不能有从站停在 SafeOp/PreOp；如果有，按 AL 码回去修，不要「跳过」。

### 做错了会怎样

- 外层再包重试 → 重复 SDO/状态切换，故障被掩盖，定位更难。
- 用「登记可选组/跳过缺席站」来凑 OP → 掩盖接线/供电问题；可选组只用于设计上允许缺席的站。
- 有站没到 OP 就使能 → 部分轴动、部分不动，机械扭伤/撞机。
- 进 OP 时输出从安全值变成有效值 → 如果输出点接着执行机构，可能立刻动作；进 OP 前确认 STO/急停/输出安全。

**出处**：`DOC\docs\ethercat\beginner-guide\state-machine.md:22-28`（状态值）、`:39-68`（各状态功能与转换条件）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\State.cs:3465-3489`（SetState 链式转换、5s 每步、只续跑失败步）；`DOC\static\ai-prompts.txt:305-316`（SetState 写法、禁止外层 retry）；`DOC\docs\sdk\csharp\master\api.md:256-259`（失败文本含逐站 AL）；`DOC\docs\faq\error-codes.md:72-105`（AL 码表与处理）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Slave\Core.cs:3136`（Slave.State）、`:3246`（AlStatusCode）、`:1328`（IsLost）；`ETH\Darra_EtherCAT_Master\Main.Designer.cs:819,848-890`（「状态机」与 INIT/PRE_OP/SAFE_OP/OP 瓦片）；`ETH\Darra_EtherCAT_Master\功能实现\State.cs:85-86,387-406`（切换等待/失败与逐站失败清单）；`DOC\docs\quick-start\advanced\hot-connect.md:16-24`（可选组默认没有，所有从站按必须在线处理）。

---

## 8. 首动

### 先决条件（缺一条都不许使能）

- 主站和全部从站 OP；WKC 满（第 9 步）；无 AL 故障；`slave.CoE.CiA402 != null`。
- `0x603F = 0`（无故障）；CSP 下 `0x6060=8` 且 `0x6061` 读回 8。
- 目标值先等于实际值：CSP 写 `0x607A = 0x6064`；CSV 写 `0x60FF = 0`；CST 写 `0x6071 = 0`。
- 软限位 `0x607D`、每轴最大速度/加速度先设好；硬件限位/急停/STO 已验证有效。
- 机械：首次试动脱开负载或留出安全行程，人离开运动区，手放在急停上。

### 使能序列（CiA 402）

- **Shutdown `0x06` → SwitchOn `0x07` → EnableOperation `0x0F`**。
- 每一步读 `0x6041` 确认到位再发下一步；不能按固定延时开环推进，也不能同一周期连发三步。
- 判据：

```text
(sw & 0x4F) == 0x40  → Switch on disabled，发 0x06
(sw & 0x6F) == 0x21  → Ready to switch on，发 0x07
(sw & 0x6F) == 0x23  → Switched on，发 0x0F
(sw & 0x6F) == 0x27  → OperationEnabled，保持 0x0F，可运动
(sw & 0x4F) == 0x08  → Fault，先排除故障再复位
```

- 用 SDK：进 OP 后调一次 `drv.Enable()`（只在 OperationEnabled 返回 true；Fault 下返回 false，先 `FaultReset()`）；**不要放进 PDO 同步回调**。
- 故障复位：`0x6040` bit7 是上升沿且 **bit2 必须为 1**；正确写法 `0x0006 → 0x0086`，**不要写 `0x0080` / `0x0000`**（bit2=0 会同时触发 Quick stop）。同步回调用 `FaultResetStep(0/1)`，不要用会阻塞的 `FaultReset()`。
- **GUI 没有使能按钮**：GUI 的「CiA 402」页只做状态监视，页面原文提示使能、模式切换和运动控制走用户程序或厂商专用工具；不要在现场找 GUI 的「使能/点动」按钮。

### 先给 0 速度 / 小行程

1. **第 1 段（无运动门）**：保持目标 = 实际，连续 **100 个真实 PDO 周期**。确认实际位置不漂、状态可识别且非 Fault、`0x603F=0`、`0x6061=8`；主从站保持 OP、WKC 匹配。
2. **第 2 段（小行程）**：给一个小增量/小速度（例如 1/4 圈或 1 mm，低速），确认方向、最终位置和停止都正常。
3. **第 3 段（工艺轨迹）**：再逐步放大到全行程/全速；不要一上来就跑全行程。

### 做完怎么算过

- `drv.Enable()` 返回 true，或状态字 `(sw & 0x6F) == 0x27`；实际位置在无运动段不漂。
- 小行程：方向正确，到位误差在工艺允许内；无 `0x8611` 跟随误差、无新故障；停止命令能停。
- 急停/STO 实测一次有效（按项目安全流程）；**软件 QuickStop 不能替代硬急停/STO**。

### 做错了会怎样

- 目标没先等于实际 → 使能瞬间跳到旧目标，撞机。
- 一上来写 `0x0F`、同一周期连发 `06→07→0F` → 驱动器可能拒绝或进入意外状态。
- 方向未确认就放大行程 → 撞硬限位/机械。
- CSP 空闲/握手写 `0x0000`，或 `0x001F` bit4（禾川 X3E）→ 锁存 `0x7500`，丢使能。
- 故障反复复位不查 `0x603F`/`0x1003` → 带病运行，扩大损坏。
- 用软件 QuickStop 代替硬急停/STO → 安全功能不达标。

**出处**：`DOC\docs\ethercat\device-profiles\cia402.md:59-82`（命令表、状态掩码、QuickStop 出口、故障复位 bit2=1）；`DOC\static\ai-prompts.txt:393-428`（Enable 语义、FaultReset、目标值每周期写）；`DOC\docs\sdk\csharp\cia402.md:132-142`（Enable 只在 OperationEnabled 返回 true）；`ETH\Darra_EtherCAT_ClassLibrary\CSharp\Master\Slave\CiA402.cs:1584`（Enable）、`:1639`（FaultReset 阻塞、仅 OP）、`:2678`（FaultResetStep）、`:69`（ModeCiA402：CSP=8/CSV=9/CST=10）、`:34`（StateCiA402）；`ETH\Darra_EtherCAT_开源案例\Windows\CSharp\HCFA_X3E_QuarterTurn\README.md:83-89`（无运动门 100 拍、三阶段、5 秒截止）；`ETH\Darra_EtherCAT_开源案例\COMMISSIONING.md:58-60`（上电安全、未使能不动）、`:66-71`（低速小目标）、`:95-97`（软限位/最大速度）；`DOC\docs\examples\hcfa-x3e-csp.md:30-38`（握手、停止语义、0x0000/0x001F 的 0x7500 风险）、`:131-138`（目标=实际）、`:166-240`（回调按状态字推进）；`DOC\docs\quick-start\from-sdk.md:404-413`（握手/状态判定/目标=实际）；`ETH\Darra_EtherCAT_Master\功能实现\CiA402.cs:185-186`（GUI 的 CiA 402 页仅状态监视，使能/运动走 SDK 或厂商工具）。

---

## 9. 验收清单

全部满足才叫「跑通」；缺一项都不算。

| # | 项 | 判据 | 怎么读 |
|---|---|---|---|
| 1 | 主站 OP | `master.State == EcState.OP` | SDK / GUI 状态 |
| 2 | 从站全 OP | 所有 `Slave.State == OP`；`IsLost=false`；`AlStatusCode=0`；`SlaveCount`=实际台数 | SDK / GUI 在线数、诊断 |
| 3 | WKC 满 | 进 OP 后 2 s 内 `WKC == ExpectedWKC` 且 `ExpectedWKC != 0`；无 WkcShortage 事件 | `master.Diagnostics.WKC` / `ExpectedWKC` |
| 4 | DC in-sync | DC 站 `Sync0Armed==true`；`GetSyncWindowStatus().Applicable && InSync`；`MaxSyncDifferenceNs` 在窗口内；`0x1C32/0x1C33=2`（DC 模式） | SDK / GUI DC 页 |
| 5 | 无报警/故障 | AL=0；`0x603F=0`；无 `0x8611` 跟随误差；驱动器非 Fault | SDK / GUI CiA402 页 |
| 6 | PDO 有效 | `Obytes`/`Ibytes` 与映射一致且 >0；状态字/实际位置在刷新 | SDK / GUI PDO 页 |
| 7 | GUI 诊断 | 健康值正常；帧错误/丢失帧/校验错误/超时帧为 0 或稳定不增长；丢包率 0 | 「诊断」页 |
| 8 | 长跑 | 验收时段内从站掉线 0、看门狗 0 次、无 WKC 缺口趋势 | 状态栏/诊断/events.log |
| 9 | 安全 | 急停/STO 实测有效；软限位/最大速度生效；未使能不动 | 现场实测 |

### 做完怎么算过

上表九项全满足，且下面三条口径都成立：

- 「能连上 / 状态字是 OP」不等于总线健康；以 WKC、逐站 AL、DC 窗口为准。
- `actual < expected` = 有从站没贡献（掉站/热插拔），报警 + 诊断；**不降 expected、不停 PDO**。
- 截图不算证据；以读到的数值/日志为准。

### 做错了会怎样

- WKC 不满就使能 → 丢帧时目标值没到，飞车/丢步。
- 有站不在 OP 就验收 → 现场偶发停机。
- DC 不 in-sync 就验收 → 多轴同步误差，产品尺寸/节拍不稳。
- 用「跑了几分钟没炸」代替清单 → 长跑才暴露的掉站/看门狗问题留到客户现场。

**出处**：`DOC\docs\examples\hcfa-x3e-csp.md:142-153`（WKC 必须 actual==非零 expected，2 s 有界等待）；`DOC\docs\sdk\csharp\master\diagnostics.md:56-57`（WKC/ExpectedWKC 语义，expected 永不动态下调）；`DOC\static\ai-prompts.txt:519-527`（Sync0Armed、MaxSyncDifference、GetSyncWindowStatus、0x1C32/0x1C33）；`DOC\docs\faq\stability.md:108-117`（连续运行、掉线 0、丢包 0、看门狗 0、线缆/接头）；`DOC\docs\quick-start\from-master-tools.md:337-343`（简易诊断：状态/频率/抖动/链路质量/丢包率）、`:374-388`（诊断三层：Master/Link/Frame）；`ETH\Darra_EtherCAT_Master\功能实现\状态诊断.cs:1013-1019`（在线/离线从站计数）；`DOC\docs\faq\motor-control-troubleshooting.md:19-28`（主站 OP、从站 OP、PDO 有效、数据刷新）。

---

## 10. 固化成配置（DENI）

### 导出

1. 确认主站已初始化、扫描到全部从站、状态在 **SafeOp 或 OP**。否则导出的代码会缺 PDO 结构体/过程数据访问。
2. GUI 顶部「导出」→「模板程序」打开导出窗口；左侧「DENI 配置文件」生成配置；`Ctrl+S` 或工具栏 `Export`/`Save` 保存为 `config.deni`。
3. DENI 包含：网口 + 从站 + PDO 映射 + DC + 启动参数；带 SHA-256 完整性校验；下次「导入」即可加载。
4. **DENI 必须由 GUI 扫描真实从站后导出，不可手工编写**；拓扑不符会进不了 OP。

### 下次加载

```csharp
var result = new DarraEtherCAT().SetENI(@"config.deni").Build();
if (!result.Success) { Console.WriteLine(result.Message); return; }
var master = result.Master;
```

- 用 DENI 时不需要再 `SetEsiFiles`；`EnableAutoStartup` 只补充未配置的从站。
- 换电脑/换网口：`.SetNetwork("以太网 1")` 覆盖 DENI 里的网口；多网卡机器按 DENI 的 Source MAC 自动匹配，匹配不唯一时显式指定。
- 加载 DENI 比自动扫描快约 50%（实测 7.4 s vs 15.2 s）。

### 做完怎么算过

- 下次启动只加载 DENI、不重新扫描，也能到 OP。
- `SlaveCount`、站序、Vendor/Product/Revision 与导出时一致。
- WKC 满、所有从站 OP、DC 已武装——第 9 步清单仍全过。
- 改了接线/PDO/DC 后重新导出，旧 DENI 不继续用。

### 做错了会怎样

- 手改 DENI（改站号/PDO/DC）→ 完整性校验失败或配置与实际不符；轻则进不了 OP，重则按错误映射运动。
- 用别的机器的 DENI → 拓扑/网卡不匹配，fail closed 或 OP 失败。
- 改了现场接线不重导 → 站序/轴映射错，点 X 动 Y。
- FreeRun 的 DENI 用在强制 DC SYNC0 的案例 → GUI 直接拒绝连接。

**出处**：`DOC\docs\quick-start\from-master-tools.md:395-420`（导出/导入、DENI 内容、SHA256）；`ETH\Darra_EtherCAT_Master\Main.Designer.cs:980,999`（导出/模板程序）；`ETH\Darra_EtherCAT_Master\导出\导出.cs:367-395`（生成 DENI 配置）、`:742-745`（默认文件名 `config.deni`）；`ETH\Darra_EtherCAT_Master\Main.cs:3924-3947`（导出前置：已初始化、有从站、SafeOp/OP）；`ETH\Darra_EtherCAT_开源案例\COMMISSIONING.md:50-54`（不可手工编写）、`:111`（DENI Source MAC 指认网卡）；`DOC\static\ai-prompts.txt:261-277,297-301`（DENI 内容、SetENI/Build、SetNetwork 覆盖）；`DOC\docs\ethercat\beginner-guide\eni-file.md:77-92`（DENI 加载快 50%、生产推荐 DENI）；`ETH\Darra_EtherCAT_开源案例\Windows\CSharp\HCFA_X3E_QuarterTurn\README.md:14-19`（GUI 强制 DC Sync0，FreeRun 被拒）。

---

## 不要做的事（现场）

- 不要用 Wi-Fi、虚拟网卡、USB 转以太网口当主站口；不要把主站口拿去做上网/共享/桥接。
- 不要手工绑定或手工替换安装包文件；GUI 报未绑定就重跑官方安装包。
- 不要在未核对拓扑、未确认 WKC 时使能。
- 不要一进 OP 就写目标；不要目标 ≠ 实际时使能。
- 不要在 PDO 同步回调里做 SDO、Sleep、文件、UI 刷新、等锁。
- 不要在 OP 改 PDO 映射；不要手改 DENI。
- 不要把 `null` 当 0 站；不要把空口当故障；不要把「能连上」当总线健康。
- 不要反复复位故障/网卡/驱动；第一次失败就停，查根因。
- 不要用软件 QuickStop 代替硬急停/STO。

## 安全提示清单（做错了会怎样）

| # | 动作 | 后果 | 必须怎么做 |
|---|---|---|---|
| 1 | 未核对拓扑就使能 | 轴映射错/撞机 | 先逐站对身份、位置、父站、入口 |
| 2 | 使能前目标 ≠ 实际 | 使能瞬间跳变 | 先 `0x607A=0x6064` / `0x60FF=0` / `0x6071=0` |
| 3 | 一进 OP 就发运动命令 | 未确认状态/无运动门 | 先 100 个真实 PDO 周期的无运动验证 |
| 4 | 首次就全行程/全速 | 撞限位/超速/飞车 | 低速小增量，方向确认后再放大 |
| 5 | 未设软限位/最大速度 | 越程、撞机 | 先设 `0x607D` 和轴参数，再动 |
| 6 | 用软件 QuickStop 代替硬急停/STO | 安全功能不达标 | 硬回路独立接线并实测 |
| 7 | SYNC0 与 LoopCycle 非整数倍，或偏移填 0 | 掉 OP/同步错误 | 同周期或整数倍；偏移首次留空 |
| 8 | 强配 ESI 未声明 DC 的站 | OP 被拒且无错误码 | 先查 `HasDC` + `HasEsiDcSync` |
| 9 | PDO 字节数/顺序错 | 飞车/数据错位 | 尺寸 + 顺序 + `Pack=1` 自检 |
| 10 | OP 下改 PDO 映射 | 被拒/配置不一致 | 回 PreOp 再改 |
| 11 | WKC 不满/有站不在 OP 就使能 | 丢帧/部分轴动 | 第 9 步清单全过再使能 |
| 12 | 手改 DENI/用错拓扑 DENI | OP 失败/错误运动 | 只从真实扫描导出，改线后重导 |
| 13 | 共用网口/虚拟网口 | 丢帧/扫不到 | 独立物理有线口，专用 |
| 14 | 手工绑/换安装包文件 | 绑定失效/整机网络不可用 | 只走官方安装包 |
| 15 | 反复复位网卡/驱动 | 设备进入不可用状态 | 第一次失败就停，查根因 |
| 16 | 带电插拔总线/带电改线 | 掉站/端口损坏 | 断电，或确认支持热插拔 |
| 17 | 把 `null` 当 0 站/空口当故障 | 误判/误换硬件 | 三态分清，按 SDK/GUI 原文归类 |
| 18 | 用截图或「能连上」当验收 | 漏掉 WKC/DC/掉站 | 读数值、AL 码、同步窗口、日志 |

## 一句话

接线对、拓扑对、PDO 对、DC 对、WKC 满、全站 OP、无报警——再让电机以 0 速度和小行程动第一下。任何一步不满足，停在那里修，不要带病往下走。
