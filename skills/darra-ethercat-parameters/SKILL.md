---
name: darra-ethercat-parameters
description: >
  读写 Darra EtherCAT 从站参数时使用：SDO 读写、abort 码判读、对象字典加载、
  CiA 402 常用对象、状态字、掉电保存、PDO 映射。覆盖 C# / Python / Java / C / C++ / Rust。
  索引一律标注「标准值，厂商可能有差异」，写代码前先读对应语言 SDK 页；
  拿不到手册就报缺资料，不要猜索引。触发词：SDO、对象字典、OD、abort、0x6040、
  0x6041、0x6060、0x6061、0x607A、0x6064、0x606C、0x6077、0x603F、0x6502、
  CiA 402、CiA402、参数保存、0x1010、PDO 映射、0x1600、0x1A00、状态字、读参数、写参数。
---

# Darra EtherCAT 参数与对象字典

初始化、进 OP、PDO 周期读写、DC、Enable 这些看 `darra-ethercat`。这份只管**参数**：SDO 怎么读写、读失败怎么判、对象字典从哪来、CiA 402 的索引是多少、状态机怎么读、参数怎么掉电保存、PDO 映射怎么改。

索引与 API 全部按仓内源码核对过，出处见文末「出处」。**索引是标准值，厂商可以有差异；差异以厂商手册为准。**

## 一句话总则

1. SDO 是**阻塞的邮箱通信**，不进周期回调。
2. 字节宽度必须等于对象宽度，短了长了都要报 abort，不要靠库补零蒙过去。
3. 读回 `null` / `None` / `false` 就是失败，**先读 abort 码再决定重试还是停**，不要 catch 掉。
4. 读参数走条目读接口（`TryGetBytes` / `get_value()` / `read_u16()`），**写参数只用 `.Bytes` / `SDOWrite()`**，只读的值属性不要赋值。
5. 索引先查对象字典或手册，查不到就报缺资料，**不要编索引**。

## SDO 的四个入口

按「要不要对象字典」分两条路，不要混用。

| 想做的事 | C# | Python |
|---|---|---|
| 按已知索引读原始字节 | `slave.CoE.SDORead(index, sub)` | `slave.coe.sdo_read(index, sub)` |
| 按已知索引读成数值 | 自己 `BitConverter.ToUInt16(...)` | `slave.coe.sdo_read_value(index, sub, dtype='u16')` |
| 按已知索引写原始字节 | `slave.CoE.SDOWrite(index, sub, bytes)` | `slave.coe.sdo_write(index, sub, bytes)` |
| 按已知索引写数值 | 自己 `BitConverter.GetBytes(...)` | `slave.coe.sdo_write_value(index, sub, v, dtype='u16')` |
| 走对象字典条目读写 | `slave.CoE.ODList[i].OEList[s]`（`ObjectEntry`）的 `.Bytes` / `.TryGetBytes(...)` | `entry.bytes` / `entry.write_u16(v)` |

不用对象字典就能读写 = 用 `SDORead` / `SDOWrite`。要对象名字、要遍历、要批量 = 先加载对象字典。

### C#：条目路径的正确写法

```csharp
// OD 目录 → 对象 → 子条目。CoEInstance 没有索引器；ObjectDictionary 也没有索引器，只有 .OEList
var entry = slave.CoE.ODList[0x6040].OEList[0];

// 读 —— 要区分「失败」和「空字符串成功」必须用 TryGetBytes
if (entry.TryGetBytes(out byte[] data, out SDOError error))
    Console.WriteLine($"Controlword = 0x{BitConverter.ToUInt16(data, 0):X4}");
else
    Console.WriteLine($"读失败: {error}");

// 写 —— 唯一写路径
entry.Bytes = BitConverter.GetBytes((ushort)0x0006);
```

`.Bytes` 的 getter 把 **所有失败折叠成 `byte[0]`**，和「从站真的返回空字符串」不可区分。判成败只能靠 `TryGetBytes`。

### Python：条目路径的正确写法

```python
od = slave.coe.load_od_list()        # 失败返回 None，空表也算失败
if od is None or not od.loaded or len(od) == 0:
    raise SystemExit(f"对象字典加载失败: {slave.coe.last_sdo_error}")

entry = od[0x6040][0]                # 索引不存在抛 KeyError，先 in 一下更稳
entry.write_u16(0x0006)              # 类型化写，返回 bool
v = entry.read_u16()                 # 类型化读，失败返回 None
raw = entry.bytes                    # 原始字节，两次都失败返回 b''（不是 None）
entry.bytes = b'\x06\x00'            # 写；无权限或失败抛 CoE_AccessDeniedException
```

### Java / C++ / C / Rust

| 语言 | 读 | 写 |
|---|---|---|
| Java | `entry.getValue(Integer.class)` | `entry.setBytes(...)` |
| C++ | `coe.ReadEntryBytes(odIndex, subIndex)` | `coe.WriteEntryBytes(odIndex, subIndex, data)` |
| C | `ec_coe_sdo_read(master, slave, index, sub, CA, ...)` | `ec_coe_sdo_write(..., bytes, len)` |
| Rust | `entry.bytes(master, slave)` | `coe.sdo_write_ex(index, sub, ca, &data)` |

Java 的 `getValue(Class<T>)` 就是「`.Value` 只读」那条规则的原型：读方法是只读的，写走 `setBytes`。

## 字节宽度必须与对象一致

宽度不对，从站回 abort；有些库还会**悄悄补零**，让你拿到一个看起来正常的错值。

```csharp
// 错：GetBytes(8) 按 int 推断 = 4 字节，而 0x6060 只有 1 字节
slave.CoE.SDOWrite(0x6060, 0, BitConverter.GetBytes(8));

// 对：显式转型锁定宽度
slave.CoE.SDOWrite(0x6060, 0, BitConverter.GetBytes((byte)8));       // INTEGER8
slave.CoE.SDOWrite(0x6040, 0, BitConverter.GetBytes((ushort)0x000F)); // UNSIGNED16
slave.CoE.SDOWrite(0x607A, 0, BitConverter.GetBytes(100000));         // INTEGER32
```

```python
# 对：dtype 决定宽度
slave.coe.sdo_write_value(0x6060, 0, 8, dtype='i8')
slave.coe.sdo_write_value(0x6040, 0, 0x000F, dtype='u16')
slave.coe.sdo_write_value(0x607A, 0, 100000, dtype='i32')
```

`BitConverter.GetBytes` 没有 `sbyte` 重载，传 `(sbyte)` 会隐式转成 `short` 变 2 字节。模式值是正数用 `(byte)`；负值用 `unchecked((byte)(sbyte)v)` 或直接构造 `new byte[] { ... }`。

Python 的 `sdo_read_value` **在应答比 dtype 短时会在尾部补 `\x00` 再解析**，短了不报错。所以「读回来有值」不等于「宽度对上了」——宽了会被截断（`data[:expected]`），窄了会被补零，两种都静默。

## 失败即 abort，不要吞

### 拿 abort 码

```csharp
byte[] data = slave.CoE.SDORead(0x6041, 0, out SdoReadResult r);
if (data == null)
    Console.WriteLine($"SDO 读取失败 abort=0x{r.AbortCode:X8}, wkc={r.Wkc}, error={r.Error}");

bool ok = slave.CoE.SDOWrite(0x6040, 0, BitConverter.GetBytes((ushort)0x0006), out SdoWriteResult w);
if (!ok)
    Console.WriteLine($"SDO 写入失败 abort=0x{w.AbortCode:X8}, wkc={w.Wkc}");
```

```python
r = slave.coe.sdo_read(0x6041, 0, detail=True)     # -> SdoReadResult(ok, data, abort_code, wkc)
if not r.ok:
    print(f"SDO 失败 abort=0x{r.abort_code:08X}, wkc={r.wkc}")

w = slave.coe.sdo_write(0x6040, 0, b'\x06\x00', detail=True)
if not w.ok:
    print(f"写入失败 abort=0x{w.abort_code:08X}, wkc={w.wkc}")
```

- `abort_code == 0` = 设备没回中止码（成功或传输层失败）。
- 展示统一 `0x%08X` / `0x{code:X8}`，不要印十进制。
- `wkc <= 0` = 邮箱没回来，**不是**「对象不存在」。
- 想看原始码（不被枚举折叠）用 Python `slave.coe.last_sdo_abort_code`；`last_sdo_error` 是枚举视图，表外码会折成 `GENERAL_ERROR`。

### 常见 abort 及处置

| abort | 含义 | 怎么办 |
|---|---|---|
| `0x06010000` | 不支持的访问 | 查对象访问权限（只读/只写）与当前状态是否允许写 |
| `0x06020000` | 对象不存在 | 索引写错，或设备没实现；对照 OD / 手册 |
| `0x06070010` | 数据类型/长度不匹配 | 字节宽度或 dtype 用错，回去对表 |
| `0x06010002` | 写只读对象 | 换可写对象 |
| `0x06090011` | 子索引不存在 | 子索引号错 |
| `0x06090030` | 值超范围 | 查 min/max，先读回原值做比较 |
| `0x08000022` | 设备当前状态不允许 | 先切到允许该操作的状态（多数参数要 PreOp） |
| `0x05040000` | SDO 协议超时（WKC=0 / 邮箱没回） | **不是**对象不存在；查链路与从站状态后重试 |

超时和通用错误**不进** NotPresent 负缓存；只有确定性中止码才会被缓存并让后续同 `index:sub` 直接失败。换固件 / 热插拔之后要清缓存：C# `entry.ResetNotPresent()`、Python `slave.coe.reset_not_present_cache()`。

### 不能这样

```csharp
try { slave.CoE.SDOWrite(0x607A, 0, data); } catch { }   // 禁：吞掉失败
slave.CoE.SDOWrite(0x607A, 0, data);                     // 禁：不判返回值
```

```python
slave.coe.sdo_write_value(0x607A, 0, 100000, dtype='i32')  # 禁：不判返回值
```

## 对象字典从哪来

### 三条路

| 路 | 入口 | 说明 |
|---|---|---|
| ESI（优先） | 建主站时 `SetEsiFiles(path)` / `SetEsiFile(file)` | 本地 XML，0 邮箱流量；按厂商 ID + 产品代码自动匹配 |
| SDO Information（设备真值） | `LoadODListAsync(ct, preferEsi:false)` / `load_od_list(prefer_esi=False)` | 真发邮箱逐条读，慢但不会错 |
| 厂商手册 | 手册的对象表 | 只有少数几个参数时最省事，不用加载整表 |

### 各语言入口

```csharp
// C#：preferEsi 默认 false（公开 SDK 走真 SDO Information）
await slave.CoE.LoadODListAsync(ct, preferEsi: true);   // GUI / 离线优先走 ESI
bool loaded  = slave.CoE.IsOdListLoaded;
var  od      = slave.CoE.PeekOdList();                  // 窥探，不触发加载
slave.CoE.ClearOdCache();                               // 清目录 + 全部缓存
```

```python
# Python：prefer_esi 默认 True，失败返回 None（空表也算失败）
od = slave.coe.load_od_list()                    # 稳定入口，空表会自动重试一次
# od = slave.coe.load_od_list(prefer_esi=False)  # 强制真发 SDO Information
if od is None or not od.loaded or len(od) == 0:
    print(f"对象字典加载失败: {slave.coe.last_sdo_error}")
```

```rust
let cached = slave.coe.od_list();          // 只取缓存，未加载 = None，不发总线
let od     = slave.coe.load_od(true)?;     // 参数 = prefer_esi，加载并缓存
let ok     = slave.coe.load_od_list(true)?; // 只要“是否非空”，正在加载时返回 false
```

```c
od_list_t* od = od_load(master, slave, TRUE);   // TRUE = 连子条目一起读
od_object_t* obj = od_find(od, 0x6040);
od_free(od);                                     // 成对释放，别跨运行库 free
```

### ESI 从哪来

- 设备厂商官网（最新最准）、ETG 官网、设备随附资料。
- 放 `ESI` 目录里，启动扫描后按 VID + PID 自动匹配，不用逐个指定。
- **没有 ESI 也能跑**：主站从从站 EEPROM / SII 读默认配置。但默认 PDO 分配固定、不生成启动 SDO 参数、DC 模式不可选。伺服这类要初始化参数的设备，最好备好 ESI。

### 没有 ESI / 手册只有索引时

1. 先 `load_od_list` 把设备真实的索引表拉下来，确认对象存在、看名字、看子索引数和数据类型。
2. 索引、子索引、位宽、是否可写，以**手册**为准；OD 只告诉你设备声明了什么，不告诉你业务含义。
3. 手册和 OD 冲突时以设备实际返回为准，并把差异记下来。

### 几个坑

- `ODList[index]` 找不到**抛 `KeyNotFoundException`**，不是返回 null。
- OP / SafeOp 下只加载了对象列表、没加载子索引表时，`od[index][sub]` 抛 `OdSubindexMetadataNotLoadedException`。此时用 `GetEntryDescription(index, sub, out _)` 取单条目元数据，再直接 `SDOWrite`。
- Python 里 `od[0x6041]` 查不到会**按列表位置回退**（`0 <= key < len(od)`），小整数可能拿到第 N 个对象。按索引访问前先 `0x6041 in od`。
- 完整 OD 加载邮箱很密，**放 PreOp 做**，别在 OP 里刷。

## CiA 402 常用对象

标准值（IEC 61800-7-204 / CiA 402），**厂商可以有差异**，尤其 0x603F 错误码、0x6502 位掩码、厂商区 0x2000–0x5FFF。表里给的是最常见的口径。

| 索引 | 名称 | 类型 | 读写 | 怎么用 / 常见值 |
|---|---|---|---|---|
| `0x6040` | Controlword 控制字 | UNSIGNED16 | RW | 状态机命令。`0x06` Shutdown → `0x07` SwitchOn → `0x0F` EnableOperation；`0x00` DisableVoltage；`0x02` QuickStop；`0x86` FaultReset（bit7 上升沿，禁止只写 `0x80`）；`0x0100` Halt |
| `0x6041` | Statusword 状态字 | UNSIGNED16 | RO | 读状态**只认这个**，不认你写了什么。位含义见下节 |
| `0x6060` | Modes of operation 模式设置 | INTEGER8 | RW | `1` PP、`2` VL、`3` PV、`4` PT、`6` HM、`7` IP、`8` CSP、`9` CSV、`10` CST、`11` CSTCA |
| `0x6061` | Modes of operation display 模式显示 | INTEGER8 | RO | 驱动器**实际生效**的模式。设完 0x6060 读这个确认真的切过去了 |
| `0x607A` | Target position 目标位置 | INTEGER32 | RW | CSP / PP 的目标。单位是驱动器位置单位（由 0x6091 / 电子齿轮决定），不是毫米 |
| `0x6064` | Position actual value 实际位置 | INTEGER32 | RO | 跟随误差看它和 `0x607A` 的差；CSP 下位置偏移 `0x60B0` 叠加到目标位置，状态字 bit13 是跟随误差标志 |
| `0x606C` | Velocity actual value 实际速度 | INTEGER32 | RO | 单位随 0x6092 / 厂商口径 |
| `0x6077` | Torque actual value 实际转矩 | INTEGER16 | RO | **千分之额定转矩**（1000 = 100%）。不是安培，不是 N·m |
| `0x603F` | Error code 错误码 | UNSIGNED16 | RO | 按 CiA 301 错误码表解码。读失败返回 `0xFFFF` 哨兵，别当成真故障码 |
| `0x6502` | Supported drive modes 支持模式 | UNSIGNED32 | RO | 位掩码：bit0 PP、bit1 VL、bit2 PV、bit3 PT、bit5 HM、bit6 IP、bit7 CSP、bit8 CSV、bit9 CST、bit10 CSTCA |

常用配套对象（同属标准，按需用）：`0x605A` 快停选项、`0x6071` 目标转矩、`0x6072` 最大转矩、`0x6076` 额定转矩、`0x607C` 回零偏移、`0x607D` 软件限位、`0x6081/0x6083/0x6084` 轮廓速度/加速/减速、`0x6098` 回零方法、`0x6099` 回零速度、`0x60B0` 位置偏移、`0x60B1` 速度偏移、`0x60B2` 转矩偏移、`0x60FD` 数字输入、`0x60FE` 数字输出、`0x60E3` 支持的回零方法。

### 先确认支持，再切模式

```csharp
if (drv.IsModeSupported(ModeCiA402.CSP))     // 读 0x6502 位掩码
    drv.OperationMode = ModeCiA402.CSP;      // 写 0x6060
```

切完读 `0x6061` 确认。`0x6502` 读失败和不支持是两回事：读失败要先修通信，不要当成「只支持 PP」。

## 状态机怎么读

### 0x6041 位定义（标准值）

| 位 | 掩码 | 含义 |
|---|---|---|
| 0 | `0x0001` | Ready to switch on |
| 1 | `0x0002` | Switched on |
| 2 | `0x0004` | Operation enabled |
| 3 | `0x0008` | Fault |
| 4 | `0x0010` | Voltage enabled |
| 5 | `0x0020` | Quick stop |
| 6 | `0x0040` | Switch on disabled |
| 7 | `0x0080` | Warning |
| 9 | `0x0200` | Remote |
| 10 | `0x0400` | Target reached |
| 11 | `0x0800` | Internal limit active |
| 12 / 13 | `0x1000` / `0x2000` | 模式相关（CSP 下 bit13 = 跟随误差） |

### 到 OperationEnabled 的判据

```
运行四态：(statusword & 0x6F) == 0x27   // OperationEnabled
其余态：  (statusword & 0x4F)           // 还能区分 SwitchOnDisabled 等
故障：    (statusword & 0x4F) == 0x08   // 只看 bit3
```

- **不要**把 `0x4F` 的掩码结果去和 `0x27` 比 —— `0x4F` 把 bit5 掩掉了，而运行态的 `0x27` 里 bit5 = 1，这样比永远不相等。运行四态必须用 `0x6F`。
- 用 `0x6F` 只对运行四态成立；判非运行态时换回 `0x4F`（有些驱动器 SwitchOnDisabled 时 bit5 仍为 1）。
- C# 直接读 `drv.StateDrive`，它就是这个解析的封装。Python 用 `state_drive`（PDO 优先），`txpdo_data_invalid` 非零时回到 SDO 的 `state` 复核。

### 为什么不能只看 0x6040

1. 0x6040 是你**发出去的命令**，不是驱动器的状态。写了 `0x0F` 不等于已经到了 OperationEnabled。
2. 故障时不复位，写多少次 `0x0F` 都进不去。
3. 有些 SDK 的 `control_word` **读回来是按当前状态字算出的使能命令**，不是回读 0x6040 的真实内容；setter 还可能不检查写入结果。
4. 正确顺序：写命令 → 读 0x6041 → 解析状态 → 再决定下一步。使能请直接调 `Enable()`，它只在解析到 OperationEnabled 时返回 true。

## 参数固化 / 掉电保存

改完参数只写在 RAM 里，**断电就没了**。保存要用设备自己的保存对象。

| 索引 | 名称 | 说明 |
|---|---|---|
| `0x1010` | Store Parameters | 写它会把参数烧进 EEPROM / Flash |
| `0x1011` | Restore Default Parameters | 恢复出厂，**会覆盖你刚调好的参数** |

三条硬规则：

1. **不同厂商不一样，按手册。** 子索引数量（有的只有 `:1` save all，有的按参数组分）、写入值的格式（CiA 301 常见是 32 位 “save” 签名，也有厂商直接收 `1` —— 本仓未验证过任何一家）、是否支持、保存耗时（几十 ms 到几秒），全都因厂商而异。手册没写就不要写。
2. **别在周期里做。** 保存要写 Flash，慢且伤寿命。只在调试完成、参数确认后做一次。
3. **保存后断电重启验证。** 读回参数确认落盘，不要用「写成功」当「已保存」。

**不要拿 0x1010 / 0x1011 做读写测试。** 它们有动作语义（写 EEPROM），测试用无副作用的参数（例如同值写 `0x1017` 心跳时间、`0x10F1:02` 同步错误计数上限）。

## PDO 映射：0x1600 / 0x1A00

| 索引范围 | 内容 |
|---|---|
| `0x1600`–`0x17FF` | RxPDO Mapping（主站 → 从站） |
| `0x1A00`–`0x1BFF` | TxPDO Mapping（从站 → 主站） |
| `0x1C12` | RxPDO Assign（SM2，指到哪个 0x16xx） |
| `0x1C13` | TxPDO Assign（SM3，指到哪个 0x1Axx） |

### 顺序不能乱

改映射**必须在 PreOp**。SafeOp / OP 下写 `0x1C12` / `0x1C13` 会被从站拒绝。

```
1. SetState(PreOp)
2. 0x1C12:00 = 0                  // 先解除 SM2 分配
3. 0x1600:00 = 0                  // 清空映射条目数
4. 0x1600:01..n = 映射值           // 逐条写
5. 0x1600:00 = n                  // 写回条目数
6. 0x1C12:01 = 0x1600；0x1C12:00 = 1
7. SetState(SafeOp) → SetState(OP)
```

- 只改 RxPDO 就**不要顺手清 `0x1C13`** —— 清了不写回，从站就没有输入过程数据了。
- 改 TxPDO 同理：`0x1C13:00 = 0` → `0x1A00:00 = 0` → 写条目 → `0x1A00:00 = n` → `0x1C13:01 = 0x1A00` → `0x1C13:00 = 1`。
- 映射值的格式是 `index << 16 | subindex << 8 | bitLength`。`0x60400010` = `0x6040:00`，16 bit。宽度对不上会 abort（常见 `0x06040042` 超 PDO 长度、`0x06040041` 不可映射）。
- 映射条目顺序必须和主站侧结构体字段顺序一致，否则读出来是错位的字节。
- 要整包读写用 Complete Access（`completeAccess: true`），但 `subindex` 只能是 0 或 1；整包读回后按子索引切分用 `ParseCompleteAccessData`。

```csharp
coe.SDOWrite(0x1600, 0, new byte[] { 0 });                        // 清空
coe.SDOWrite(0x1600, 1, BitConverter.GetBytes(0x60400010u));      // 0x6040:00, 16 bit
coe.SDOWrite(0x1600, 0, new byte[] { 1 });                        // 条目数 = 1
coe.SDOWrite(0x1C12, 1, BitConverter.GetBytes((ushort)0x1600));
coe.SDOWrite(0x1C12, 0, new byte[] { 1 });
```

### 读当前分配

`slave.coe.enumerate_default_pdo(0)` 读 `0x1C12`，`enumerate_default_pdo(1)` 读 `0x1C13`。返回三态：`List` = 读到了、`[]` = 确认没分配、`None` = **读失败**（不要当成空表继续配 PDO）。

## 常见坑

1. **在 OP 里改映射** → 从站直接 abort。改映射先去 PreOp。
2. **把 `SDO_PROTOCOL_TIMEOUT` 当成「对象不存在」** → 它是邮箱没回来，重试或查链路，不是索引写错。
3. **用 `BitConverter.GetBytes(int)` 写 1 字节对象** → 4 字节，abort 或写坏相邻参数。
4. **`.Bytes` 读失败拿到 `byte[0]` 还当成功** → 用 `TryGetBytes` 判。
5. **Python `sdo_read_value` 宽度写大** → 尾部补零，返回一个假的正常值。
6. **不判 `SDOWrite` 的 bool** → 失败被静默吞掉，后面全在错参数上跑。
7. **OP 下靠 `ODList[i][s]` 取条目** → 子索引表可能没加载，抛 `OdSubindexMetadataNotLoadedException`。用 `GetEntryDescription` + `SDOWrite`。
8. **热插拔后还读旧缓存** → NotPresent 负缓存还在，会一直返回不存在。清缓存再试。
9. **在 `ProcessDataCyclicSync` 里做 SDO** → 阻塞邮箱，周期被打断。
10. **用 `0x1010` 当测试对象** → 写 EEPROM，伤寿命且改设备行为。
11. **`0x6077` 当安培读** → 它是千分之额定转矩，`0x6077 / 1000 × 0x6076`（额定转矩）才是实际转矩。
12. **`0x6502` 读失败当成「只支持 PP」** → 先修通信，再判断支持能力。

## 已知不一致（按当前 SDK 二进制核对）

`ai-prompts.txt` 和部分页面里的 `slave.CoE[idx][sub].Value` 写法，在**当前发布的 C# SDK 上编译不过**：`CoEInstance` 没有索引器，`ObjectEntry` 也没有 `Value` 属性（只有 `Bytes` / `TryGetBytes`）。已对着 `本地NuGet源/Darra.EtherCAT.Master.2.13.16.nupkg` 里的 `DarraEtherCAT.dll` 反射核对过。

C# 请用：

```csharp
var entry = slave.CoE.ODList[0x6041].OEList[0];   // ObjectDictionary 没有索引器，必须再走 .OEList
if (entry.TryGetBytes(out byte[] data, out SDOError error))
    Console.WriteLine($"Statusword = 0x{BitConverter.ToUInt16(data, 0):X4}");
else
    Console.WriteLine($"读失败: {error}");
```

`.Value` 只读这条规则本身没错（Java 就是 `getValue(Class<T>)`），只是 C# 当前没有这个名字。

## 不要生成的写法

- `slave.CoE[0x6041][0].Value` / `slave.CoE[0x6041][0].GetValue<ushort>()` —— 当前 C# SDK 不存在，编译不过
- `entry.Value` / `entry.Value = ...` —— `ObjectEntry` 根本没有 `Value` 属性（不是「只读」，是编译不过），写用 `entry.Bytes = ...` / `SDOWrite`
- `slave.CoE.ODList[i][s]` —— `ObjectDictionary` 没有索引器，必须 `ODList[i].OEList[s]`
- 不判 `SDORead` 是否为 `null` 就 `BitConverter`
- 不判 `SDOWrite` 的返回值
- `catch { }` 吞掉 SDO 异常
- `BitConverter.GetBytes(8)` 写 1 字节对象
- 不查手册直接编对象索引
- 把 `0x06020000` / `0x05040000` / `0x08000000` 混为一谈
- OP 里改 PDO 映射
- 在周期回调里读参数
- 拿 `0x1010` / `0x1011` 做测试
- 只看 `0x6040` 不读 `0x6041` 就断言已使能

## 出处

对象索引与 API 的仓内出处（`a:\c\Darra\Darra_EtherCAT_Master\` 下）：

**API 签名**
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:2320` — `SDORead(ushort, byte, bool)`
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:7230` — `SDOWrite(ushort, byte, byte[], bool)`
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:5986` — `ObjectEntry.Bytes`（读失败折叠 `byte[0]`）
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:6075` — `TryGetBytes(out byte[], out SDOError)`
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:1921` — `LoadODListAsync(ct, preferEsi = false)`
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:3266` — `EcODList.this[ushort]`（找不到抛 `KeyNotFoundException`）
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CoE.cs:7041` — `ObjectDictionary.this[byte]`（元数据未加载抛 `OdSubindexMetadataNotLoadedException`）
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Initialise.cs:162` — `SetEsiFiles(string path)`
- `Darra_EtherCAT_ClassLibrary/Python/darra_ethercat/slave/core.py:559` — `sdo_read`
- `Darra_EtherCAT_ClassLibrary/Python/darra_ethercat/slave/core.py:778` — `sdo_read_value`（短应答补零）
- `Darra_EtherCAT_ClassLibrary/Python/darra_ethercat/slave/core.py:802` — `sdo_write`
- `Darra_EtherCAT_ClassLibrary/Python/darra_ethercat/slave/core.py:925` — `sdo_write_value`
- `Darra_EtherCAT_ClassLibrary/Python/darra_ethercat/slave/coe.py:2291` — `_coe_load_od_list(prefer_esi=True)`
- `Darra_EtherCAT_ClassLibrary/Rust/src/slave/coe.rs:2256` — `od_list()`
- `Darra_EtherCAT_ClassLibrary/Rust/src/slave/coe.rs:2272` — `load_od(prefer_esi)`
- `Darra_EtherCAT_ClassLibrary/Java/src/com/darra/ethercat/slave/CoE.java:1268` — `getValue(Class<T>)`
- `Darra_EtherCAT_ClassLibrary/Java/src/com/darra/ethercat/slave/CoE.java:1246` — `setBytes(byte[])`
- `Darra_EtherCAT_ClassLibrary/CPP/include/slave/coe.hpp:1767` — `ReadEntryBytes`
- `Darra_EtherCAT_ClassLibrary/C/include/slave/coe.h:344` — `ec_coe_sdo_write`

**CiA 402 对象常量**
- `Darra_EtherCAT_ClassLibrary/CSharp/Master/Slave/CiA402.cs:168` — `OD_CONTROLWORD = 0x6040`
- 同文件 `:170` `0x6041`、`:172` `0x6060`、`:174` `0x6061`、`:176` `0x607A`、`:178` `0x6064`、`:182` `0x606C`、`:186` `0x6077`、`:208` `0x6502`、`:252` `0x603F`

**文档**
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:17` — `(statusWord & 0x6F) == 0x27` 判 OperationEnabled、`(statusWord & 0x4F) == 0x08` 判故障
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:55` — `StateCiA402` 枚举
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:112` — 控制字命令常量（`0x00/0x02/0x06/0x07/0x0F/0x86/0x0100`）
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:137` — `Enable()` 只在 OperationEnabled 返回 true
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:246` — `ModeCiA402` 枚举（PP=1 … CSTCA=11）
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:500` — 状态字位掩码常量
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:524` — `0x6502` 位含义
- `云端/ethercat-doc/docs/sdk/csharp/cia402.md:454` — 标准对象索引常量表
- `云端/ethercat-doc/docs/sdk/csharp/coe.md:188` — 空字符串成功只对 `0x1008/0x1009/0x100A` 成立
- `云端/ethercat-doc/docs/sdk/csharp/coe.md:224` — Complete Access `subindex` 只能是 0/1
- `云端/ethercat-doc/docs/sdk/csharp/coe.md:252` — NotPresent 只缓存确定性中止码
- `云端/ethercat-doc/docs/sdk/python/coe.md:889` — `SDOError` 全套 abort 码
- `云端/ethercat-doc/docs/sdk/python/coe.md:637` — `ODList` 默认 `prefer_esi=True`，OP/SafeOp 下加载会挤占周期邮箱
- `云端/ethercat-doc/docs/sdk/python/coe.md:544` — `enumerate_default_pdo` 三态
- `云端/ethercat-doc/docs/ethercat/device-profiles/coe.md:109` — `0x1600–0x17FF` / `0x1A00–0x1BFF` 范围
- `云端/ethercat-doc/docs/ethercat/device-profiles/coe.md:288` — 改 PDO 映射必须在 PreOp 及完整顺序
- `云端/ethercat-doc/docs/quick-start/preparation.md:90` — ESI 从哪里获取（`@:92` 厂商官网 / ETG / 随附资料）
- `云端/ethercat-doc/docs/quick-start/preparation.md:96` — 无 ESI 自动配置与有/无 ESI 的能力差异

**保存参数**
- `测试项目/TEST_SDK_CSharp/MbxSoakTest.cs:175` — `0x1010` / `0x1011` 保存/恢复参数会写 EEPROM，禁止用于测试

## 需要查厂商手册才能定的项

以下内容**标准里没有统一答案**，本仓也没有验证过，写代码前必须查手册：

1. `0x1010` Store Parameters 的**子索引布局**和**写入值格式**（是否要 32 位签名、是否按参数组分）。
2. `0x1011` Restore Default 的允许值和恢复范围。
3. `0x6077` 实际转矩的单位换算基准（千分之额定 vs 千分之最大）。
4. `0x6064` / `0x606C` 的位置/速度单位（电子齿轮比、0x6091、0x6092 的厂商口径）。
5. `0x603F` 错误码的完整码表（CiA 301 只定义大类，细码各家不同）。
6. `0x6502` 是否完整实现、`0x60E3` 回零方法列表。
7. 厂商私有对象区 `0x2000–0x5FFF` 的全部索引。
8. 参数写入后是否需要额外的「生效」动作（有些厂商要单独写一条 apply / 或者必须回 PreOp 才生效）。
9. 保存参数需要多长时间、期间是否中断 PDO。
