class_name MetaSystem
extends Node
## meta_system.gd — 多周目跨局数据 【分包：包 E·存档与平台组】
##
## ── 职责 ──   profile.sav 的读写：周目数/难度/多周目解锁表/统计/成就推送状态
## ── 边界 ──   跨局只继承知识、配方和选项，绝不继承强力道具或资源
##              （第二周目开头无难度 = 无难度空转）
##
## ── 定稿规则（2.8 多周目持久化边界）──
##   跨局保留：科技知识(二周目成本-50%，L1 直接全开)/解锁表/统计/立绘
##   每局重置：四条状态/背包/设施/地图搜刮/事件进度/循环库存
##
## ── 判据 ──  S13(归档证据物) 成就推送幂等(achievements_synced 防重复推)

var profile: Dictionary = {}

func load_or_init() -> void:
	profile = Save.load_profile().get("profile", {})

## 多周目解锁查询（TechTreeSystem.cost_multiplier 的数据来源）
func tech_cost_multiplier() -> float:
	return float(profile.get("unlocked", {}).get("tech_cost_multiplier", 1.0))

func record_achievement(ach_id: StringName) -> void:
	var synced: Array = profile.get("achievements_synced", [])
	if ach_id in synced:
		return  # 幂等：本地先记账再推 Steam，防重复推送
	synced.append(String(ach_id))
	profile["achievements_synced"] = synced
	# TODO 包 E：Steam.setAchievement + storeStats（离线只记本地，下次启动补推）
