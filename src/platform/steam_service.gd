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

## GodotSteam GDExtension 的脚本绑定文件。不存在时必须**安全降级**而不是崩——
## 架构 1012/1075 条：初始化失败必须走 NullSteam 降级并记日志。
## S 构建（无 Steam 环境）下本文件根本不存在，属正常路径。
const BINDING_PATH := "res://src/platform/steam_binding.gd"
const NULL_PATH := "res://src/platform/steam_null.gd"

func _ready() -> void:
	if _try_init_godotsteam():
		var b := load(BINDING_PATH)
		if b != null:
			_backend = b.new()
			Logger.log("steam", "godotsteam_backend", BINDING_PATH)
		else:
			_degrade("binding_script_missing")
	if _backend == null:
		_degrade("init_failed")

## 降级到 NullSteam：S 构建硬要求「脱离 Steam 可运行」（QA S 判据）
func _degrade(reason: String) -> void:
	_backend = load(NULL_PATH).new()
	Logger.log("steam", "null_backend", reason, null, "no steam env / init failed, NullSteam fallback")

## GodotSteam 是否可用。
##
## 判定方式：**只查 ClassDB 里有没有 `Steam` 这个已注册类**，不发起任何网络调用——
## S9 硬约束「零网络出站」要求连"探测 SDK"都不能连网。
## 注意：即使 GodotSteam 存在，steamInitEx() 也可能失败（无 Steam 客户端 / 凭据过期）；
## 那种情况的"失败回连 Valve"行为**不在本函数判定范围**，需按架构 1075 条
## 在带 SDK 的真实构建上用 Process Monitor 验证（本机无 SDK，无法在此断言）。
func _try_init_godotsteam() -> bool:
	if not ClassDB.class_exists("Steam"):
		return false
	# 类存在才继续：此处仍不发网络请求，只问引擎"这个单例在不在"
	return Engine.has_singleton("Steam") or ClassDB.instantiate("Steam") != null

func set_achievement(id: StringName) -> void:
	if _backend == null:
		return
	_backend.call("set_achievement", id)

func set_rich_presence(status: String) -> void:
	if _backend == null:
		return
	_backend.call("set_rich_presence", status)

## 后端类型（供 UI/诊断显示当前跑在 Steam 还是 NullSteam）
func backend_kind() -> StringName:
	if _backend == null:
		return &"none"
	if _backend.has_method("backend_id"):
		return StringName(_backend.call("backend_id"))
	return &"unknown"

## 后端是否就绪（只读；不给外部可写引用——防绕过抽象层直接调后端）
func backend_ready() -> bool:
	return _backend != null
