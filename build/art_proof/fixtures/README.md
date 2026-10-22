# 负样本夹具（`check_palette_conformance.py` 的变异测试证据）

**这里是故意做错的图，不是资产，不要挪进 `assets/`。**

用途：证明 P1–P4 四条判据**真的能抓到东西**。判据「全绿」本身不构成证据——
本项目已踩过「空转假绿」「恒真式」两次，所以每道门禁都要能演示它报红。

| 文件 | 故意制造的缺陷 | 应报的判据 |
|---|---|---|
| `ui_fixture_good.png` | （无，合规对照） | 应**放行** |
| `ui_fixture_badpal.png` | `#101010` / `#209040` 越界；`#df7127` 只差 1 | P1 色板归属 |
| `ui_fixture_badalpha.png` | 16 px alpha=128（羽化边） | P2 alpha 二值 |
| `ui_fixture_empty.png` | 整张全透明 | P3 非空素材 |
| `ui_palette_db32.png` | 真 LUT 的副本，改了 1 个像素为 `#111111` | P4 LUT 自洽（+P1） |

跑法（预期 exit=1，列出 5 项违例）：

```powershell
python tools/check_palette_conformance.py --dir build/art_proof/fixtures
```

其中 `#df7127` 那条是关键：它和合法色 `#df7126` 只差 1。如果判据用的是「近似色容差」，
这条会漏 —— 而漏了它，「统一色板」就等于没有判据。
