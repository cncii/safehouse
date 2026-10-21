extends SceneTree

# palette_map.gdshader 静态解析检查
# 用途：确认 Godot 4.3 能解析该 shader 并列出 uniform。
# 注意：--headless 是 dummy 渲染器，真正的 GPU 编译需要窗口；本检查只验证语法层。

const SHADER_PATH := "res://assets/shaders/palette_map.gdshader"

func _initialize() -> void:
	var code := FileAccess.get_file_as_string(SHADER_PATH)
	if code.is_empty():
		print("[shader-check] FAIL: 读不到 ", SHADER_PATH)
		quit(1)
		return

	print("[shader-check] shader 源码长度: ", code.length(), " 字符")
	var sh := Shader.new()
	sh.code = code
	var params := sh.get_shader_uniform_list()
	print("[shader-check] 解析出 uniform 数量: ", params.size())
	for p in params:
		print("  - ", p.get("name", "?"), " | type=", p.get("type", "?"),
			" | hint=", p.get("hint", "?"))

	if params.size() >= 4:
		print("[shader-check] PASS: 4 个 uniform 全部识别")
		quit(0)
	else:
		print("[shader-check] WARN: uniform 数异常（headless 下可能未真正编译）")
		quit(2)
