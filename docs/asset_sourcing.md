# 素材采购与授权记录 · asset_sourcing.md

**版本**：v1.0（2026-10-21 结案）｜**归属**：美术组 TASK-ART v1.0｜**状态**：✅ 老板已核准（U1–U4 全部结案）
**上游**：`docs/style_contract.md`（准入门槛）、任务书 §7「每批交付附来源与授权清单」

> ✅ **白名单核准**：本文件超出任务书 §3 白名单（只列了 `assets/**` 与 `docs/style_contract.md`）。
> 老板 2026-10-21 明确裁决「两个文件都留」，本文件与 `build/art_proof/` 一并通过保留。

---

## 0. 三条铁律

1. **先过 `style_contract.md` §6 准入清单，再下单。** 不合规的素材买了也不用（架构 R6 既定省钱条款）。
2. **授权记录当场写，不做事后补。** Steam 上架会查来源，事后补的记录等于没有记录——你不会记得三个月前那个包是在哪个站下的。
3. **来源不明的素材一律不用。** 包括"朋友给的""群里存的""忘了哪来的"。

---

## 1. 授权类型白名单 / 黑名单

| 授权 | 能否进包 | 说明 |
|---|---|---|
| **CC0 1.0**（公有领域） | ✅ 最安全 | 无需署名（建议仍署名，成本为零） |
| **CC-BY 4.0** | ✅ | 必须在游戏 credits 里署名作者与来源 |
| **CC-BY-SA 4.0** | ⚠ **回避** | 传染性条款，与商业分发叠加后解释空间大，不值得为它请律师 |
| **CC-BY-NC / NC-SA** | ❌ **一票否决** | 禁止商用，直接用不了 |
| **itch.io 商用附加许可** | ✅ | 免费素材多数默认只允许非商用，需按作者标价加购。加购凭证存本文件 |
| **SIL OFL 1.1** | ✅（字体） | 可嵌入分发；**禁止单独出售字体文件本身**；可修改但须同样以 OFL 公开 |
| **MIT** | ✅（代码/工具） | 保留许可证文本即可 |
| **"Free for personal use"** | ❌ | 与 NC 同效 |
| **无 license / 来源不明** | ❌ | 同 S6 精神：缺授权 = 不能用 |

---

## 2. 采购清单（按任务书 §5 批次）

### 2.1 第一批（现在）— **零采购**

第一批三件全部由美术组自产，无需花钱：

| 交付 | 位置 | 状态 |
|---|---|---|
| 风格契约 | `docs/style_contract.md` | ✅ 已交付 |
| 色板统一 shader | `assets/shaders/palette_map.gdshader` | ✅ 已交付 |
| DB32 色板 LUT | `assets/sprites/ui/ui_palette_db32.png`（32×16，32 色） | ✅ 已交付，门禁通过 |
| 采购与授权记录 | 本文件 | ✅ 已交付（已核准保留） |
| 中文字体 | 见 §3，`assets/fonts/` | ✅ 已交付（Fusion Pixel 12px 简繁各一份，零缺字实测通过） |

### 2.2 MVP 批 — **触发条件：灰盒过了手感闸门**（✅ 已过，2026-10-22 老板确认）

> ⚠ 任务书 §5 警告：R1 头号死因是内容量爆炸。**MVP 阶段只对应 1 个安全屋 + 1 个地点 + 1 种丧尸**，多做就是烧钱买返工。

| # | 需求 | 规格（来自 style_contract） | 检索关键词 | 优先 |
|---|---|---|---|---|
| 1 | 主角行走帧 | 16×24 或 16×32，4 方向 × 4–6 帧，左上光源 | `16x16 top-down character walk cycle` | P0 |
| 2 | 主角动作帧 | 挥砍 3–4 帧 + 翻滚 3–4 帧，与行走帧同源 | 同上（同包优先） | P0 |
| 3 | 丧尸 ×1 种 | 16×24，行走 4 帧 + 攻击 2 帧 | `16x16 zombie sprite` | P0 |
| 4 | tileset · 安全屋 | 16×16 图块，室内地板/墙/家具/工作台 | `16x16 interior shelter tileset` | P0 |
| 5 | tileset · 超市 | 16×16，货架/商品/收银台/破损版 | `16x16 supermarket tileset` | P0 |
| 6 | UI 件（四条状态条 + 底板） | 按 `style_contract` §4 全表 | — | **自产，不买**。状态条 2 件已出基准图 |
| 7 | 事件立绘 ×3–5 | 192×256，半身裁切，背景透明 | 可玩批再做 | P1 |

**为什么 UI 件自产不买**：UI 件必须严格贴合 640×360 的栅格与九宫格边界（§4.1 / §4.2）。市面上的 UI 包尺寸是随机的，买回来要么重切要么重画，**成本高于直接做**。而且 UI 只用 6 色（§3.1），画起来比买更快。

### 2.3 关于「为什么不给具体商品链接」

**我不给具体商品链接，这是有意为之。**

- 素材包上架下架频繁，链接几周就失效；
- 更关键的是：**我无法替你核实某个具体商品当下的授权条款是否允许商用**——那需要打开页面当场看 license 区块。给一个我核实不了的链接，等于给你一个假的安全感。

我给的是**检索式 + 筛选条件**。你在站点上当场核对 license 区块后下单，比照着我给的链接下单可靠得多。

**itch.io 实操筛选**：
1. 搜索页用上表关键词；
2. 左侧 **License** 过滤区选 `CC0` / `Commercial use allowed`；
3. **免费素材默认是「非商用」的占多数**——必须看清作者是否提供付费商用许可，加购后截图存本文件；
4. 优先找**同一作者的系列包**（同源画风，天然少一半拼贴感）。

**备选站点**：`opengameart.org`（授权标注明确，质量参差）｜`kenney.nl`（CC0，质量高，但画风偏卡通，与末日调性**可能不符**，先看再定）。

---

## 3. 中文字体（**S6 一票否决项 · 已结案**）

### 3.1 结论：Fusion Pixel Font（缝合像素字体）12px，OFL，已入包

| 项 | 内容 |
|---|---|
| 落地文件 | `assets/fonts/font_fusion_pixel_12px_zh_hans.ttf`（7.1 MB）<br>`assets/fonts/font_fusion_pixel_12px_zh_tw.ttf`（7.2 MB） |
| 上游版本 | `2026.10.16`（TakWolf/fusion-pixel-font 最新发布） |
| 授权 | **SIL OFL 1.1** — 可商用、可嵌入分发、可与游戏捆绑销售、可修改（衍生作品须同以 OFL 发布） |
| 授权文件 | `assets/_licenses/` 下 **4 份**：本体 + 上游 Ark Pixel + Cubic 11 + Galmuri |
| 字符覆盖 | **37415 个码位**；自带 ASCII 95/95、数字 0-9、全角标点、常用符号（× ÷ ℃ · — …） |
| 实机实测 | 12px 单字 **12.0 × 12.0**，9 字整行 **108.0** — 栅格完美对齐，无亚像素偏移 |

> ⚠ 它是**缝合体**：把 Ark Pixel / Cubic 11 / Galmuri 三个像素字体缝在一起补字。
> 所以授权链是 **4 份、不是 1 份**，少放一份即授权不全。四份都在 `assets/_licenses/`。

### 3.2 为什么淘汰了原先推荐的 Ark Pixel（数据说话）

| 字体 | 当前 `strings.csv`（143 唯一 CJK） | GB2312 一级字（3716） |
|---|---|---|
| Ark Pixel | 缺 5：击 据 药 避 脏 / 擊 據 避 髒 | **缺 147（96.0%）** |
| **Fusion Pixel** | **0 缺** | **0 缺（100%）** |

Ark 的缺字清单里有：**热 / 燃 / 餐 / 窗 / 聚 / 紧 / 酸 / 药 / 避 / 警**——末日生存题材的日常用字。
"手补 147 个像素字形"不是工时问题，是**手补的字不可能与原字体画风一致**的问题，所以不做。

> 方法论教训（可复用）：
> 1. **字体选型不能凭"官方说支持中文"判断，必须拿真实语料压一遍。**
> 2. **只测 strings.csv 不够**——它只有 143 字，会严重低估风险；GB2312 一级字表才反映"未来加文案"。
> 3. 两轮测试结论一致（都是 Fusion 100% / Ark 缺字），所以这不是抽样偶然。

### 3.3 字号规定

| 用途 | 字号 | 理由 |
|---|---|---|
| 正文 / 数值 / HUD | **12px** | 640×360 下中文可读下限；10px 笔画会糊 |
| 标题 / 弹窗标题 | **16px** | 与 16px 图块栅格同源，位置对齐 |
| 极窄辅助（物品数量角标） | 10px（**仅在必要时**） | 需实测，不优先 |

### 3.4 缺字的处理流程（`strings.csv` 每次定稿后跑）

```bash
python tools/check_font_coverage.py \
  --csv data/locale/strings.csv \
  --font assets/fonts/font_fusion_pixel_12px_zh_hans.ttf \
  --font assets/fonts/font_fusion_pixel_12px_zh_tw.ttf
```

退出码非 0 = 有缺字，并直接列出缺哪几个字。

- 纯标准库实现（不依赖 fontTools），解析 sfnt 的 `cmap` 表（format 4 / 12）
- 语料**按列**分别统计：`zh_CN` 列的字要在 hans 字体里存在，`zh_TW` 列的字要在 zh_tw 字体里存在
- `--gb2312-l1` 改用 3716 个常用字评估字体自身广度（选型阶段用）
- Godot 侧另有实机验证 `build/art_proof/check_font.gd`：证明 TextServer 真能出字形，
  而不只是"cmap 里有映射"。两者缺一个都不算过
- 运行时已用 `allow_system_fallback=false` 锁死：缺字会显示 `.notdef` 方框而**不会**静默回退到系统字体，
  所以本门禁的结论是可信的（这条很关键，否则开发机有字库会把问题焊死）

---

## 4. 授权登记表

### 4.1 已登记（第一批）

| 资产 | 来源 | 授权 | 核实状态 | 日期 |
|---|---|---|---|---|
| DB32 色板（32 色值） | Lospec / Aseprite 内置预设；与 Hugging Face `palettes.json` 交叉核对，色值完全一致 | 社区长期免费使用 | ✅ 老板核准接受惯例（U2 结案） | 2026-10-19 |
| `ui_palette_db32.png` | 由上述色值**程序化生成**（32×16，非第三方素材） | 本项目自产 | ✅ 无外部依赖 | 2026-10-19 |
| `ui_bar_frame.png` / `ui_bar_fill.png` | **本项目程序化生成**（`build/art_proof/gen_ui_bar.py`，可复跑） | 本项目自产 | ✅ 无第三方素材，纹理由脚本定义 | 2026-10-22 |
| **Fusion Pixel Font 12px** | TakWolf/fusion-pixel-font，release `2026.10.16` | **SIL OFL 1.1**（`assets/_licenses/fusion_pixel_font_OFL_1.1.txt`） | ✅ 已入包，md5 与上游逐字节一致，零缺字 | 2026-10-21 |
| ├ 上游 · Ark Pixel | TakWolf/ark-pixel-font | SIL OFL 1.1（`fusion_pixel_upstream_ark_pixel_OFL.txt`） | ✅ 已归档 | 2026-10-21 |
| ├ 上游 · Cubic 11 | ACh-K/Cubic-11 | SIL OFL 1.1（`fusion_pixel_upstream_cubic_11_OFL.txt`） | ✅ 已归档 | 2026-10-21 |
| └ 上游 · Galmuri | Lee Minseo / quiple | SIL OFL 1.1（`fusion_pixel_upstream_galmuri_OFL.txt`） | ✅ 已归档 | 2026-10-21 |
| 方舟像素字体 Ark Pixel（单独使用） | TakWolf | SIL OFL 1.1 | ❌ **已评估、未采用**：GB2312 一级字缺 147（见 §3.2） | 2026-10-21 |

### 4.2 登记模板（后续每批照抄）

```
资产名：
站点/链接：
作者：
许可证类型：（必须是 §1 白名单内的一种）
是否加购商用附加许可：是 / 否 / 不适用
加购凭证：（截图存 assets/_licenses/ 同名文件）
下载日期：
核对人：
```

> ✅ 已建 `assets/_licenses/`（2026-10-21 核准），存放许可证原文与加购凭证截图。
> 当前内含 4 份 OFL 文本；后续每笔采购的加购凭证照 `资产名_凭证.png` 归档于此。

---

## 5. 结案记录（2026-10-21）

**老板裁决原话**：「U2 接受惯例、U3 保素材、U4 都建、两个文件都留、字体按 OFL 引进」

| # | 事项 | 结论 | 处置 |
|---|---|---|---|
| **U1** | 中文字体 | ✅ **Fusion Pixel 按 OFL 引进** | 4 份授权归档 + 两个 ttf 入包 + 零缺字双重验证 |
| **U2** | DB32 授权 | ✅ **接受社区惯例** | 沿用。补充依据：LUT 是程序生成的，不含第三方素材 |
| **U3** | UI 底板形态 | ✅ **保留像素素材** | `StyleBoxFlat` 仅调试面板 |
| **U4** | 目录 | ✅ **都建** | `assets/_licenses/` + `assets/import_presets/` 已建，后者带参数规格与门禁 |
| — | `asset_sourcing.md` | ✅ **保留** | 白名单核准通过 |
| — | `build/art_proof/` | ✅ **入库** | 验收证据入库 |

## 5.1 本轮新增的两个工具（白名单外，已随核准保留）

| 工具 | 用途 |
|---|---|
| `tools/check_font_coverage.py` | S6 缺字门禁。纯标准库解析 cmap，按列统计缺字 |
| `tools/check_import_presets.py` | 导入参数门禁（架构 §7.3）。校验所有 `.import` 的 `[params]` 与规格一致 |

> 两者都用退出码表达结论，可直接接 CI。与 `check_assets.py` 并列，构成美术侧三道门禁。

---

## 6. 第一批交付清单（2026-10-21 全部闭环）

| 文件 | 说明 | 门禁 |
|---|---|---|
| `docs/style_contract.md` | 准入门槛：六条风格条款 + UI 件规格 + 四本实测记录 | 人工 |
| `assets/shaders/palette_map.gdshader` | 色板统一 shader（优先级最高交付） | ✅ Godot 4.3 实机解析通过 + A/B 对比图 |
| `assets/sprites/ui/ui_palette_db32.png` | DB32 LUT，32×16，32 色 | ✅ `check_assets.py` |
| `assets/fonts/font_fusion_pixel_12px_zh_hans.ttf` | 简体中文像素字体 12px | ✅ 零缺字 + Godot 实机渲染 |
| `assets/fonts/font_fusion_pixel_12px_zh_tw.ttf` | 繁体中文像素字体 12px | ✅ 零缺字 + Godot 实机渲染 |
| `assets/_licenses/`（4 份） | OFL 授权原文，Steam 上架查证用 | 人工 |
| `assets/import_presets/README.md` | 导入参数规格（架构 §7.3） | ✅ `check_import_presets.py` |
| `tools/check_font_coverage.py` | S6 缺字门禁 | 自验 |
| `tools/check_import_presets.py` | 导入参数门禁 | 自验 |
| `build/art_proof/` | 验收对比图 + 3 个可复跑验证脚本 | 人工看 |
| `docs/asset_sourcing.md` | 本文件 | ✅ 老板核准保留 |

**验收方式（任务书 §4）**：两张来源不同的精灵图，开/关 shader（`mix_strength` 0 ↔ 1）各截一张并排。
✅ **已自验完成**——用程序构造的两张色相相反的测试精灵（暖色 / 冷色）做对比，
见 `build/art_proof/palette_map_ab_compare.png`：映射后越界色 0、两张描边统一为 `#222034`、
羽化脏边被清掉 178 px。**仍需老板肉眼确认一次**（"看得出是两个来源 = 未过"这条只有人能判）。
