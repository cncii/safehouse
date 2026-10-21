# 素材导入预设规格 · import_presets

**归属**：美术组 TASK-ART v1.0｜**上游**：架构方案 §7.3「统一 import preset」｜**状态**：已核准（2026-10-21）
**门禁**：`python tools/check_import_presets.py`（退出码 0 = 全部符合）

---

## 0. 这个目录为什么不是一堆 `.preset` 文件

Godot 4 的**项目级**导入默认值只有两个存放位置：

| 位置 | 能否用 | 原因 |
|---|---|---|
| `project.godot` 的 `[importer_defaults]` 段 | ❌ **不能用** | 任务书 §3 明令禁改 `project.godot`（归主理人） |
| 每个资源自己的 `.import` 文件 `[params]` 段 | ✅ 用这个 | 逐资源持久化，编辑器与命令行一致 |

所以这里交付的不是"预设文件"，而是**一份可校验的参数规格 + 一个门禁脚本**：
- 规格 = 本文件 §2 / §3 两张表（权威出处）
- 门禁 = `tools/check_import_presets.py`，扫描 `assets/**` 下所有 `.import` 与表比对

> 这样做的额外好处：规格是**判据**，不是"建议"。新人照着编辑器默认值导入 → 门禁直接打红，
> 不依赖谁记得住。

---

## 1. 为什么值得单独做这一件事

Godot 对**像素字体**的默认导入参数，有三个不报错但会毁掉画面的值：

| 默认值 | 后果 | 谁能发现 |
|---|---|---|
| `antialiasing=1`（灰度抗锯齿） | 12px 像素字被灰化，边缘出半透明像素 | 只能肉眼，且要放大看 |
| `subpixel_positioning=1`（亚像素定位） | 字落在半像素上，同一行字粗细不一 | 只能肉眼 |
| `allow_system_fallback=true` | 缺字**静默**回退到系统字体 | 开发机有字库看不出来，玩家机器上变豆腐块 |

第三条是真正危险的：它会让 `check_font_coverage.py` 的门禁形同虚设——门禁查字体文件缺字，
但运行时被系统字体兜住了，于是**测试永远绿、上架才炸**。

---

## 2. 纹理（`.png`）规格

适用：`assets/sprites/**` 全部像素美术与 UI 件。

| 参数 | 值 | 为什么 |
|---|---|---|
| `compress/mode` | `0`（Lossless） | 有损压缩会改变像素色值 → 直接从 32 色膨胀，违反契约 S2 |
| `compress/high_quality` | `false` | 无损模式下无意义，保持一致 |
| `compress/normal_map` | `0` | 2D 素材没有法线图 |
| `compress/channel_pack` | `0` | 通道打包会改通道语义，UI 件依赖 RGBA 原样 |
| `mipmaps/generate` | `false` | 2D 像素图开 mipmap → 远处糊成一团 |
| `process/fix_alpha_border` | `false` | **会改边缘像素颜色**。像素美术要求像素数据零改动；等比放大走 NEAREST，不存在黑边问题 |
| `process/premult_alpha` | `false` | 预乘 alpha 会让半透区色值漂移 |
| `process/size_limit` | `0` | 不许自动缩图（缩了 16px 栅格就废了） |
| `detect_3d/compress_to` | `0` | **默认 1**：素材一旦被 3D 节点引用就自动转 VRAM 压缩，画质悄悄掉了还没人知道 |

> `process/fix_alpha_border=false` 的取舍说明：如果你将来改用**线性过滤**做缩放，
> 透明边缘可能出现黑边，那时需要开回 `true`。本项目锁 640×360 整数缩放 + NEAREST，
> 所以按"像素零改动"优先。

---

## 3. 字体（`.ttf` / `.otf`）规格

适用：`assets/fonts/**`，当前为 Fusion Pixel Font 12px（见 `docs/asset_sourcing.md` §3）。

| 参数 | 值 | 为什么 |
|---|---|---|
| `antialiasing` | `0`（None） | 像素字形必须硬边。这一条是像素字体与普通字体导入设置的核心差异 |
| `hinting` | `0`（None） | 字形本身已按位图设计，自动 hinting 会二次改造笔画 |
| `subpixel_positioning` | `0`（Disabled） | 字必须落在整像素；亚像素定位会造成同行字粗细不一 |
| `allow_system_fallback` | `false` | 缺字必须暴露。配合 `tools/check_font_coverage.py` 才能形成闭环 |
| `generate_mipmaps` | `false` | 同上，2D 不需要 |
| `multichannel_signed_distance_field` | `false` | MSDF 是为任意缩放设计的，会把像素边缘重新插值 → 必糊 |
| `oversampling` | `0.0` | 跟随项目缩放策略 |

**已验证**（本机 Godot 4.3，`build/art_proof/check_font.gd`）：按上表导入后，
12px 单字度量 = **12.0 × 12.0**，9 字整行 = **108.0**，完美栅格对齐。

---

## 4. 新增素材怎么用

**路线 A（推荐，编辑器内）**：素材放进 `assets/` → Godot 自动生成 `.import` → 在 FileSystem 面板选中资源，
Import 标签页按 §2 / §3 表格逐项设置 → Reimport。

**路线 B（批量/脚本）**：直接写 `.import` 的 `[params]` 段，然后
```
Godot_v4.3-stable_win64_console.exe --headless --path <工程根> --import
```
> ⚠ 路线 B 不要碰 `[remap]` / `[deps]` 段（`uid` / `path` / `dest_files` 由引擎维护），只改 `[params]`。

**两种情况都必须做的收尾**：
```
python tools/check_import_presets.py    # 导入参数门禁
python tools/check_assets.py            # 资产门禁（A1–A4）
```

---

## 5. 已知边界

1. **没有项目级默认值**。`project.godot` 禁改，所以新资源默认走的仍是 Godot 出厂参数——
   也就是说**每加一个素材都要过一遍 §2/§3**。门禁会替你兜底，但它只能事后报警，不能事前阻止。
2. 字体缺字的**运行时**行为已被 `allow_system_fallback=false` 锁死：缺字会渲染成 `.notdef` 方框，
   而不是悄悄换字体。所以 `check_font_coverage.py` 的结论是可信的。
3. 本规格不覆盖音频/场景/着色器资源（当前项目无音频素材入库）。
