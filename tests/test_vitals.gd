extends RefCounted
## tests/test_vitals.gd — 域判据：状态·每夜硬失能额度 【包 F · W2 判据移植】
##
## 判据定义来源：vitals_system.gd 文件头设计定稿（M13：每夜硬失能(野睡+失能合计)≤1次，
## 第 2 次起 DeBUFF）+ 架构方案。引用版本：vitals_system.gd@2026-10-20。
##
## 说明：M2/M2b/M3/M3b/M4（死钟/跨零份额/5% 双路径）已在 run_tests.gd（W1 修订 #1/#3），
## 本文件只覆盖 M13。DeBUFF 生效行为（第 2 次起的 debuff 挂接）依赖 TimeSystem 联动，
## 无头侧先锚定「额度计数」语义——DeBUFF 端到端归灰盒人工审查项（周报 review 列）。
##
## 能抓：野睡/失能不计同一额度（count 分家）/ reset 缺失导致跨夜累积 /
##       night_incap_exhausted 阈值被改（>=1 改成 >=2 之类）。

static func run(host) -> void:
	var vs = VitalsSystem.new()
	host.add_child(vs)   # _ready 连 GameLoop 信号（无害），写 State 走 vitals writer 白名单

	# ── M13-1：波次失能 1 次 → 每夜额度即用掉 ──
	vs.reset_night_incap()
	vs.wave_incap_refill()
	host._t("M13-1 one wave incap exhausts the nightly quota",
		vs.night_incap_exhausted() and vs.night_incap_count == 1)

	# ── M13-2：夜间额度重置后复位 ──
	vs.reset_night_incap()
	host._t("M13-2 reset_night_incap clears the quota",
		not vs.night_incap_exhausted() and vs.night_incap_count == 0)

	# ── M13-3：野睡与失能合计占用同一额度（不许分家）──
	vs.wild_sleep_penalty()
	vs.wave_incap_refill()
	host._t("M13-3 wild sleep + wave incap share ONE quota (total 2)",
		vs.night_incap_count == 2 and vs.night_incap_exhausted())

	vs.free()

	# ── M2-c 前置段锚点（W2 移植补充）：饥饿/渴速率设计定稿 5/7 per GH ──
	# M2/M3 死钟只覆盖「归零后」段（hp_max ÷ loss_per_sec），速率漂移（5→6）它抓不到
	# （变异测试 W3 将实测这一点）。归零前段的速率是设计冻结值
	# （vitals_system.gd 文件头 + 架构定稿），tests 侧冻结锚点如 M30 同款纪律。
	var f := FileAccess.open("res://data/balance/survival.json", FileAccess.READ)
	if f == null:
		host._block(["M2-c-hunger-rate", "M2-c-thirst-rate"], "blocked: survival.json unreadable")
	else:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) != TYPE_DICTIONARY:
			host._block(["M2-c-hunger-rate", "M2-c-thirst-rate"], "blocked: survival.json parse failed")
		else:
			var d: Dictionary = parsed
			host._t("M2-c hunger_rate_per_gh == 5.0 (design anchor, pre-zero segment)",
				is_equal_approx(float(d.get("hunger_rate_per_gh", -1.0)), 5.0))
			host._t("M2-c thirst_rate_per_gh == 7.0 (design anchor, pre-zero segment)",
				is_equal_approx(float(d.get("thirst_rate_per_gh", -1.0)), 7.0))
