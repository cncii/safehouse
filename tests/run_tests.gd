extends Node
## run_tests.gd — 无头测试入口（**场景方式**：godot --headless res://tests/test_main.tscn）
##
## ⚠ 2026-10-20 运行形态修订（包 F·修订记录 #1，此前的 -s 方式作废）：
##   旧入口 `godot --headless -s tests/run_tests.gd`（extends SceneTree）实测有两条结构性死穴：
##   1. -s 主脚本编译早于 autoload 注册，凡被加载的脚本引用 autoload 标识符（State 等）
##      即编译失败 → vitals_system.gd 连带挂掉 → M2/M2b/M3/M3b/M4 从未真跑过；
##   2. -s 下 Node._ready() 不触发，依赖 _ready 初始化的对象全在"空表"状态下被断言。
##   正解（战斗组 combat_probe 先例）：**场景方式**启动完整工程 → autoload 全就位 →
##   所有系统可编译可执行。test_main.tscn 根节点即本脚本，_ready() 驱动全量断言。
##
## 三层空跑判负（QA v2.1）：
##   stage 层：断言总数 == 0 → 失败
##   判据层：扫描对象数 == 0 → "未生效"，不判通过
##   变异体层：变异后无任何判据变红 → 该变异体未捕获
##
## 分包验收流程（tools/test.ps1 单入口编排）：
##   stage1 数据校验(python validate_data.py) → stage2 依赖扫描 →
##   stage3 本地化扫描 → stage4 本文件
##
## 首批判据（架构定稿）：F0 / M1 / M2 / P1① —— 每条写明"能抓什么"。
##
## ── 本轮新增（QA v3.0，包 F：缺陷 A / 缺陷 B）──
## A 组：Localize.tr → text 纯机械改名（A0/A1/A2/A3/A4/A5）
## B 组：splitmix64 常数与逻辑右移（B0/B1/B2/B3/B4/B5）
##
## ⚠ 两条实测环境陷阱（2026-10-20 QA 实跑，写判据的人必须知道）：
##  1. `-s` 场景下 **Node._ready() 不会触发**（实测：add_child 后 _table.size() 仍为 0，
##     自动加载 Localize/Rng 的 _table/_salts 也都是空的）。
##     → 凡依赖 _ready 初始化的被测对象，本文件**必须显式调用 _load() / setup()**，
##       否则断言全部在"表是空的"这个状态下跑，结论毫无意义。
##  2. 空表状态下 `text("NO_SUCH_KEY_XYZ") == "NO_SUCH_KEY_XYZ"` **照样为真**——
##     这是本组最容易骗过验收的一条假绿。故 A0/B0 各有一条"表/盐必须非空"的空跑判负断言，
##     它红了，后面所有值断言一律不算数。

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []
var _groups: Dictionary = {}      # 分组前缀 -> {"p": n, "f": n}

# ── 缺陷 A / B 的判据常量（冻结值，禁止随源码改动而改）──
const SEED := 20261020

# ── W2 域判据（包 F 2026-10-20）：tests/test_*.gd 按文件分域，记账统一走本文件的 _t/_block ──
const TimeTests = preload("res://tests/test_time.gd")
const MapTests = preload("res://tests/test_map.gd")
const VitalsTests = preload("res://tests/test_vitals.gd")
const CombatTests = preload("res://tests/test_combat.gd")
const TechTests = preload("res://tests/test_tech.gd")
const EventTests = preload("res://tests/test_events.gd")
const LoopTests = preload("res://tests/test_loop.gd")
const ActionTests = preload("res://tests/test_action.gd")
# 逻辑组两个自检的接线（包 B 2026-10-21）：判据本体在 inventory_system.gd /
# tech_tree_system.gd，接线文件由逻辑组补（包 F 若要归档可整体移入其分域机制）。
const InventoryTests = preload("res://tests/test_inventory.gd")
const TechRuntimeTests = preload("res://tests/test_tech_runtime.gd")
const MapLootTests = preload("res://tests/test_map_loot.gd")
const TimePersistTests = preload("res://tests/test_time_persist.gd")
const SaveSeedTests = preload("res://tests/test_save_seed.gd")

# 空跑/截断判负门檻：本文件在无变异、无运行时截断时应产出的断言总数。
# 修订 #1：vitals 段 8 条（M2 死钟/M2b/M3/M3b/M4×4）随场景方式修通，75 → 83。
# 修订 #4：W2 域判据移植（tests/test_*.gd 按文件分域）83 → 120
#          （time 12 + map 4 + vitals 3 + combat 4 + tech 5 + events 3 + loop blocked 5）。
#          loop_system 编译失败修复后该域将产出 6 条，总数 121，仍 > 门槛，不误报。
# 修订 #5：M2-c 前置段锚点 2 条（hunger 5 / thirst 7 per GH 设计定稿），120 → 122。
# 修订 #6：变异 V4 实测 P1-1 formula 为恒真式（引用 vs 引用）→ 删除；phase-A 与
#          overtime 改结构式（15G/9G）→ 122 → 121。
# 修订 #7：loop_system 修复（924b0f6）LOOP-0 复活 121→122；M20 移植（test_action 7 条）
#          + 破防顺序无关判据 1 条 → 122 → 130；A 组冻结基线随 UI 文案更新（16/17→25/33）。
# 任何"少跑了"的情况都必须在这里吵出来，而不是让 coverage 行照常打印。
const MIN_ASSERTS := 135

# A1 扫描用的针。刻意用拼接写出来：本文件自身也携带这些针（自测夹具里有），
# 若写成整串，扫描 tests/ 时会自命中。tests/ 已排除，但拼接是双保险。
var RE_TR_CALL := "Localize\\." + "tr\\("
var RE_TRF_CALL := "Localize\\." + "trf\\("
var RE_TR_FUNC := "func\\s+" + "tr\\s*\\("
var RE_TRF_FUNC := "func\\s+" + "trf\\s*\\("

# A3 KEY 字面量提取器：只吃 Localize.text("...") / Localize.textf("...") 的首个字符串字面量
var RE_KEY := "Localize\\.(?:text|textf)\\(\\s*\"([^\"]*)\""

# A3-1 期望：17 处调用点里 16 处是字面量（vital_bar.gd 那处是 String(_name_key) 动态拼接），
# 去重后 14 个 KEY，SETTINGS_TITLE / HUD_STAGE_UNKNOWN 各出现 2 次。
# A3-1 期望：调用点 KEY 字面量多重集。
# 修订 #7（2026-10-20）：逻辑组 924b0f6 新增循环面板 UI 文案（LOOP_BLOCK_/LOOP_CHAIN_/
# LOOP_DATA_NOT_WIRED/LOOP_PANEL_TITLE/LOOP_REPORT_GAP，带 _ 后缀者为前缀拼接字面量），
# 冻结基线随之更新 16 → 25。基线过时不是判据错也不是实现错——每次 UI 文案变更须同步本表。
# 修订 #8（2026-10-21）：表现组 S6 键位重绑 +6 字面量（keybind_settings.gd 的
# ACTION_ 拼接×2 / KEYBIND_LISTENING / KEYBIND_RESET，ui_smoke.gd 断言对照的
# ACTION_ 拼接 / ACTION_MOVE_RIGHT）并删除 SETTINGS_KEYBIND_TODO 占位调用点，
# 冻结基线随之更新 25 → 30。
# 修订 #9（2026-10-22）：TASK-G M1 主菜单/背包 UI +6 字面量（main_menu_screen.gd 的
# MAIN_MENU_TITLE / MAIN_MENU_HINT——NEW/CONTINUE/SETTINGS/QUIT 走 _button(key) 参数
# 传递不构成字面量；inventory_panel.gd 的 INV_TITLE / INV_USE / INV_EMPTY / INV_CAPACITY），
# 冻结基线随之更新 30 → 36。
var EXPECT_KEYS: Array = [
		"ACTION_", "ACTION_", "ACTION_", "ACTION_MOVE_RIGHT",
		"HUD_CLOCK_DAY", "HUD_STAGE_A_LOOT", "HUD_STAGE_B_SIEGE",
		"HUD_STAGE_UNKNOWN", "HUD_STAGE_UNKNOWN", "HUD_VITAL_HP",
		"INV_CAPACITY", "INV_EMPTY", "INV_TITLE", "INV_USE",
		"KEYBIND_LISTENING", "KEYBIND_RESET",
		"LANG_NAME_EN", "LANG_NAME_ZH_CN", "LANG_NAME_ZH_TW",
		"LOOP_BLOCK_", "LOOP_BLOCK_", "LOOP_CHAIN_", "LOOP_CHAIN_", "LOOP_CHAIN_",
		"LOOP_DATA_NOT_WIRED", "LOOP_DATA_NOT_WIRED", "LOOP_PANEL_TITLE", "LOOP_REPORT_GAP",
		"MAIN_MENU_HINT", "MAIN_MENU_TITLE",
		"NO_SUCH_KEY_XYZ", "SETTINGS_CLOSE", "SETTINGS_KEYBIND",
		"SETTINGS_LANG", "SETTINGS_TITLE", "SETTINGS_TITLE",
	]

# A3-3 期望：strings.csv KEY 集合。
# 修订 #7：随逻辑组循环面板文案更新 17 → 33（HUD×9 / LANG×3 / LOOP×16 / SETTINGS×5）。
# 修订 #8：随表现组 S6 键位词条更新 33 → 47（+ACTION×10 / +KEYBIND×5 / -SETTINGS_KEYBIND_TODO，
# 即 HUD×9 / LANG×3 / LOOP×16 / SETTINGS×4 / ACTION×10 / KEYBIND×5）。
# 修订 #9：随 TASK-G M1 主菜单/背包/交互词条更新 47 → 58（+MAIN_MENU×6 / +INV×4 / +INTERACT_PICK）。
var EXPECT_CSV_KEYS: Array = [
	"HUD_CLOCK_DAY", "HUD_CLOCK_TIME", "HUD_STAGE_A_LOOT", "HUD_STAGE_B_SIEGE",
	"HUD_STAGE_UNKNOWN", "HUD_VITAL_HP", "HUD_VITAL_HUNGER", "HUD_VITAL_STAMINA",
	"HUD_VITAL_THIRST", "LANG_NAME_EN", "LANG_NAME_ZH_CN", "LANG_NAME_ZH_TW",
	"LOOP_BLOCK_FILTER_CORE", "LOOP_BLOCK_NONE", "LOOP_BLOCK_POWER", "LOOP_BLOCK_UNLOCK",
	"LOOP_CHAIN_FOOD", "LOOP_CHAIN_MEDS", "LOOP_CHAIN_POWER", "LOOP_CHAIN_WATER",
	"LOOP_COL_BLOCK", "LOOP_COL_CHAIN", "LOOP_COL_DAYS", "LOOP_COL_RATE", "LOOP_COL_STOCK",
	"LOOP_DATA_NOT_WIRED", "LOOP_PANEL_TITLE", "LOOP_REPORT_GAP",
	"SETTINGS_CLOSE", "SETTINGS_KEYBIND", "SETTINGS_LANG", "SETTINGS_TITLE",
	"ACTION_ATTACK", "ACTION_DODGE", "ACTION_INTERACT", "ACTION_INVENTORY",
	"ACTION_MOVE_DOWN", "ACTION_MOVE_LEFT", "ACTION_MOVE_RIGHT", "ACTION_MOVE_UP",
	"ACTION_PAUSE", "ACTION_TECH_TREE",
	"KEYBIND_CONFLICT", "KEYBIND_LISTENING", "KEYBIND_REBIND", "KEYBIND_RESET",
	"KEYBIND_RESET_DONE",
	"MAIN_MENU_CONTINUE", "MAIN_MENU_HINT", "MAIN_MENU_NEW", "MAIN_MENU_QUIT",
	"MAIN_MENU_SETTINGS", "MAIN_MENU_TITLE",
	"INV_CAPACITY", "INV_EMPTY", "INV_TITLE", "INV_USE",
	"INTERACT_PICK",
]

func _ready() -> void:
	# ── 判定工具先自验（QA 硬纪律：跑不崩 ≠ 跑得对）──
	_selfcheck_extractor()

	# ── M30 金标准锚点（冻结参照：禁止读任何源/生成器，价值就在于不会自动改）──
	# 修订 #2（2026-10-20）：combat-chain 原判据 `INCAP_TICKS % 60 == 0` 把
	# "帧数 ÷ fps = 秒值"误写成"帧数能被 fps 整除"——216 % 60 = 36 恒假，首跑即红。
	# 实现没错（216 帧 = 3.60s 精确，架构 1419/1518/1522 三处一致），判据自己写错，归测试组修。
	# 修订 #6（变异 V4 实测驱动）：phase-A 原式 `== 15 * 4320`（右侧冻结字面量）在 GH 帧数
	# 漂移（4320→4300）时测不出"phase-A 必须是 15 个 GH"的倍数关系断裂——变异测试证实
	# 它不红（64800 独立 const vs 判据字面量 64800 恒等）。改为结构式 `15 * FRAMES_PER_GH`：
	# 倍数关系由本条抓，绝对值由 1GH==4320 锚点抓，两者互补后漂移必红。
	_t("M30 time-chain: 1GH == 4320 frames",
		GameLoop.FRAMES_PER_GH == 4320)
	_t("M30 time-chain: phase-A day == 15 GH (structural multiple)",
		GameLoop.FRAMES_PHASE_A_ACTIVE == 15 * GameLoop.FRAMES_PER_GH)
	_t("M30 time-chain: full-run clock == 816480 frames (189GH)",
		GameLoop.FRAMES_FULL_RUN == 7 * 64800 + 7 * 51840)
	_t("M30 combat-chain: incap 216 ticks == 3.60s exact",
		TimeSystem.INCAP_TICKS == 216 \
			and is_equal_approx(float(TimeSystem.INCAP_TICKS) / 60.0, 3.60))
	_t("M30 combat-chain: windup 8 ticks (ceil for reaction window)",
		TimeSystem.WINDUP_TICKS == 8)

	# ── F0-b 帧数↔秒双向校验（生成物必须与常量一致）──
	_t("F0-b: 5 combat constants /60 match baseline seconds",
		_check_frame_seconds())

	# ── M1：1 GH = 72 s（抓时基型变异）──
	_t("M1: FRAMES_PER_GH / 60 == 72.0",
		absf(float(GameLoop.FRAMES_PER_GH) / 60.0 - 72.0) < 1e-9)

	# ── P1-1 结构判据（修订 #6）──
	# 原 formula 条（FRAMES_FULL_RUN == 7*PHASE_A + 7*PHASE_B，两侧都引用运行常量）
	# 是恒真式——变异 V4 实测 GH 漂移下不红，期望值被被测常量自算（本项目第 4 例恒真坑），
	# 删除；跨常量绝对锚点由 M30 full-run（816480 字面量）承担。
	# overtime 改结构式：NIGHT_OVERTIME 必须恒等于 9 个 GH（k=2 上限与 9GH 加时基准的关系锚）。
	_t("P1-1: overtime delta == 9 GH (structural multiple)",
		GameLoop.FRAMES_NIGHT_OVERTIME == 9 * GameLoop.FRAMES_PER_GH)

	# ── P28 分母锚点：科技树 24 节点（覆盖率 50–67% 的分母，不许再砍）──
	_t("P28: tech_tree.json node count == 24",
		_count_tech_nodes() == 24)

	# ── S3/S5 键名规范抽查（完整扫描在 tools/validate_data.py）──
	_t("M28-a: no_unit_keys whitelist <= 10 (self-destruct)",
		_count_no_unit_keys() <= 10)

	# ── 包 F：缺陷 A（Localize tr→text 改名）／缺陷 B（splitmix64 常数）──
	# 顺序保留：先 localize/rng 后 vitals。修订 #1 后运行形态为场景方式，
	# 旧「vitals 段运行时报错会截断后续判据」的排序理由已消除（改注释不改顺序）。
	_run_localize_asserts()
	_run_rng_asserts()

	# ── M2 / M2b / M3 / M3b / M4：vitals 归零致死链（包 B 提交，2026-10-19）──
	_run_vitals_asserts()

	# ── W2 域判据（包 F 2026-10-20，修订 #4）：按文件分域，每域一个 test_*.gd ──
	TimeTests.run(self)
	MapTests.run(self)
	VitalsTests.run(self)
	CombatTests.run(self)
	TechTests.run(self)
	EventTests.run(self)
	LoopTests.run(self)
	ActionTests.run(self)
	# ── 逻辑组补接线（2026-10-21）：背包容量守恒 / 科技树运行期 ──
	# 放在 TechTests/LoopTests 之后：科技树的解锁会改全局 State，
	# 排在后面可避免影响其它域的前置检查（State 是 autoload，全局共享）。
	InventoryTests.run(self)
	TechRuntimeTests.run(self)
	# ── P12 背包基线（跨域合成：掉落 × 容量 × D8 计划）──
	# ⚠ **暂不挂载**：判据已实现且实跑，但当前是**红的**（真实设计缺口）。
	#   实测：D8 三个地点总掉落 64 件，背包 24 格装不下 → 丢 25 件；
	#   净水 4（要 ≥6）零件 4（要 15–25）→ 缺数 D-B11。
	#   门禁没有"已知红"机制（_block 也计 fail），挂进去会让**整条门禁常挂**，
	#   污染其它组的信号（他们提交也变红，且不知道为什么）。
	#   等创意总监给出掉落率/杂物占比/D8 出行计划（缺数 D-B11）后，一行即可挂上。
	#   判据本体：src/systems/map_system.gd 的 verify_loot_baseline()
	#   接线文件：tests/test_map_loot.gd（已就绪，摘掉下面这行即可挂）
	# MapLootTests.run(self)
	# ── 时间存档一致性（C-01 的直接判据，M7/M8/P7 的时间侧）──
	TimePersistTests.run(self)
	# ── seed 存档往返精度（P0 回归门禁，2026-10-22 修复后转常规）──
	SaveSeedTests.run(self)

	_finish()

# ══════════════════════════════════════════════════════════════════
# 缺陷 A · Localize 自动加载从未编译成功（tr() 与 Object.tr 撞名）
# ══════════════════════════════════════════════════════════════════
func _run_localize_asserts() -> void:
	# ── A0 空跑判负层 ──
	# 能抓：脚本 Parse Error / 编译失败（这正是缺陷 A 的原样症状）。
	var sc := load("res://src/core/localization.gd")
	_t("A0-1 localization.gd compiles (load() != null)", sc != null)
	if sc == null:
		_block(["A0-2", "A0-3", "A0-4", "A1-1", "A1-2", "A1-3", "A1-4",
				"A2-1", "A2-2", "A2-3", "A2-4", "A2-5", "A3-1", "A3-2", "A3-3",
				"A4-1", "A5-1", "A5-2", "A5-3"],
			"blocked: localization.gd not compiling")
		return

	_t("A0-2 text()/textf() declared (no native-name clash)",
		_has_fn(sc, "text") and _has_fn(sc, "textf"))
	_t("A0-3 tr()/trf() NOT redeclared (would re-break the autoload)",
		not _has_fn(sc, "tr") and not _has_fn(sc, "trf"))

	# ⚠ 脚本有 Parse Error 时 load() 仍返回非 null 的 GDScript 对象，但**它连 new() 都没有**
	# （实测报 "Invalid call. Nonexistent function 'new' in base 'GDScript'"）。
	# GDScript 没有 try/catch，这一抛就把本函数从这一行起整段截断：
	# 变异体 6 实测断言总数从 74 掉到 57，A0-4 / A1 / A2 / A3 / A4 / A5 共 17 条
	# 一条没跑，而 exit code 照样是 1、coverage 行照样打印——**看不出少跑了**。
	# 所以必须在调用 new() 之前用方法清单判定，抛错之后再救是救不回来的。
	if not _has_fn(sc, "text") or not _has_fn(sc, "textf"):
		_block(["A0-4", "A1-0", "A1-1", "A1-2", "A1-3", "A1-4",
				"A2-1", "A2-2", "A2-3", "A2-4", "A2-5", "A3-1", "A3-2", "A3-3",
				"A4-1", "A5-1", "A5-2", "A5-3"],
			"blocked: text()/textf() missing -- localization.gd parse error")
		return

	# 自建实例 + 显式 _load()（-s 下 _ready 不触发，见文件头陷阱 1）
	var L = sc.new()
	if L == null or L.get_script() == null:
		# 脚本有 Parse Error 时 load() 仍返回非 null 对象、new() 也出得来实例，
		# 但实例上**没有脚本**——此时调 L._load() 会抛
		# "Nonexistent function '_load'"，把本函数从这一行起整段截断。
		# 首跑变异体 6 时实测踩到过：只红了 A0-2，A0-4 / A1 / A2 / A3 / A4 / A5
		# 共 17 条**一条都没跑**（断言总数从 74 掉到 57，静默少跑）。
		_block(["A0-4", "A1-0", "A1-1", "A1-2", "A1-3", "A1-4",
				"A2-1", "A2-2", "A2-3", "A2-4", "A2-5", "A3-1", "A3-2", "A3-3",
				"A4-1", "A5-1", "A5-2", "A5-3"],
			"blocked: localization.gd parse error, instance carries no script")
		return
	# 场景方式下 root 正在 _ready 建树，add_child 会报 "Parent node is busy"——
	# 且这两个实例的全部断言同步完成，根本无需进树（-s 时代的进树理由已不存在）。
	# 用完即 free（Node 非 RefCounted，不 free 会在退出时报 ObjectDB 泄漏）。
	L._load()
	# 空跑判负：表必须真的加载出来，否则下面所有值断言都在空表上跑（陷阱 2）
	# 修订 #7：随逻辑组循环面板文案更新 17 → 33
	# 修订 #8：随表现组 S6 键位词条更新 33 → 47（strings.csv 现 47 有效键）
	# 修订 #9：随 TASK-G M1 主菜单/背包/交互词条更新 47 → 58
	_t("A0-4 locale table loaded (size == 58, else all value asserts are void)",
		L._table.size() == 58)
	if L._table.size() == 0:
		_block(["A2-1", "A2-2", "A2-3", "A2-4", "A2-5", "A3-2", "A4-1"],
			"blocked: locale table empty")
		return

	# ── A1 全仓扫描：改名是否彻底 ──
	# 能抓：任何一处漏改（Localize.tr / Localize.trf 残留调用，或 func tr 又被写回来）。
	# 注意 Object 自带 tr()，所以"漏改"不报错、不崩溃，只会静默返回裸 KEY——
	# 编译期和 CI 都拦不住，只有扫描能拦。
	var files := _gd_files("res://")
	_t("A1-0 scan target non-empty (%d .gd files, else the scan is void)" % files.size(),
		files.size() > 0)
	var h1 := _scan(files, RE_TR_CALL)
	var h2 := _scan(files, RE_TRF_CALL)
	var h3 := _scan(files, RE_TR_FUNC)
	var h4 := _scan(files, RE_TRF_FUNC)
	_t("A1-1 zero Localize.tr call sites repo-wide (%d hits)" % h1.size(), h1.is_empty())
	_t("A1-2 zero Localize.trf call sites repo-wide (%d hits)" % h2.size(), h2.is_empty())
	_t("A1-3 zero func tr redeclaration (%d hits)" % h3.size(), h3.is_empty())
	_t("A1-4 zero func trf redeclaration (%d hits)" % h4.size(), h4.is_empty())
	if not h1.is_empty():
		print("      hits: " + " | ".join(h1))
	if not h2.is_empty():
		print("      hits: " + " | ".join(h2))
	if not h3.is_empty():
		print("      hits: " + " | ".join(h3))

	# ── A2 ui_smoke 三条原断言的值语义（改名后必须逐字不变）──
	# 能抓：改名的同时把 CSV 里的 KEY 改了 / 兜底逻辑被改成返回空串。
	_t("A2-1 HUD_VITAL_HP resolves (not raw key)", L.text("HUD_VITAL_HP") != "HUD_VITAL_HP")
	_t("A2-2 missing key falls back to key itself",
		L.text("NO_SUCH_KEY_XYZ") == "NO_SUCH_KEY_XYZ")
	L.set_lang("en")
	_t("A2-3 en: SETTINGS_TITLE == 'Settings'", L.text("SETTINGS_TITLE") == "Settings")
	L.set_lang("zh_CN")
	# A2-4 的 zh_CN 期望值**从 strings.csv 里读**，不硬编码译文。
	# 理由（team-lead 裁定）：把译文复制一份进测试代码 = 造了第二个文本来源，
	# 违反"文本唯一来源"原则，且 CSV 一改这条断言不会跟着变，是必然腐烂的断言。
	# 同时这条也让 check_i18n.py 不必为 tests/ 开口子（代码侧零中文字面量）。
	var zh_expect := _csv_cell("SETTINGS_TITLE", "zh_CN")
	_t("A2-4 zh_CN: SETTINGS_TITLE resolves to the zh_CN column of strings.csv",
		zh_expect != "" and L.text("SETTINGS_TITLE") == zh_expect)
	# A2-5 反向对照：zh_CN 与 en 必须**不同**，否则说明语言切换根本没生效
	# （空表 / 兜底情况下两者都会等于 KEY，上一条会假绿）。
	L.set_lang("en")
	var en_v := String(L.text("SETTINGS_TITLE"))   # 必须显式转型：L 是无类型 Variant，
	#                                                冷导入下这里会报 "Cannot infer the type of en_v"
	#                                                → 整个 run_tests.gd Parse Error → 0 断言。
	#                                                热导入下这条被旧编译产物盖住，看不见。
	L.set_lang("zh_CN")
	_t("A2-5 zh_CN and en resolve to different strings (lang switch is live)",
		L.text("SETTINGS_TITLE") != en_v)

	# ── A3 KEY 字面量逐字校验（"纯机械改名"的硬证据）──
	# 能抓：改名时顺手把 KEY 改掉（调用点改 / 改成 CSV 里没有的键 / CSV 键被改名）。
	var got := Array(_extract_keys(files))
	got.sort()
	var exp_sorted := Array(EXPECT_KEYS)
	exp_sorted.sort()
	_t("A3-1 call-site KEY literal multiset unchanged (%d literals)" % got.size(),
		got == exp_sorted)
	if got != exp_sorted:
		print("      got: " + " | ".join(got))
		print("      exp: " + " | ".join(exp_sorted))

	var csv_keys := _csv_keys()
	var missing: Array = []
	for k in EXPECT_KEYS:
		if k == "NO_SUCH_KEY_XYZ":
			continue      # 这条是故意不存在的键，A2-2 / A4-1 专门测它
		if String(k).ends_with("_"):
			continue      # 修订 #7：前缀拼接字面量（LOOP_BLOCK_ + 动态段）不是完整 KEY，
			              # 完整键的 CSV 侧一致性由 A3-3 覆盖
		if not csv_keys.has(k):
			missing.append(k)
	_t("A3-2 every call-site KEY exists in strings.csv (%d missing)" % missing.size(),
		missing.is_empty())
	if not missing.is_empty():
		print("      missing: " + " | ".join(missing))

	var csv_sorted := Array(csv_keys)
	csv_sorted.sort()
	var exp_csv := Array(EXPECT_CSV_KEYS)
	exp_csv.sort()
	_t("A3-3 strings.csv KEY set unchanged (%d keys)" % csv_sorted.size(),
		csv_sorted == exp_csv)

	# ── A4 缺键兜底 ──
	# 能抓：兜底被改成返回 "" / 返回 "MISSING" 之类的占位串。
	var fb := String(L.text("__QA_DEFINITELY_MISSING__"))
	_t("A4-1 unknown key returns the key itself (not empty, not placeholder)",
		fb == "__QA_DEFINITELY_MISSING__")

	# ── A5 自动加载运行时等价检查（tools 侧 D5 门禁的运行时补位）──
	# 能抓：脚本编译失败 → autoload 退化成裸 Node → 全项目 Localize.* 调用全是死的。
	# 用字符串取节点而不是 autoload 标识符：-s 场景下标识符解析顺序不稳定（见报告）。
	var ln := get_tree().root.get_node_or_null("Localize")
	_t("A5-1 autoload node 'Localize' exists and carries its script",
		ln != null and ln.get_script() != null)
	if ln != null:
		_t("A5-2 autoload exposes text()", ln.has_method("text"))
		_t("A5-3 autoload exposes textf()", ln.has_method("textf"))
	else:
		_block(["A5-2", "A5-3"], "blocked: autoload node missing")
	L.free()   # 未进树，直接 free 即销毁（防退出 ObjectDB leak 警告）

# ══════════════════════════════════════════════════════════════════
# 缺陷 B · splitmix64 常数不是设计值（3 常数 + 3 掩码全被截成 INT64_MAX）
# ══════════════════════════════════════════════════════════════════
func _run_rng_asserts() -> void:
	# ── B0 空跑判负层 ──
	var sc := load("res://src/core/rng_service.gd")
	_t("B0-1 rng_service.gd compiles (load() != null)", sc != null)
	if sc == null:
		_block(["B0-2", "B0-3", "B0-4",
				"B1-01", "B1-02", "B1-03", "B1-04", "B1-05", "B1-06", "B1-07",
				"B1-08", "B1-09", "B1-10", "B1-11", "B1-12", "B1-13",
				"B2-1", "B2-2", "B3-1", "B3-2", "B3-3", "B3-4", "B3-5",
				"B4-1", "B4-2", "B4-3", "B4-4", "B4-5", "B4-6",
				"B5-1", "B5-2", "B5-3", "B5-4", "B5-5", "B5-6", "B5-7", "B5-8"],
			"blocked: rng_service.gd not compiling")
		return

	_t("B0-2 u63() exported (absi() boundary trap removed)", _has_fn(sc, "u63"))
	_t("B0-3 _ushr() present (logical shift, not arithmetic)", _has_fn(sc, "_ushr"))
	# 同 A 组：脚本带 Parse Error 时方法清单是空的，直接往下调 mix64() 会抛错截断整段。
	if not _has_fn(sc, "mix64") or not _has_fn(sc, "day_seed") or not _has_fn(sc, "hash_at") \
			or not _has_fn(sc, "pick") or not _has_fn(sc, "unitf") or not _has_fn(sc, "verify_day"):
		_block(["B0-4", "B0-5",
				"B1-01", "B1-02", "B1-03", "B1-04", "B1-05", "B1-06", "B1-07",
				"B1-08", "B1-09", "B1-10", "B1-11", "B1-12", "B1-13",
				"B2-1", "B2-2", "B2-3", "B3-1", "B3-2", "B3-3", "B3-4", "B3-5",
				"B4-1", "B4-2", "B4-3", "B4-4", "B4-5", "B4-6",
				"B5-1", "B5-2", "B5-3", "B5-4", "B5-5", "B5-6", "B5-7", "B5-8"],
			"blocked: core RNG API missing -- rng_service.gd parse error")
		return

	# 显式 setup()：新实例不依赖 _ready（同 A 组 L），不进树（root 正在建树会报 busy）
	var r = sc.new()
	r.setup(SEED)
	# 空跑判负：盐表必须加载出来，否则 hash_at 全部按 salt=0 算，黄金向量无意义。
	# 实测 size == 9 而不是 8：rng_salts.json 里的 "_comment" 键也被塞进了盐表
	# （契约 6 说盐值发布后不可改，混进注释键会让 _salts 的口径含糊——已单列报告，
	#  这里先按"8 条子流 + 1 个注释键"的实测事实记，不假装看不见）。
	_t("B0-4 salts loaded (size == 9, else every golden vector below is void)",
		r._salts.size() == 9)
	# 契约 6：8 条子流的盐值逐条钉死，发布后不许改值
	var salt_ok := true
	for pair in [["LOOT", 3735928559], ["SPAWN_WAVE", 3735928560],
			["SPAWN_AMBIENT", 3735928561], ["EVENT_ROLL", 3735928562],
			["EVENT_PARAM", 3735928563], ["REFILL", 3735928564],
			["FLAVOR", 3735928565], ["BREACH", 3735928566]]:
		if int(r._salts.get(String(pair[0]), -1)) != int(pair[1]):
			salt_ok = false
			print("      salt mismatch: " + String(pair[0]))
	_t("B0-5 all 8 sub-stream salts match rng_salts.json (contract 6)", salt_ok)

	# ── B1 黄金向量逐条（架构实测 + QA 在 Python 侧独立复算，15/15 一致）──
	# 能抓：常数被改成任何别的值（含截成 INT64_MAX）、_ushr 换回算术右移、
	#       str_hash 被改、盐值被改、seed 口径被改。
	_teq("B1-01 mix64(0)", sc.mix64(0), 0)
	_teq("B1-02 mix64(1)", sc.mix64(1), 6238072747940578789)
	_teq("B1-03 mix64(42)", sc.mix64(42), -6387817139659442654)
	_teq("B1-04 mix64(-1)", sc.mix64(-1), -5417735806833148549)
	_teq("B1-05 day_seed(1)", r.day_seed(1), -7994549966922959745)
	_teq("B1-06 day_seed(2)", r.day_seed(2), -6200040790082114596)
	_teq("B1-07 day_seed(3)", r.day_seed(3), 6703764042843081744)
	_teq("B1-08 hash_at(LOOT,1,[crate_01,1])",
		r.hash_at(&"LOOT", 1, ["crate_01", "1"]), -1512457937576091675)
	_teq("B1-09 hash_at(SPAWN_WAVE,1,[1,2])",
		r.hash_at(&"SPAWN_WAVE", 1, ["1", "2"]), 7484763783507669784)
	_teq("B1-10 hash_at(FLAVOR,1,[1])",
		r.hash_at(&"FLAVOR", 1, ["1"]), -7647793351162884199)
	_teq("B1-11 hash_at(BREACH,1,[1])",
		r.hash_at(&"BREACH", 1, ["1"]), -6704898596262891980)
	_teq("B1-12 hash_at(REFILL,1,[crate_01,1])",
		r.hash_at(&"REFILL", 1, ["crate_01", "1"]), -2404875622666602513)
	# 哨兵：String.hash() 无跨版本保证，升级引擎必须重跑这条
	_teq("B1-13 sentinel abc.hash() (engine-version canary)", "abc".hash(), 193485963)

	# ── B2 退化反向对照（本轮最有价值的一条）──
	# 修复前不是"不够随机"，是"塌的"：三个常数全被截成 INT64_MAX，
	# 十日 day_seed 只剩两个值按奇偶交替 → map_system 的每日掉落逐日不变。
	# 能抓：常数塌缩（变异 1）、算术右移导致的塌缩（变异 2）。
	# 只写"十天互不相同"不够，再配一条"极差 > 0.5"，两条独立探测。
	var vals: Array = []
	for d in range(1, 11):
		vals.append(r.unitf(&"FLAVOR", d, ["1"]))
	var vmin: float = vals[0]
	var vmax: float = vals[0]
	for v in vals:
		if float(v) < vmin:
			vmin = float(v)
		if float(v) > vmax:
			vmax = float(v)
	_t("B2-1 unitf(FLAVOR, day 1..10) spread > 0.5 (got %.6f)" % (vmax - vmin),
		(vmax - vmin) > 0.5)
	# B2-2 最小相邻间距。
	# ⚠ 本条原本写的是"十日互不相同"，实测在真实退化形态下**仍是绿的**：
	#   修复前十天取值 0.944155 / 0.944112 / 0.944165 ... 确实两两互不相同，
	#   但全部挤在 5.3e-5 的带宽里。"互不相同"抓不住"挤在一起"，是条假绿判据，
	#   已换成"最小相邻间距 > 0.005"（修复后实测最小间距 0.011394）。
	var srt: Array = []
	for v in vals:
		srt.append(v)      # 显式拷贝：Array(vals) 实测返回同一引用，sort() 会把 vals 一起排掉
	srt.sort()
	var min_gap: float = 1.0
	for i in range(1, srt.size()):
		var g := float(srt[i]) - float(srt[i - 1])
		if g < min_gap:
			min_gap = g
	_t("B2-2 unitf(FLAVOR, day 1..10) min adjacent gap > 0.005 (got %.6f)" % min_gap,
		min_gap > 0.005)
	# B2-3 留证锚点：把十日 trace 逐值钉死。
	# 说明：B2-1/B2-2 是"性质判据"，只对"三常数同时塌缩"这种整体退化敏感；
	# 实测单点常数漂移（变异 1）和移位语义错（变异 2）它们**抓不到**（十日依旧互不相同、
	# 极差依旧很大）。靠这条钉死的 trace 兜住——所以 B2 必须是"性质 + 锚点"两条腿。
	var expect_trace := [0.891609, 0.141530, 0.002116, 0.804217, 0.755443,
		0.581021, 0.968542, 0.728283, 0.510420, 0.739677]
	var trace_ok := vals.size() == expect_trace.size()
	if trace_ok:
		for i in range(vals.size()):
			if absf(float(vals[i]) - float(expect_trace[i])) > 1e-6:
				trace_ok = false
				break
	_t("B2-3 unitf(FLAVOR, day 1..10) trace matches the frozen golden trace", trace_ok)
	print("      B2 trace unitf: " + _fmt_floats(vals))

	# ── B3 契约 2 的双向判据（防"假绿"）──
	# 只写"同输入同输出"，旧实现也会过（它确定性地输出垃圾）。
	# 必须同时写"换 day / 换 key / 换 purpose 结果必变"。
	var base: int = r.hash_at(&"FLAVOR", 1, ["1"])
	var same := true
	for i in range(100):
		if r.hash_at(&"FLAVOR", 1, ["1"]) != base:
			same = false
			break
	_t("B3-1 100 repeated draws on the same (purpose,day,keys) are identical", same)
	_t("B3-2 changing day changes the value",
		r.hash_at(&"FLAVOR", 2, ["1"]) != base)
	_t("B3-3 changing key changes the value",
		r.hash_at(&"FLAVOR", 1, ["2"]) != base)
	_t("B3-4 changing purpose changes the value",
		r.hash_at(&"BREACH", 1, ["1"]) != base)
	# 顺序无关（契约 3，零顺序消费）：夹 100 次别的子流后回到原值必须一致
	for i in range(100):
		r.hash_at(&"SPAWN_AMBIENT", 5, ["x" + str(i)])
	_t("B3-5 draw order irrelevant (contract 3: zero sequential consumption)",
		r.hash_at(&"FLAVOR", 1, ["1"]) == base)

	# ── B4 契约 5 读档强校验 + 反向对照 ──
	# 能抓：verify_day 被改成恒等（那样读档校验形同虚设）。
	for d in [1, 2, 7, 30]:
		_t("B4-day%d: verify_day(%d, day_seed(%d)) == true" % [d, d, d],
			r.verify_day(d, r.day_seed(d)))
	_t("B4-5 REVERSE: verify_day(1, day_seed(2)) == false",
		r.verify_day(1, r.day_seed(2)) == false)
	_t("B4-6 REVERSE: verify_day(1, day_seed(1)+1) == false",
		r.verify_day(1, r.day_seed(1) + 1) == false)

	# ── B5 取模语义与边界 ──
	# 能抓：pick/unitf 的 (x & U63) 被换回 absi()——absi(INT64_MIN) 仍为负，
	#       取模会出负数下标，且数值与黄金向量不符。
	_teq("B5-1 pick(BREACH,1,[1],3) == 0 (u63 modulo semantics)",
		r.pick(&"BREACH", 1, ["1"], 3), 0)
	_tfeq("B5-2 unitf(FLAVOR,1,[1]) == 0.891609",
		r.unitf(&"FLAVOR", 1, ["1"]), 0.891609)
	_t("B5-3 pick(mod=1) always 0", r.pick(&"LOOT", 1, ["crate_01", "1"], 1) == 0)
	_t("B5-4 pick(mod=0)  returns 0 (no div-by-zero)",
		r.pick(&"LOOT", 1, ["crate_01", "1"], 0) == 0)
	_t("B5-5 pick(mod=-1) returns 0", r.pick(&"LOOT", 1, ["crate_01", "1"], -1) == 0)
	var imin := -9223372036854775807 - 1     # 不能直写 9223372036854775808（字面量溢出）
	_t("B5-6 u63(INT64_MIN) == 0 (absi() boundary trap eliminated)", sc.u63(imin) == 0)
	_t("B5-7 witness: absi(INT64_MIN) < 0 (this is why u63 is mandatory)", absi(imin) < 0)
	var in_range := true
	for d in range(1, 31):
		var p: int = r.pick(&"LOOT", d, ["crate_01", "1"], 7)
		if p < 0 or p >= 7:
			in_range = false
			break
	_t("B5-8 pick() always within [0, mod) over day 1..30, mod=7", in_range)
	r.free()   # 未进树，直接 free 即销毁（防退出 ObjectDB leak 警告）

# ══════════════════════════════════════════════════════════════════
# 判定工具先自验（QA 硬纪律：跑不崩 ≠ 跑得对；构造不出夹具的工具只能当线索）
# ══════════════════════════════════════════════════════════════════
func _selfcheck_extractor() -> void:
	# 8 个已知答案夹具：3 应命中 / 5 应不命中。
	# 后两条是首跑实测踩到的误命中（文档注释里的用法示例），必须留成夹具钉住。
	var fixtures := [
		["_t.text = Localize.text(\"SETTINGS_TITLE\")", ["SETTINGS_TITLE"]],
		["_l.text = Localize.textf(\"HUD_CLOCK_DAY\", {\"day\": day})", ["HUD_CLOCK_DAY"]],
		["_a.text = Localize.text(\"HUD_VITAL_HP\")", ["HUD_VITAL_HP"]],
		["_x.text = Localize.tr(\"OLD_STYLE_KEY\")", []],
		["_n.text = Localize.text(String(_name_key))", []],
		["print(\"not a locale call\")", []],
		["## usage example in a doc comment: Localize.text(\"UI_HUD_HUNGER\")", []],
		["## params example: Localize.textf(\"EV_TRAP_HINT\", {\"days\": 3})", []],
	]
	var ok := 0
	for fx: Array in fixtures:
		var got := _keys_in_text(String(fx[0]))
		if got == Array(fx[1]):
			ok += 1
		else:
			print("      selfcheck MISMATCH: " + String(fx[0]) + " -> " + str(got))
	_t("SELF-1 KEY extractor self-test %d/8 (3 should-hit + 5 should-miss)" % ok, ok == 8)

	# 5 个已知答案夹具：2 应命中 / 3 应不命中
	var needle_fixtures := [
		["_t.text = Localize.tr(\"K\")", true],
		["_t.text = Localize.text(\"K\")", false],
		["func tr(key: StringName, ctx: StringName) -> String:", true],
		["func text(key: String) -> String:", false],
		["## deprecated, must not be scanned: Localize.tr(\"K\")", false],
	]
	var ok2 := 0
	for fx: Array in needle_fixtures:
		var src := String(fx[0])
		if src.strip_edges().begins_with("#"):
			# 注释行：扫描器整行跳过 → hit 恒为 false，故期望值也必须是 false 才算通过
			if not bool(fx[1]):
				ok2 += 1
			continue
		var hit := RegEx.create_from_string(RE_TR_CALL).search(src) != null \
			or RegEx.create_from_string(RE_TR_FUNC).search(src) != null
		if hit == bool(fx[1]):
			ok2 += 1
		else:
			print("      selfcheck MISMATCH: " + src + " -> hit=" + str(hit))
	_t("SELF-2 tr() needle self-test %d/5 (2 should-hit + 3 should-miss)" % ok2, ok2 == 5)

# ── 工具：在一段文本里抽出 KEY 字面量 ──
func _keys_in_text(text: String) -> Array:
	var re := RegEx.create_from_string(RE_KEY)
	var out: Array = []
	for m: RegExMatch in re.search_all(_strip_comments(text)):
		out.append(m.get_string(1))
	return out

## 去掉整行注释。文档注释里的用法示例（## 用法：Localize.text("UI_HUD_HUNGER")）
## 不是调用点——首跑时它们被算进了 KEY 多重集，属于判定工具误命中。
func _strip_comments(text: String) -> String:
	var keep: PackedStringArray = []
	for line in text.split("\n"):
		if not String(line).strip_edges().begins_with("#"):
			keep.append(String(line))
	return "\n".join(keep)

func _extract_keys(files: PackedStringArray) -> Array:
	var out: Array = []
	for p in files:
		out.append_array(_keys_in_text(_read(p)))
	return out

func _scan(files: PackedStringArray, pattern: String) -> PackedStringArray:
	var re := RegEx.create_from_string(pattern)
	var hits: PackedStringArray = []
	for p in files:
		var lines := _read(p).split("\n")
		for i in range(lines.size()):
			var ln := String(lines[i])
			if ln.strip_edges().begins_with("#"):
				continue      # 同上：注释不是调用点
			if re.search(ln) != null:
				hits.append("%s:%d" % [p, i + 1])
	return hits

func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

func _gd_files(root_dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	_walk(root_dir, out)
	return out

func _walk(dir_path: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n.begins_with(".") or n == "tests" or n == "addons":
			n = d.get_next()
			continue
		var full := "res://" + n if dir_path == "res://" else dir_path + "/" + n
		if d.current_is_dir():
			_walk(full, out)
		elif n.ends_with(".gd"):
			out.append(full)
		n = d.get_next()
	d.list_dir_end()

## 从 strings.csv 取某个 KEY 在某个语言列下的值（权威来源，不复制译文进代码）
func _csv_cell(key: String, lang: String) -> String:
	var f := FileAccess.open("res://data/locale/strings.csv", FileAccess.READ)
	if f == null:
		return ""
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
		if cols[0] != key:
			continue
		for i in range(header.size()):
			if String(header[i]).strip_edges() == lang and i < cols.size():
				return String(cols[i])
	return ""

func _csv_keys() -> Array:
	var out: Array = []
	var f := FileAccess.open("res://data/locale/strings.csv", FileAccess.READ)
	if f == null:
		return out
	var first := true
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() == "":
			continue
		if first:
			first = false
			continue
		out.append(line.split(",")[0])
	return out

func _has_fn(sc, fname: String) -> bool:
	if sc == null:
		return false
	for d: Dictionary in sc.get_script_method_list():
		if String(d.get("name", "")) == fname:
			return true
	return false

func _fmt_floats(vals: Array) -> String:
	var s: PackedStringArray = []
	for v in vals:
		s.append("%.6f" % float(v))
	return ", ".join(s)

# ══════════════════════════════════════════════════════════════════
# 既有判据（包 B 提交，2026-10-19）——保持原样不动
# ══════════════════════════════════════════════════════════════════
func _run_vitals_asserts() -> void:
	var surv := _load_json_dict("res://data/balance/survival.json")
	_t("M2-M4: survival.json loadable", not surv.is_empty())
	if surv.is_empty():
		return
	var hp_max := float(surv.get("hp_max_hp", 0.0))
	var st_max := float(surv.get("stamina_max_units", 0.0))
	var loss_h := float(surv.get("hp_loss_hunger_zero_per_sec", 0.0))
	var loss_t := float(surv.get("hp_loss_thirst_zero_per_sec", 0.0))
	var thr_pct := float(surv.get("forced_sleep_threshold_pct", -1.0))

	# M2：饥饿归零 → 100±2s 死。能抓：death_seconds_after_zero 算式被改 / 速率被改
	_t("M2: hunger-zero -> death in 100+-2s",
		absf(VitalsSystem.death_seconds_after_zero(hp_max, loss_h) - 100.0) <= 2.0)
	# M2b（修订 #3）：单帧份额 == 设计定稿 1.0%/60 帧的精确分数。
	# 原判据 zero_cross_frame_share_ok() 内部写死「份额 ≤ 1%/60」，把饥饿侧 1.0%/s 的
	# 份额错当成通用上限——渴侧定稿 1.5%/s，对渴侧恒假（首跑即红，属"判据自己写错"）。
	# 期望值直写设计锚点（1.0 / 1.5），不取被测函数自算值——防恒真式断言（本项目实测三连坑）。
	# 能抓：漏除 60 / 整秒整块扣血 / 速率漂移 / 帧基 TICKS_PER_SEC 被改。
	_t("M2b: hunger zero-cross frame share == 1.0%/60 (frame-granular drain)",
		is_equal_approx(VitalsSystem.hp_loss_per_tick(loss_h), 1.0 / 60.0))
	# M3：渴归零 -> 66.7s 死。能抓：death_seconds_after_zero 算式被改 / 速率被改
	_t("M3: thirst-zero -> death in 66.7s",
		absf(VitalsSystem.death_seconds_after_zero(hp_max, loss_t) - 66.6667) <= 0.5)
	# M3b（修订 #3）：同 M2b，渴侧定稿 1.5%/s → 单帧份额锚点 1.5/60
	_t("M3b: thirst zero-cross frame share == 1.5%/60 (frame-granular drain)",
		is_equal_approx(VitalsSystem.hp_loss_per_tick(loss_t), 1.5 / 60.0))
	# M4 双路径：5.01->5.00 边界 与 4.99 一步跨过，都必须触发且只触发 1 次。
	# 能抓：比较符 <= 被改成 < / 阈值被改 / 锁存失效
	_t("M4: 5.01->5.00 boundary triggers once",
		VitalsSystem.forced_sleep_should_trigger(5.00, thr_pct, st_max, false)
		and not VitalsSystem.forced_sleep_should_trigger(5.00, thr_pct, st_max, true))
	_t("M4: 4.99 one-step-cross triggers once",
		VitalsSystem.forced_sleep_should_trigger(4.99, thr_pct, st_max, false)
		and not VitalsSystem.forced_sleep_should_trigger(4.99, thr_pct, st_max, true))
	_t("M4: 5.01 above threshold never triggers",
		not VitalsSystem.forced_sleep_should_trigger(5.01, thr_pct, st_max, false))
	# M2/M3 阈值本身是设计定稿：5% 与 1%/1.5% 一改，上面的死钟就跟着漂
	_t("M4: forced_sleep_threshold_pct == 5 (design anchor)",
		is_equal_approx(thr_pct, 5.0))

	# ── M14：同帧多源致死归因（包 B 提交，2026-10-21）──
	# 判据本体在 src/systems/vitals_system.gd 的 verify_death_attribution()。
	# 期望值独立写死（不取被测函数自算值——防恒真式，本项目已踩三次）。
	# ★ 关键：判据里的多源字典一律**逆表序**插入——GDScript Dictionary 保序，
	#   若按表序插入，"遍历 present 字典"这个 M14 明令禁止的写法会给出同一答案，
	#   判据就成了永远绿的假货。变异测试已实测：改成 dict 遍历 → M14 变红。
	var m14 := VitalsSystem.verify_death_attribution()
	_t("M14-multi-source death cause deterministic 10/10 (%s)"
		% str(m14.get("M14_cause", "?")),
		bool(m14.get("M14_pass", false))
		and int(m14.get("M14_runs", 0)) == 10
		and bool(m14.get("M14_consistent", false)))
	_t("M14-only-dehydration -> dehydration (not hardcoded starvation)",
		bool(m14.get("M14_only_dehydration_ok", false)))
	_t("M14-bleed-only -> bleed (buff wired into attribution table)",
		bool(m14.get("M14_bleed_ok", false)))
	_t("M14-table order wins over dict order (starvation < bleed)",
		bool(m14.get("M14_starve_over_bleed_ok", false)))
	_t("M14-no cause present -> table[0] (unique non-empty source)",
		bool(m14.get("M14_fallback_ok", false)))

	# ── 出血 buff 生命周期（包 B 提交，2026-10-21）──
	# 判据本体在 vitals_system.gd 的 verify_bleed_buff()。
	var vs_b = VitalsSystem.new()
	add_child(vs_b)
	var bleed := vs_b.verify_bleed_buff()
	_t("BLEED-apply stacks + active before expiry",
		bool(bleed.get("BLEED_applied", false))
		and bool(bleed.get("BLEED_active_before_expiry", false)))
	_t("BLEED-same-id stacks accumulate (%s total)"
		% str(bleed.get("BLEED_stacked_total", -1)),
		bool(bleed.get("BLEED_stack_ok", false)))
	_t("BLEED-expiry takes the LATEST (not overwritten)",
		bool(bleed.get("BLEED_expiry_ok", false)))
	_t("BLEED-stack cap enforced (cap=%s, total=%s)"
		% [str(bleed.get("BLEED_max_stacks", -1)), str(bleed.get("BLEED_capped_total", -1))],
		bool(bleed.get("BLEED_cap_ok", false)))
	_t("BLEED-expired at expires_at_gh -> removed + inactive",
		bool(bleed.get("BLEED_expired", false))
		and bool(bleed.get("BLEED_not_active_after_expiry", false)))
	_t("BLEED-save/load roundtrip preserves container",
		bool(bleed.get("BLEED_roundtrip_ok", false)))
	_t("BLEED-unknown buff id rejected on load",
		bool(bleed.get("BLEED_dirty_ok", false)))
	vs_b.free()

func _load_json_dict(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _check_frame_seconds() -> bool:
	var pairs := [
		[TimeSystem.IFRAMES_TICKS, 0.15], [TimeSystem.WINDUP_TICKS, 0.1333333],
		[TimeSystem.RECOVERY_TICKS, 0.10], [TimeSystem.HITSTUN_TICKS, 0.20],
		[TimeSystem.INCAP_TICKS, 3.60],
	]
	for p: Array in pairs:
		if absf(float(p[0]) / 60.0 - float(p[1])) > 1e-4:
			return false
	return true

func _count_tech_nodes() -> int:
	var f := FileAccess.open("res://data/tech/tech_tree.json", FileAccess.READ)
	if f == null:
		return -1
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return -1
	var nodes: Variant = parsed.get("nodes", parsed)
	if nodes is Dictionary:
		return nodes.size()
	if nodes is Array:
		return nodes.size()
	return -1

func _count_no_unit_keys() -> int:
	var f := FileAccess.open("res://data/schema/no_unit_keys.json", FileAccess.READ)
	if f == null:
		return 999
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed.get("keys", []) as Array).size() if typeof(parsed) == TYPE_DICTIONARY else 999

# ══════════════════════════════════════════════════════════════════
# 断言记账
# ══════════════════════════════════════════════════════════════════
func _t(name: String, cond: bool) -> void:
	_record(name, cond)
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)

## 整数等值判据：失败时打印实际值/期望值，保证"红得能归因"
func _teq(name: String, actual: int, expected: int) -> void:
	if actual != expected:
		print("      actual=" + str(actual) + " expected=" + str(expected))
	_t(name, actual == expected)

func _tfeq(name: String, actual: float, expected: float) -> void:
	if absf(actual - expected) > 1e-6:
		print("      actual=" + str(actual) + " expected=" + str(expected))
	_t(name, absf(actual - expected) <= 1e-6)

## 一组判据因前置条件不成立而整体判红（绝不静默跳过）
func _block(names: Array, reason: String) -> void:
	for n in names:
		_t("%s -- %s" % [String(n), reason], false)

func _record(name: String, ok: bool) -> void:
	var idx := name.find("-")
	var key := name.substr(0, idx) if idx > 0 else name.substr(0, min(2, name.length()))
	if not _groups.has(key):
		_groups[key] = {"p": 0, "f": 0}
	if ok:
		_groups[key]["p"] += 1
	else:
		_groups[key]["f"] += 1

func _finish() -> void:
	print("--- gate run: %d pass / %d fail ---" % [_pass, _fail])
	# 空跑 / 截断判负：GDScript 的运行时报错只截断它所在的那个函数，调用方继续跑，
	# 于是"少跑了十几条断言"这件事在 exit code 和 coverage 行上都看不出来。
	# 实测（变异体 6）就是这么静默吞掉 17 条的。这里把门檻钉死，让它必须吵出来。
	if _pass + _fail < MIN_ASSERTS:
		print("  FATAL  EMPTY-RUN / TRUNCATION: ran %d asserts, expected >= %d"
			% [_pass + _fail, MIN_ASSERTS])
		get_tree().quit(1)
	var keys := _groups.keys()
	keys.sort()
	for k in keys:
		print("      group %-6s: %d pass / %d fail" % [k, _groups[k]["p"], _groups[k]["f"]])
	# coverage_statement（架构 v1.23 定稿：脚本生成，禁止手写"全部通过"）
	# 变异确认数从 tools/mutation_report.json 读取（W3 起），缺失/损坏如实报 not run。
	var mut_line := "mutation-confirmed independent: 0 (not run)"
	var mf := FileAccess.open("res://tools/mutation_report.json", FileAccess.READ)
	if mf != null:
		var parsed: Variant = JSON.parse_string(mf.get_as_text())
		if typeof(parsed) == TYPE_ARRAY:
			var confirmed := 0
			for m: Dictionary in parsed:
				if bool(m.get("captured", false)) and bool(m.get("no_collateral", false)):
					confirmed += 1
			mut_line = "mutation-confirmed independent: %d (per tools/mutation_report.json)" % confirmed
	print("coverage: gate=%d | this report covers %d gate asserts; %s"
		% [_pass + _fail, _pass + _fail, mut_line])
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
		get_tree().quit(1)
	else:
		get_tree().quit(0)
