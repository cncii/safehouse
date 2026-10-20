extends Node
## localization.gd — 文本唯一来源封装（架构 §2.1 data/locale + R9 风险防线）
##
## · 唯一文本来源：data/locale/strings.csv（KEY,zh_CN,zh_TW,en）。
## · src/**/*.gd 出现中文字面量 → tools/check_i18n.py exit 1（第一天就开）。
## · 缺失键兜底：debug 打印 KEY 本身，release 显示键名（不显示空）。

const FALLBACK_LANG := "zh_CN"

var _table: Dictionary = {}     # key -> {lang: text}
var _lang := FALLBACK_LANG

func _ready() -> void:
	_load()

func _load() -> void:
	var f := FileAccess.open("res://data/locale/strings.csv", FileAccess.READ)
	if f == null:
		push_warning("strings.csv missing - raw KEY fallback")
		return
	var header: PackedStringArray = []
	var first := true
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() == "":
			continue
		var cols := line.split(",")
		if first:
			header = cols
			first = false
			continue
		if cols.size() < 2:
			continue
		var dict := {}
		for i in range(1, header.size()):
			if i < cols.size():
				dict[header[i]] = cols[i]
		_table[cols[0]] = dict

func set_lang(lang: String) -> void:
	_lang = lang

func get_lang() -> String:
	return _lang

## 用法：Localize.text("UI_HUD_HUNGER")
##
## ⚠ 为什么不能叫 tr（2026-10-20 实跑结论，勿回滚）：
## Object 自带 tr(StringName, StringName) -> String（gettext 翻译接口）。
## 在它上面**任何**签名（哪怕与父签名逐字一致）声明 tr，GDScript 4.3 都会报
##   Parse Error: The method "tr()" overrides a method from native class "Object".
##   (Warning treated as error.)
## → 整个脚本 Parse Error → autoload Localize 创建失败 → 全项目 Localize.* 调用全是死的。
## 实测结论：**这是名字冲突，不是签名问题；改名是唯一出路。**
##
## 为什么是 text 而不是 t() / get_text()：
## · t() —— 单字母，全仓 grep "t(" 噪音太大，且读起来像临时变量，不抗误读。
## · get_text() —— 本类不做任何"取回某个对象"的事，get_ 前缀暗示有对应 set_/属性，
##   与 set_lang/get_lang 那对"真的有状态"的 getter 混在一起，语义错。
## · text() —— 无前缀、名词直陈，与 trf→textf 成对，一眼看出是"查文本"。
##
## 为什么参数是 String 而不是 StringName：
## _table 的键来自 strings.csv 的 line.split(",")，是 String 不是 StringName。
## 拿 StringName 去查 String 键属于"能跑但没保证"的隐式转换，不赌它。
func text(key: String) -> String:
	var entry: Dictionary = _table.get(key, {})
	if entry.is_empty():
		if OS.is_debug_build():
			push_warning("missing locale key: %s" % key)
		return key
	return String(entry.get(_lang, entry.get(FALLBACK_LANG, key)))

## 带参数：Localize.textf("EV_TRAP_HINT", {"days": 3})
##
## 将来若需要复数形式 / 占位符顺序不同的语言，内部换成 Godot 的
## TranslationServer + tr_n() 即可——**调用点一个都不用动**，这是把文本入口
## 收在本类里的全部收益所在。改动只允许发生在本文件内。
func textf(key: String, args: Dictionary) -> String:
	var s := text(key)
	for k: String in args:
		s = s.replace("{%s}" % k, str(args[k]))
	return s
