class_name SteamService
extends Node
## steam_service.gd — Steam 平台抽象层 【分包：包 E·存档与平台组】
##
## ── 接入结论（架构 §6.1，不要改）──
##   ✅ SDK 初始化：GodotSteam GDExtension，版本与 Godot 强绑定锁死
##   ✅ 成就：本地先写 profile.achievements_synced 再推，离线补推
##   ✅ Rich Presence：只推一个字段（成本<2h，商店页好友曝光）
##   ❌ Steam Input API（Godot InputMap + 手柄映射 + Steam 后台配置器替代）
##   ❌ Steam Cloud（与"无云存档"硬约束冲突）
##   ❌ Leaderboards / Stats / Workshop / Steam Deck 认证（首发）
##
## ── 架构纪律 ──  所有调用走本抽象层；无 Steam 环境（直接双击 exe 开发调试）
## 自动降级 SteamNull。src 其它地方禁止 import GodotSteam。

static func create() -> SteamService:
	var svc := SteamService.new()
	svc.name = "SteamService"
	return svc

var _backend: Object = null   # GodotSteam binding 或 SteamNull

func _ready() -> void:
	if _try_init_godotsteam():
		_backend = load("res://src/platform/steam_binding.gd").new()
	else:
		_backend = load("res://src/platform/steam_null.gd").new()
		Logger.log("steam", "null_backend", "", null, "no steam env, NullSteam")

func _try_init_godotsteam() -> bool:
	# TODO 包 E：Steam.steamInitEx() 判定；注意验证"verify valve reconnect after init failure"
	# （架构侧唯一待验证项——QA S9 出站 0 判据的唯一不确定处，Process Monitor 验证）
	return false

func set_achievement(id: StringName) -> void:
	_backend.call("set_achievement", id)

func set_rich_presence(status: String) -> void:
	_backend.call("set_rich_presence", status)
