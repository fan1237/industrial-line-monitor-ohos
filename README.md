# 工业产线智能监控 APP

基于 **ArkTS** 开发的工业 miniAPP，运行于 OpenHarmony / HarmonyOS 6.0（API 20）的 PDA 与移动端设备，面向"工业智能体"三大场景单元，实现产线**状态监控、远程控制、数据采集可视化、报警管理、订单扫码交互**，并按要求集成**国密 SM2 / SM3 / SM4** 加密能力。

---

## 一、功能一览

### 必做模块（模块一 ~ 模块五）

| 模块 | 功能 | 状态 | 说明 |
| --- | --- | --- | --- |
| 一 | 产线运行状态监控 | 部分完成 | 已实现产线状态、温湿度传感器、光电传感器实时显示，刷新周期 1 秒；**工序进度与物理指示灯同步待补** |
| 二 | 远程产线控制 | 完成 | 启动 / 停止 / 复位，均带二次确认；指令经 `IDataService` 下发（真实环境由智能计算场景单元校验后转 PLC），操作日志完整记录操作人与结果 |
| 三 | 数据采集与可视化 | 完成 | 温湿度曲线 + 温度仪表盘；历史数据落 RelationalStore，支持最近 10 / 30 / **60 分钟**回看与统计，支持 CSV 导出 |
| 四 | 报警管理与异常处理 | 完成 | 温湿度超限 / 过低自动报警，含类型、时间、位置、等级；支持报警确认（记录确认时间）与按等级筛选，阈值可自定义配置 |
| 五 | 订单管理与扫码交互 | 完成 | 扫码下单 / 手动录入（产品、数量、优先级），订单进度随产线推进，支持开始生产、确认完成、删除 |

### 创新功能（加分项）

| 模块 | 功能 | 状态 |
| --- | --- | --- |
| 六 | AI 视觉检测联动 | 待定（依赖组委会相机接口） |
| 七 | 数字孪生 3D 交互 | 待定（依赖孪生场景接口） |
| 八 | 智能分析与报表 | 已完成统计基础（极值 / 均值），报表导出待扩展 |
| 九 | 多设备协同与权限管理 | 待扩展（RBAC 三种角色） |
| 十 | 自定义扩展 | 已实现「国密算法自检」面板，可现场演示加解密与验签 |

---

## 二、技术栈

| 层 | 技术 |
| --- | --- |
| 开发语言 | ArkTS |
| 开发工具 | DevEco Studio（最新稳定版） |
| 目标平台 | OpenHarmony 6.0+ / HarmonyOS（compatibleSdk 26） |
| UI 框架 | ArkUI（声明式）+ Canvas 2D 自绘图表 |
| 本地存储 | `@kit.ArkData` → RelationalStore（关系型数据库） |
| 安全加密 | `@kit.CryptoArchitectureKit` → SM2 / SM3 / SM4 |
| 通信规划 | MQTT over TLS 1.3 / WebSocket，JSON 报文 |

---

## 三、快速开始

### 环境要求

- DevEco Studio 最新稳定版，已安装 HarmonyOS SDK（API 20 / 6.0）
- OpenHarmony 6.0 PDA，或鸿蒙手机 / 平板（开启开发者模式与 USB 调试）

### 运行步骤

1. 用 DevEco Studio 打开本仓库根目录（选择 `HarmonyStudingFinal` 文件夹，不要只开 `entry`）。
2. 等待 `oh-package.json5` 依赖自动同步完成（若提示 `ohpm install`，执行即可）。
3. 连接真机或启动本地模拟器，右上角选择目标设备。
4. 点击 **Run ▶** 直接运行；或 **Build → Build Hap(s)/APP(s)** 生成安装包。
5. HAP 产物路径：`entry/build/default/outputs/default/`。

> 首次在新机器打开时，DevEco 会重新生成 `local.properties`（已加入 `.gitignore`，不会被提交）。

---

## 四、目录结构

```
HarmonyStudingFinal/
├── AppScope/                      # 应用级配置（包名、图标、应用名）
├── entry/                         # 主模块
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/      # UIAbility 生命周期入口
│       │   ├── entrybackupability/# 备份恢复能力
│       │   ├── model/             # 数据模型
│       │   │   ├── SensorData.ets     # 实时传感器数据
│       │   │   └── HistoryPoint.ets   # 历史数据点（含时间戳）
│       │   ├── service/           # 数据服务层
│       │   │   ├── IDataService.ets   # 数据源接口（抽象）
│       │   │   ├── MockDataService.ets# 模拟实现（当前启用）
│       │   │   ├── HistoryStore.ets   # 历史数据仓储（RelationalStore）
│       │   │   └── CryptoService.ets  # 国密 SM2 / SM3 / SM4
│       │   └── pages/
│       │       └── Index.ets      # 主页面（全部功能模块）
│       ├── resources/             # 资源文件（多语言、主题、rawfile）
│       └── module.json5           # 模块配置（权限、设备类型、路由）
├── docs/
│   ├── 技术文档.md                # 设计说明书（架构 / 协议 / 国密方案）
│   └── 答辩大纲.md                # PPT 结构 + 演示脚本 + 常见问题
├── build-profile.json5            # 工程级构建配置（SDK 版本）
└── oh-package.json5               # 依赖声明
```

---

## 五、数据层设计（一句话）

> **UI 只认接口，不认数据来源。**

```
Index.ets (UI)
   ↓ 依赖
IDataService (接口)
   ↓ 实现
MockDataService   ← 现在用（本地模拟）
MqttDataService   ← 拿到协议后新增，改一行 new 即可切换
```

拿到组委会「工业智能体接口协议」后，只需新增一个 `MqttDataService implements IDataService`，把 `Index.ets` 里 `new MockDataService()` 换成 `new MqttDataService()`，UI 代码零改动。

历史数据同理：当前 `HistoryStore` 是本地兜底实现，接口打通后可改为「远端 TDengine 优先查询、本地缓存降级」的双实现策略。

---

## 六、国密合规说明

赛项要求数据传输链路强制使用国密算法加密，明文传输视为严重违规。本项目的实现分工：

| 算法 | 角色 | 用途 |
| --- | --- | --- |
| SM2（非对称） | 密钥协商 / 签名 | 协商 SM4 会话密钥、身份认证与防篡改验签 |
| SM3（摘要） | 完整性 | 报文摘要，接收端比对防篡改 |
| SM4（对称） | 数据加密 | 加密业务 JSON 报文（128 位密钥，CBC + PKCS7） |

代码位置：`entry/src/main/ets/service/CryptoService.ets`，APP 内「国密算法自检」区块可现场一键验证三种算法可用。

---

## 七、已知限制与待办

- [ ] 模块一缺**工序进度（上料/装配/检测/打包/入库）**展示
- [ ] 模块一缺**物理产线指示灯状态同步**显示
- [ ] 通信层尚未接入（等待组委会接口协议与国密 SDK）
- [ ] 真实设备扫码能力待在 PDA 硬件上验证
- [ ] 创新模块六 / 七 依赖相机与孪生场景接口，暂未接入

---

## 八、提交材料清单（赛前 1 小时交组委会）

总文件夹命名格式：`参赛编号-团队名-作品名`

- [x] **源代码** — 本仓库，含注释与 README
- [x] **技术文档 / 设计说明书** — `docs/技术文档.md`
- [ ] **演示视频** — 时长 ≤ 5 分钟
- [ ] **APP 安装包** — `.hap` 格式（DevEco 构建产物）
- [ ] **答辩 PPT** — 参考 `docs/答辩大纲.md`

---

## 九、开发记录

| 日期 | 进展 |
| --- | --- |
| 2026-10-19 | 完成模块一 ~ 模块五基础功能；抽出 `IDataService` 数据层接口 |
| 2026-10-20 | 历史数据落库（RelationalStore + 时间索引）、最近 1 小时回看与 CSV 导出；国密 SM2/SM3/SM4 服务与自检面板 |
