// palette_map.gdshader — 目标色板统一映射
// 归属：美术组 TASK-ART v1.0 第一批（优先级最高交付）
// 上游：架构方案 R6（素材拼贴感缓解）· docs/style_contract.md §5
//
// 作用：把不同来源精灵的色板映射到统一 target palette。
//       本项目美术走素材包采购，来源必杂；这是低成本统一风格最有效的手段。
//
// ─── 使用方式 ───────────────────────────────────────────────────────────
//   palette_tex   = res://assets/sprites/ui/ui_palette_db32.png （32×16，每列一个色）
//   mix_strength  = 0.0 → 原图；1.0 → 完全映射。验收对比图就是拉这个值。
//
// ─── 颜色空间（必须一致，否则映射错色）─────────────────────────────────
//   LUT 图与主纹理必须保持相同的导入设置（都用默认 sRGB）。
//   Godot 4 采样 sRGB 纹理时自动转 linear，两边同时转，距离比较才成立。
//   若 LUT 改成 linear 导入而主纹理保持 sRGB → 采样到的色值错一倍，
//   映射结果整体错色。排查方法：挂上一个纯色精灵，看输出是否等于 DB32 中最接近的色。
//
// ─── 验收方式（任务书 §4）────────────────────────────────────────────────
//   两张来源不同的精灵并排，mix_strength 拉 0 与 1 各截一张：
//   看得出是两个来源 = 未过；看不出 = 过关。
//
// ─── 性能注意（不谎报）──────────────────────────────────────────────────
//   每个像素 32 次 LUT 采样。全屏 640×360 = 约 7.4M 次采样/帧。
//   建议只给「采购来源」的精灵挂这个材质，全屏 TileMap 挂之前先实测帧率。
//   若 1% low 掉到 50fps 以下，优先把 TileMap 烘成已映射的贴图而不是全局挂。

shader_type canvas_item;
render_mode blend_mix, unshaded;

// Target palette LUT。filter_nearest 是硬要求：线性插值会造出 palette 之外的中间色，
// 反而破坏「统一色板」这个目的。
uniform sampler2D palette_tex : filter_nearest, repeat_disable;

// 0 = 完全不映射（原图），1 = 完全映射。做 A/B 对比图时用它。
uniform float mix_strength : hint_range(0.0, 1.0) = 1.0;

// 暗部统一色。亮度低于 outline_luma 的像素（实际就是 1px 深色描边）会被强制
// 映射到 outline_color —— 契约 style_contract S4 规定描边色必须是 #222034。
//
// ⚠ 为什么是「统一」而不是「保护原色」：
//   初版设计成「保护描边、不参与映射」，实测断言直接证伪 —— 最近邻映射并不会抹掉描边，
//   它只会把描边换成各自最接近的暗色。结果两张来源不同的素材各自保留深棕描边与冷蓝描边，
//   并排时描边色不一致，等于没统一（实测越界色正是 (48,24,12) 与 (18,22,36)）。
//
// ⚠ 这里比的是 LINEAR 空间的亮度，不是取色器里的 sRGB 值。
//   Godot 4 把 PNG 当 sRGB 导入，texture() 采样返回 linear，两者差约 8 倍。实测锚点：
//     描边 #222034 ≈ 0.017 ／ 深棕描边 (48,24,12) ≈ 0.015 ／ 冷蓝描边 (18,22,36) ≈ 0.008
//     底板 #323c39 ≈ 0.041 ／ 暖色衣服 (168,84,40) ≈ 0.172
//   取 0.02 能抓住全部描边、放过正常填充。若按 sRGB 直觉填 0.12，会连大片暗部一起吞成描边色。
uniform vec3 outline_color : source_color = vec3(0.133, 0.125, 0.204);
uniform float outline_luma : hint_range(0.0, 0.2) = 0.02;

// 半透明羽化边缘二值化阈值。素材自带的抗锯齿脏边在这一步被清掉，
// 同时也是 style_contract §4.3「Alpha 只允许 0 或 255」的机械化执行。
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;

const int PALETTE_MAX = 32;

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// LUT 布局：32×16 横向排色，纵向 16 行内容相同。
// u 取列中心避免采样到相邻列，v 取 0.5（第 8 行）。
vec2 palette_uv(int i) {
	return vec2((float(i) + 0.5) / float(PALETTE_MAX), 0.5);
}

void fragment() {
	vec4 src = texture(TEXTURE, UV);

	// ① 羽化边缘二值化：先杀半透明，避免脏边参与后面的取色
	if (src.a < alpha_cut) {
		discard;
	}

	float l = luma(src.rgb);
	vec3 mapped = src.rgb;

	// ② 暗部统一：描边类像素直接压成契约规定的描边色 #222034
	if (l < outline_luma) {
		mapped = outline_color;
	} else {
		float best = 1e9;
		for (int i = 0; i < PALETTE_MAX; i++) {
			vec3 p = texture(palette_tex, palette_uv(i)).rgb;
			vec3 d = p - src.rgb;
			// 加权欧氏距离：绿通道权重最高（人眼对绿最敏感），
			// 红蓝取近似权重。比朴素 RGB 距离更接近视觉感知。
			float dist = dot(d * d, vec3(2.0, 4.0, 3.0));
			if (dist < best) {
				best = dist;
				mapped = p;
			}
		}
	}

	// ③ 输出。alpha 保持原值：这里只统一颜色，不负责抠图。
	COLOR = vec4(mix(src.rgb, mapped, mix_strength), src.a);
}
