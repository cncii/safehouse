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

**所以现阶段你继续用色块灰盒是对的**，唯一的改动就是把字体接上。

---

## 7. 状态条：基准图已出，你的改动只有三行

手感闸门已过（老板 2026-10-22 确认），我按 `style_contract` §4 出了两件基准图：

| 文件 | 尺寸 | 说明 |
|---|---|---|
| `assets/sprites/ui/ui_bar_frame.png` | 128×16 | 底板/槽：1px 描边 + 左上高光 + 右下暗边，凹槽 112×12 @ (8,2)，4 色 |
| `assets/sprites/ui/ui_bar_fill.png` | 112×16 | 填充块，**纯白**，可见带 112×12，上下各 2px 全透明留白，1 色 |

### 7.1 你要改的两行常量（`src/ui/hud/hud_style.gd`）

```gdscript
const BAR_W := 112.0   # → 128.0   槽含边框的完整宽度
const BAR_H := 10.0    # → 16.0    10 不是 16 的倍数，像素素材进不来（A1）
```

> **为什么必须改 BAR_H**：验收器 A1 要求所有 PNG 宽高都是 16 的倍数。
> 10px 高的槽只能放纯色块（`StyleBoxFlat` 不受约束），一旦换成像素素材就必须是 16。
> 这条是硬约束，不是我在提要求——原稿 112×8 的 fill 也因此改成了 112×16。

### 7.2 填充块的落点是 (8, 0)，不是 (8, 2)

fill 自带 **2px 透明留白**（为了凑 16 倍数），所以贴图原点要对齐到 frame 的 (8, 0)，
它的可见带才会落在凹槽 (8, 2) 上。**放在 (8, 2) 会让填充带整体下移 2px 溢出凹槽。**
这条我做了逐像素断言（`build/art_proof/gen_ui_bar_preview.py` 的 `assert_geometry`）。

染色方式：fill 是**纯白**，用 `modulate` 直接染成语义色（白 × 色 = 色，色值精确）——
不需要为四条状态各出一张图。色值从 `style_contract` §3.2 取：

| 语义 | 正常 | 低值告警 |
|---|---|---|
| HP | `#ac3232` | `#d95763` |
| 体力 | `#6abe30` | `#99e550` |
| 饥饿 | `#df7126` | `#d9a066` |
| 渴 | `#306082` | `#5fcde4` |

### 7.3 九宫格参数（从 §4.2 读，别从图里猜）

```
frame:  patch_margin_left=8  top=4  right=8  bottom=4
fill :  patch_margin_left=4  top=4  right=4  bottom=4
```

### 7.4 一件需要你确认的事：S5 要重跑

`BAR_H` 10 → 16 会让 HUD 竖排四行的总高从 49px 涨到 73px。
**你之前通过的 S5（27 组合越界 0 处）是在 BAR_H=10 下跑的，结论不再适用。**
请改完常量后重跑一次，把结果给我，我记进契约的实测记录。

视觉方向确认看 `build/art_proof/ui_bar_preview.png`（含 1× 真实尺寸与 A/B 台面色对比）。

---

## 8. 需要你回一句的两件事

1. **接字体的时间点** —— 你什么时候接？我好在之后跑一次全量缺字复检（字体渲染变了，某些字的包围盒可能影响你的布局）。
2. **S5 重跑的结论** —— 你重跑 27 组合后把结果告诉我，我记进 `style_contract.md` 的实测记录，避免下一个人再问一遍。

有异议或发现我这条说明跟你的实现冲突，直接在 `docs/` 下回一份说明，或让老板转达。
