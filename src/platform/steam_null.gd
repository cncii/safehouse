class_name SteamNull
extends RefCounted
## steam_null.gd — 无 Steam 环境的空实现（QA S 构建产物要求：脱离 Steam 可运行）
## 仅成就不可用；Rich Presence 静默丢弃。

func set_achievement(_id: StringName) -> void:
	pass

func set_rich_presence(_status: String) -> void:
	pass
