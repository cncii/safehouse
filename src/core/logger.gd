extends Node
## logger.gd — 结构化日志（PII 契约：QA 自查表 A9 / 架构 §6.3）
##
## 只允许 5 类字段：{system, event_id, path, delta, reason}
## 禁止输出：globalize_path() 结果、绝对路径、SteamID、MAC、主机名、用户名。
## 日志量门禁：≤ 50 MB/局（QA S11），debug 模式下重复 message > 1000 次自动降采样。

const MAX_PER_FRAME := 64
const MAX_SAME_MESSAGE := 1000

var _enabled := true
var _counts: Dictionary = {}      # message -> 次数
var _frame_count := 0
var _dropped := 0

func set_enabled(v: bool) -> void:
	_enabled = v

## 唯一入口。system=模块名，event_id=事件枚举，path=状态路径（可空），
## delta=数值增量（可空），reason=人读说明（必须能定位"哪个系统在什么时机做了什么"）。
func log(system: StringName, event_id: StringName, path: String = "", delta: Variant = null, reason: String = "") -> void:
	if not _enabled:
		return
	_frame_count += 1
	if _frame_count > MAX_PER_FRAME:
		_dropped += 1
		return
	var key := "%s|%s|%s" % [system, event_id, path]
	_counts[key] = int(_counts.get(key, 0)) + 1
	if int(_counts[key]) > MAX_SAME_MESSAGE:
		return  # 降采样，防日志膨胀
	var line := "sys=%s ev=%s" % [system, event_id]
	if path != "":
		line += " path=%s" % path
	if delta != null:
		line += " delta=%s" % str(delta)
	if reason != "":
		line += " why=%s" % reason
	print(line)

func frame_reset() -> void:
	_frame_count = 0

## PII 自检（S10 / QA A9 的运行期部分）：任何路径写入前过一遍
func contains_pii(text: String) -> bool:
	for token: String in ["Users\\", "C:\\", "AppData", "steam_", "STEAM_", "COM", "\\Device"]:
		if text.contains(token):
			return true
	return false
