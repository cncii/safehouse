class_name EffectSink
extends Node
## effect_sink.gd — 事件/科技 4 类能力的唯一落地适配器（架构 §3.7+§4.5）
##
## ── 为什么存在 ──
## 事件系统自己没有写权限（EventSystem 只产出 Effect，落地全走这里）；
## 科技节点效果也走这里。全项目"改世界"只有这一个入口 → 只有一个调试点。
##
## ── 4 类能力 = 封闭集，没有第 5 类 ──
##   kind="num"   改契约内数值路径（±/set/clamp）——不能新增未注册路径
##   kind="flag"  开关（地点解锁/设施运行/结局标记）——不能开设计期不存在的开关
##   kind="time"  压缩时段/强制睡 → 只能调 TimeSystem，不能改天数
##   kind="spawn" 只能引用 spawn_tables.json 的 id——不能内联敌人参数
## data/schema/effect.schema.json 用 additionalProperties:false 硬校验；
## 出现 script/expr/call/on_fire 字段 → 启动即失败（不做通用脚本引擎的机械保障）。
## 注意：condition 用结构化谓词 {all/any/not + eq/ne/lt/lte/gt/gte}，
## 一个 "!" 字符串都不许出现（架构 v1.4 否决案）。

## state_store.gd 没有 class_name（autoload 名是 State），所以**不能**写
## `StateStore.ChangeSet`——那样编译期就报 "Identifier not declared"。
## 正解：preload 脚本取内嵌 ChangeSet（与 vitals_system.gd / combat_system.gd 同款）。
const _Store = preload("res://src/core/state_store.gd")

func resolve(effects: Array, source: StringName) -> void:
	for e_variant: Variant in effects:
		var e: Dictionary = e_variant
		match String(e.get("kind", "")):
			"num":
				var cs := _Store.ChangeSet.new(source, "effect_sink:num")
				match String(e.get("verb", "add")):
					"set":   cs.setv(String(e["path"]), e["value"])
					"clamp": cs.clampv(String(e["path"]), float(e["value"]))
					_:       cs.add(String(e["path"]), float(e["value"]))
				State.apply(cs)
			"flag":
				pass  # TODO 包 C：scope(location/facility/ui_hints) + field + value
			"time":
				pass  # TODO 包 C：SHIFT_END / ADD_GH / FORCE_SLEEP → TimeSystem
			"spawn":
				pass  # TODO 包 C：SpawnService.spawn(table_id, count, anchor)
			var unknown:
				push_error("unknown effect kind='%s' - schema validation gap" % unknown)
