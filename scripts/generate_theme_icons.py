import argparse
import colorsys
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='生成 8 种主题色的首页星气球变体（星星保持纯白）。需要 Pillow。')
parser.add_argument('--output', type=Path, default=root)
options = parser.parse_args()
output = options.output

# 与 lib/theme_color.dart 的 ThemeColor.seed 一一对应。
themes = {
    'white': 0xFFFFFF,
    'orange': 0xFFFF664F,
    'rose': 0xFFC25485,
    'amber': 0xFFB37000,
    'teal': 0xFF009C84,
    'blue': 0xFF0089D0,
    'violet': 0xFF7970D5,
    'star': 0xFF3EE0FF,
}

def channels(seed):
    return [(seed >> shift) & 255 for shift in (16, 8, 0)]

# ---- 首页星气球变体：只换球体颜色，白色星星与明暗渐变完全保留 ----
ball_source = Image.open(root / 'assets/images/star_ball.png').convert('RGBA')
ball_pixels = ball_source.load()
ball_w, ball_h = ball_source.size

# 原图球体基准色相（度）：采样高饱和像素的中位色相。
sample_hues = []
for y in range(ball_h):
    for x in range(ball_w):
        r, g, b, a = ball_pixels[x, y]
        hue, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if sat > 0.5 and val > 0.15:
            sample_hues.append(hue * 360)
sample_hues.sort()
base_hue = sample_hues[len(sample_hues) // 2]

for name, seed in themes.items():
    if name == 'white':
        # 白色主题：素色球，靠明度渐变保留立体感，星星依旧纯白。
        target_hue = base_hue
        target_sat = 0.0
    else:
        r, g, b = channels(seed)
        target_hue, target_sat, _ = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        target_hue *= 360
    out = ball_source.copy()
    px = out.load()
    for y in range(ball_h):
        for x in range(ball_w):
            r, g, b, a = px[x, y]
            hue, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            # 低饱和/高亮 = 星星与高光，保持原样（纯白）。
            if sat < 0.25 or val > 0.93:
                continue
            new_hue = ((target_hue + (hue * 360 - base_hue)) % 360) / 360
            # 深浅优化：球体饱和度贴近主题色，同时保留原图饱和度浮动。
            new_sat = min(1.0, max(0.0, target_sat + (sat - 0.85) * 0.35))
            nr, ng, nb = colorsys.hsv_to_rgb(new_hue, new_sat, val)
            px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    out.save(output / f'assets/images/star_ball_{name}.png')

print(f'基准色相 {base_hue:.1f}°, 已生成 {len(themes)} 张球体变体')
