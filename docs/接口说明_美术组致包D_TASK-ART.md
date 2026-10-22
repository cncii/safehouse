# 接口说明 · 美术组 → 表现组（包 D）

**发起**：美术组 TASK-ART v1.0｜**日期**：2026-10-21｜**上游核准**：老板已批「字体按 OFL 引进」
**对应任务书**：`docs/tasks/任务书_表现组_包D.md` §3（`data/locale/strings.csv` 归你方）、§5 禁改第 2 条（零中文字面量）

> 一句话：**中文字体已经进包了，你可以直接接。但换成像素字体后，你已完成 UI 的文本宽度会变，S5 的 27 组合需要重跑一次。**

---

## 1. 直接可用的东西

| 用途 | 路径 | 说明 |
|---|---|---|
| 简体中文字体 | `res://assets/fonts/font_fusion_pixel_12px_zh_hans.ttf` | Fusion Pixel 12px，OFL，37415 码位 |
| 繁体中文字体 | `res://assets/fonts/font_fusion_pixel_12px_zh_tw.ttf` | 同上，地区字形不同 |
| 风格与 UI 件规格 | `docs/style_contract.md` §4 | 尺寸表、九宫格、五态矩阵、命名 |
| 授权凭证 | `assets/_licenses/`（4 份） | Steam 上架查证，别动 |

**导入参数已经配好了，不要改。** 四个关键值（`assets/fonts/*.ttf.import`）：

```
antialiasing=0            像素字形硬边，灰度抗锯齿会把 12px 字糊掉
hinting=0                 字形已按位图设计，自动 hinting 会二次改造
subpixel_positioning=0    禁止亚像素定位，字必须落在整像素
allow_system_fallback=false  缺字必须暴露，禁止静默回退系统字体
```

有门禁守着：`python tools/check_import_presets.py`，改坏了会打红。

---

## 2. 你需要做的最小接入（3 行）

```gdscript
# 全局字体（建议放 Theme 里统一设，别逐个 Label 配）
var font_zh := load("res://assets/fonts/font_fusion_pixel_12px_zh_hans.ttf")
theme.default_font = font_zh
theme.default_font_size = 12
```

**字号只有两档**（`style_contract` S6）：

| 用途 | 字号 |
|---|---|
| 正文 / 数值 / HUD | **12** |
| 标题 / 弹窗标题 | **16** |

⚠ **不要写 13、14、15**。字体是按 12px 等宽设计的（实测单字正好 12.0×12.0），非整倍数会破坏栅格对齐。

---

## 3. 一个必须立刻处理的风险（**请优先看这条**）

你方 `b31a1b0` 刚交付的键位重绑面板等 UI，**目前跑在 Godot 默认字体上**。换成像素字体后：

- 字形完全不同（像素点阵 vs 矢量轮廓）
- 单字宽度会变（像素字体严格等宽 12px，默认字体中文宽度随字号而定）
- 于是**已经通过的 S5（三分辨率 × 三模式 × DPI = 27 组合，越界 0 处）结论可能失效**

**建议**：接入字体后**重跑一次** S5 的 27 组合截图。这不是重复劳动——换字体改变的是文本包围盒，
而 S5 判的就是包围盒越界。你方上一次 S5 就抓到过 30 处越界，说明这条判据是真会红的。

---

## 4. 我这边能替你查的：缺字

S6 是"缺字 = 界面出现豆腐块"的一票否决项。运行时我已把 `allow_system_fallback` 关掉，
所以缺字**不会被系统字体兜住**——它会老老实实显示方框。

**流程约定**：
1. 你方 `data/locale/strings.csv` 每次**定稿**时，知会美术组一声；
2. 我跑 `python tools/check_font_coverage.py --csv data/locale/strings.csv --font ...`；
3. 有缺字我立刻回你，你改文案或我换字。

**你也可以自己跑**（不需要等我的档期）：

```bash
python tools/check_font_coverage.py \
  --csv data/locale/strings.csv \
  --font assets/fonts/font_fusion_pixel_12px_zh_hans.ttf \
  --font assets/fonts/font_fusion_pixel_12px_zh_tw.ttf
```

退出码 0 = 全列零缺字；非 0 = 直接列出缺哪几个字。
它**按列分别检查**：`zh_CN` 列的字在 hans 字体里、`zh_TW` 列的字在 zh_tw 字体里——所以别只测简体。

> 当前状态（2026-10-21 这份快照）：47 行 / 143 唯一汉字，**零缺字**。

---

## 5. 命名即契约（改了要通知）

`style_contract.md` §4 定的命名与尺寸，**我按它出素材、你按它接**。任何改名、改尺寸、
改图集切分，必须双方同步一次——否则你接的路径会静默失效（Godot 资源路径不匹配是加载失败，不是报错弹窗）。

已知的命名坑（`check_assets.py` 会拦，提前说）：

| 你以为的 | 实际必须的 | 原因 |
|---|---|---|
| `alert-icon.png` | `ui_alert_icon.png` | 只允许小写+下划线，且必须域前缀 |
| `icon@v1.png` | `ui_icon_v1.png` | `@` 不在字符类里 |
| `atlas_ui_panels.png` | `ui_atlas_panels.png` | 域前缀要在最前 |
| `panel.9.png` | —— 不支持 | 文件名只允许一个点 |

---

## 6. 目前**还不能**接的东西（免你空等）

| 素材 | 状态 | 卡在哪 |
|---|---|---|
| **状态条 2 件**（`ui_bar_frame` / `ui_bar_fill`） | ✅ **基准图已出**，见 §7 | 老板确认视觉方向后放量，接口现在就能对 |
| UI 底板 / 按钮 / 插槽 实物 | 未交付 | 同一批，按 §7 确认后依次出 |
| tileset / 角色 / 丧尸 | 未交付 | 同上 |
| 图集（`.png` atlas） | 未交付 | 素材到位后再切；规格已写在 `style_contract` §4.6 |

**所以现阶段你继续用色块灰盒是对的**：唯一确定要动的就是把字体接上；
状态条 2 件已可接（见 §7），属可选项，不急。

---

## 7. 状态条：基准图已出，接法比你想的少一步

手感闸门已过（老板 2026-10-22 确认），两件基准图按 `style_contract` §4 出完了：

| 文件 | 文件尺寸 | 可见带 | 色数 |
|---|---|---|---|
| `assets/sprites/ui/ui_bar_frame.png` | **112×16** | 112×14 @ (0,1) | 3：`#222034` 描边 / `#323c39` 槽 / `#847e87` 高光 |
| `assets/sprites/ui/ui_bar_fill.png` | **112×16** | **108×10 @ (2,3)** | 1：`#ffffff` 纯白，由你染色 |

宽度 112 是照你的 `HudStyle.BAR_W` 定的（美术不自选，否则会像初版那样出成 128 多溢 16px）；
高度 16 是 A1（16 网格）的硬约束，10 过不了。

### 7.1 关键：两张图**同原点**叠画，不需要记任何偏移

上一版我写过"fill 落在 (8,0) 而不是 (8,2)"——那是个坏设计，靠人记偏移量迟早写错。
现在所有内部偏移都编码成 PNG 里的透明边距，两张图都放在 `(0,0)` 即可：

```
frame 可见带  x 0..111, y 1..14      ← 112×14
凹槽          x 2..109, y 3..12      ← 108×10，四边统一 2px 边框
fill  可见带  x 2..109, y 3..12      ← 与凹槽逐像素重合
```

已做**跨文件**断言：`fill.get_used_rect() == 凹槽`，且凹槽那 1080 个像素全是槽色
（边框没有压进槽里）。只比"两张图各自尺寸对"是不够的——位置差 2px 照样错位。

### 7.2 别用 ProgressBar 的 fill StyleBox —— 那是**拉伸**，不是裁切

这是本轮最要紧的一条。`ProgressBar` 把 `fill` 当 StyleBox 画在"当前值对应的宽度"上，
用 `StyleBoxTexture` 时**整张图会被拉伸**：112px 拉到 37% = 41.44px，落在半像素上，
像素被重采样、边缘糊，左右 2px 透明留白的宽度也跟着漂。

像素条的正确做法是**裁切**：图 1:1 原样画，用一个 `clip_contents = true` 的 Control 把右边盖住。

我写了一份可直接移植的参考实现，并且带判据（实测全过）：

| 文件 | 说明 |
|---|---|
| `build/art_proof/pixel_bar_ref.gd` | 参考实现，约 110 行，无外部依赖，自带 `custom_minimum_size = (112,16)` |
| `build/art_proof/check_pixel_bar.gd` | 17 条判据：几何自洽 / 裁切宽度边界值 / 单调性 / 1:1 未缩放 |

核心就这几行：

```gdscript
var clip := Control.new()
clip.clip_contents = true                      # 裁切，不是缩放
clip.size = Vector2(2 + visible_px, 16)        # 2 = 左边框宽
var fill := TextureRect.new()
fill.texture = load("res://assets/sprites/ui/ui_bar_fill.png")
fill.stretch_mode = TextureRect.STRETCH_KEEP   # 原尺寸绘制，禁缩放
clip.add_child(fill)
```

可见像素数算法（`VIS_W = 108`）：

| 值 | 可见像素 | 裁切宽 |
|---|---|---|
| 0% | 0 | 2 |
| 0.4% | **1**（非 0 至少给 1px，否则玩家以为已空） | 3 |
| 50% | 54 | 56 |
| 100% | 108 | 110 ← 右边框 2px 永不被覆盖 |

染色方式：fill 是**纯白**，用 `modulate` 直接乘语义色（白 × 色 = 色，色值精确）——
不需要为四条状态各出一张图。色值从 `style_contract` §3.2 取：

| 语义 | 正常 | 低值告警 |
|---|---|---|
| HP | `#ac3232` | `#d95763` |
| 体力 | `#6abe30` | `#99e550` |
| 饥饿 | `#df7126` | `#d9a066` |
| 渴 | `#306082` | `#5fcde4` |

### 7.3 你要改的地方（比上一版说的更小）

| 文件 | 改动 |
|---|---|
| `src/ui/hud/vital_bar.gd` | `_bar: ProgressBar` → 换成 `PixelBar`（移植参考实现）；`set_value()` 里不再重建 `StyleBoxFlat`，入参**照旧直接传** `bar.set_value(v)`（同为 0–100 标度，内部只除一次，满足 P20"同源同一入参"） |
| 同上 | 染色从 `sb.bg_color = ...` 改为 `bar.set_tint(c)`（内部走 `modulate`，色值精确） |
| `src/ui/hud/hud_style.gd` | **不用改**。参考实现自带 `custom_minimum_size = (112,16)`，`BAR_H` 保持 10 |
| `_name_label` / `_value_label` | **不用改**。仍是 `BAR_H + 4` = 14 |

> **为什么不让你把 `BAR_H` 改成 16**：`BAR_H + 4` 还被 `hud_clock.gd` 的标签高度引用，
> 改 `BAR_H` 会连带把时钟行高一起撑高，凭空扩大 S5 的影响面。素材高独立成常量更安全。

### 7.4 九宫格：本件**不需要**

两件素材的可见尺寸与控件尺寸一致，**永不拉伸**，所以填任何 `patch_margin` 都是
"只在你哪天把它拉宽时才会生效"的伪参数。真要拉宽再用（`style_contract` §4.2 有具名值）。

### 7.5 ⚠ S5 必须重跑（这条别漏）

素材 16px 高，控件最小高度就从 10 变成 16，HBox 行高跟着涨：

| 项 | 现在 | 接素材后 |
|---|---|---|
| 单行行高 | 14（Label 的 `BAR_H+4` 撑起） | **16**（素材高） |
| 四条状态块总高 | 4×14 + 3×3 = **65** | 4×16 + 3×3 = **73** |
| 左上 HUD 面板 | — | **+8px** |

`HudRoot` 已把 clock / vitals / loop_panel 放进同一个 VBox（注释里记着"曾绝对定位 y=70
导致与 vitals 重叠"的教训），所以高度变化自适应、**不会重叠**；
但**你之前通过的 S5（27 组合越界 0 处）是行高 14 下跑的，结论不再适用，必须重跑**，
结果给我，我记进 `style_contract` §8.2。

视觉方向确认看 `build/art_proof/ui_bar_preview.png`（含 1× 真实尺寸，台面亮/暗 A/B 两版）。

---

## 8. 需要你回一句的三件事

1. **接字体的时间点** —— 你什么时候接？我好在之后跑一次全量缺字复检（字体渲染变了，某些字的包围盒可能影响你的布局）。
2. **S5 重跑的结论** —— 你重跑 27 组合后把结果告诉我，我记进 `style_contract.md` §8.2，避免下一个人再问一遍。
3. **参考实现你收不收** —— `build/art_proof/pixel_bar_ref.gd` 是"裁切而非拉伸"的可运行样板。
   你愿意移植就移植（记得加 `class_name PixelBar`）；你有更好的写法也直接说，
   但**别用 `ProgressBar` + `StyleBoxTexture` 的 fill**——那是拉伸，像素会糊（见 §7.2）。

有异议或发现我这条说明跟你的实现冲突，直接在 `docs/` 下回一份说明，或让老板转达。
