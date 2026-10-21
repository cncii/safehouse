class_name UITheme
extends RefCounted
## ui_theme.gd — 全项目 UI 主题装配（包 D 表现组 · 像素字体接线 S5）
##
## ── 为什么是这个文件 ──
## 美术组已按 assets/import_presets/README.md §3 规格导入 Fusion Pixel 12px
## （antialiasing=0 / subpixel=0 / 无系统回退），但 UI 侧从未接线——所有 Control
## 仍跑在 Godot 默认字体上。本文件是字体的唯一装配点。
##
## ── 像素字体纪律 ──
## 字体原生 12px，美术组实测单字度量 12.0×12.0、9 字整行 108.0（完美栅格）。
## 因此 default_font_size 只允许 12 的整数倍（12/24…）：
## 非整数倍会把位图字形落在半像素上（模糊/粗细不一），等于白做像素美术。
## HudStyle.FONT_SIZE 等显式字号常量必须与这里同律。
##
## ── 装配方式 ──
## project.godot 禁改（不能配项目级 theme / 不能加 autoload），
## 所以走 root Window.theme：root 持久存在、不被 SceneRouter 切场景释放，
## 全项目 Control 经树继承拿到字体。语言切换时只换 default_font 不重建主题。
##
## ── 语言 → 字体映射 ──
## zh_TW 用繁体版（hans 版缺繁体字形）；zh_CN / en 用简体版（含拉丁与 CJK）。
## 映射与 Localize 的语言代码（strings.csv 列名）对齐，别处不许再抄一份。

const FONT_HANS := "res://assets/fonts/font_fusion_pixel_12px_zh_hans.ttf"
const FONT_TW := "res://assets/fonts/font_fusion_pixel_12px_zh_tw.ttf"
const NATIVE_SIZE := 12

static var _cache := {}   # path -> FontFile；切换语言复用，不重复解码 7MB 字体

static func font_for_lang(lang: String) -> FontFile:
	var path := FONT_TW if lang == "zh_TW" else FONT_HANS
	if not _cache.has(path):
		var f := load(path) as FontFile
		if f == null:
			push_error("UITheme: font load failed: %s (run --import first?)" % path)
			return null
		_cache[path] = f
	return _cache[path]

static func build(lang := "zh_CN") -> Theme:
	var t := Theme.new()
	t.default_font = font_for_lang(lang)
	t.default_font_size = NATIVE_SIZE
	return t

## 启动装配（boot 自检通过后调用一次）
static func install(tree: SceneTree, lang := "zh_CN") -> void:
	tree.root.theme = build(lang)

## 语言切换后调用（settings_screen._on_lang_selected）：
## 只换 default_font，保持 theme 对象与其余覆盖项不动
static func retint_lang(tree: SceneTree, lang: String) -> void:
	var t := tree.root.theme
	if t == null:
		install(tree, lang)
		return
	t.default_font = font_for_lang(lang)
