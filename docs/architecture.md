# 架构纪律摘要（分包团队必读）

完整决策链见 `../末日安全屋_项目架构方案_v1.md`（1400+ 行，含全部否决案与事故记录）。
本文件只列**日常开发会碰到**的硬约束。

## 引擎与渲染
- Godot 4.3 + GDScript；内部分辨率 640×360 整数缩放（门禁项，改动需架构审批）
- 所有时序常量以**帧**为单位；秒值由脚本生成（`gen_baseline.py`），文档手写秒值 = CI 拒绝
- 取整方向：帮玩家的向上、罚玩家的向下、中性结构时长必须精确整除

## 数据与代码
- `data/` 纯 JSON（键名 `<域>_<量>_<单位>` 三段式）；`src/` 纯 .gd；代码零魔法数
- 产线/库存/RNG 派生一律**整数定点**（milli / ticks）；float 仅剩 HP/体力/饥饿/渴四个连续量
- 同一事实只允许一处定义（M28 扫描：同名单位 key 出现两文件 → exit 1）

## 状态与时间
- 状态写入只有一条路：`StateStore.apply(ChangeSet)`，writers 白名单鉴权，越权 debug 崩溃
- 时间唯一真相：`GameLoop.elapsed_ticks`（整数帧）；`gh()` 是纯派生，不存储
- 同帧多源结算必须走 `ResolveOrder` 常量表，禁字典遍历
- **两层边界（D-009 裁决，勿混）**：
  ① 运行期数值路径 → `state_contract.json` 鉴权（hp/milli/计数走 apply）
  ② 容器型状态（背包列表/搜刮标记/事件日志）→ 系统内部持有，`register_persistence()` 挂接，
     结构由 `save.schema.json` 定义——容器不进 contract、不走 apply（ChangeSet 是数值 Op 流）

## 事件
- 只允许 4 类能力：`num / flag / time / spawn`（effect.schema.json additionalProperties:false）
- condition 用结构化谓词，一个 `!` 都不许出现在字符串里
- 事件 id 不编码会变的数据（日期/序号/数量）；幂等键 `{event_id}:{day}:{slot_index}`

## 随机
- 全项目只有 `RngService` 能产生随机；7 条子流全部纯 hash、零顺序消费
- `randi()/randf()/randomize()` 出现在 src/ 其它任何地方 → CI exit 1
- 允许的横向依赖白名单新增：**CombatSystem → LoopSystem 只读 `pick_breach_target()`**（破防目标选取，任务书授权；未接入时必须本地确定性降级 + 告警，禁 randi 兜底）

## 存档
- 单档 `user://save.sav`；原子写（tmp→自校验→bak→rename）；读档零写入
- 夜战进行中退出不写档（与崩溃同路径，防"退出比死亡划算"）

## Steam 平台
- **GodotSteam 版本锁定：4.15-gde（对应 Godot 4.1–4.3）**，随附 `addons/godotsteam/`（仅 win64，首发平台）
  - 完整决策链见架构方案 §6.1 第 529 行「SDK 初始化 ✅ 必须」——版本与 Godot 强绑定，**升 Godot 必须同步升 GodotSteam**
  - 许可：MIT（`addons/godotsteam/license.txt`）；其余平台从 Codeberg 官方包取回
  - **探测 SDK 不得发网络请求**：`_try_init_godotsteam()` 只查 `ClassDB.class_exists("Steam")`（S9 零出站硬约束）
  - 初始化失败（无 appID / 未登录）**必须**走 NullSteam 降级并记日志（架构 1012 条，已由 `scenes/debug/steam_probe.tscn` 的 1012(1)–(4) 守护）
  - 实测（2026-10-21）：GodotSteam 初始化**失败时不回连 Valve**（对外连接 0 / DNS 0），架构 1075 条已验证通过

## 验收
- `tools/test.ps1` 单入口四 stage；空跑判负；报告两段（gate/review）+ coverage_statement
- 判据落笔四问：适用域？随第二变量分裂？余量/误差>3？失败可归因？
