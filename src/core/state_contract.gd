class_name StateContract
extends Node
## 状态路径注册表（运行期由 StateStore 加载 data/schema/state_contract.json）
## 分包团队新增状态路径时改 JSON，不改代码。此 autoload 仅提供路径常量，防拼写漂移。

# ── 玩家状态（QA 判据 M2/M3/M2b/M3b 的被测路径）──
const P_HP := "player.hp"
const P_STAMINA := "player.stamina"
const P_HUNGER := "player.hunger"
const P_THIRST := "player.thirst"
const P_FORCED_SLEEP := "player.forced_sleep_pending"

# ── 时间 ──
const T_DAY := "time.day"
const T_GH_TODAY := "time.gh_elapsed_today"

# ── 战斗 ──
const C_WAVE_ACTIVE := "combat.wave_active"

# ── UI 提示（第 10 类持久化——必须入档，否则读档后提示重弹或漏弹）──
const H_TRAP_HINT := "ui.hints.trap_telegraph"
const H_TECH_L2 := "ui.hints.tech_L2_1_trap"
