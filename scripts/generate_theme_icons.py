import argparse
import colorsys
import io
import json
from pathlib import Path

import resvg_py
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='生成 8 种主题色的桌面图标变体 + 首页星气球变体（星星保持纯白）。需要 Pillow 和 resvg-py。')
parser.add_argument('--output', type=Path, default=root)
options = parser.parse_args()
output = options.output
source = (root / 'scripts/brand_icon.svg').read_text(encoding='utf-8')

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

def pastel(seed):
    return tuple(round(255 * 0.78 + value * 0.22) for value in channels(seed))

def render(svg):
    png = resvg_py.svg_to_bytes(svg_string=svg, width=1024, height=1024)
    return Image.open(io.BytesIO(bytes(png))).convert('RGBA')

foreground = render(source)

# iOS appiconset：必须与主图标同样的完整 idiom 尺寸集，actool 才会编进 Assets.car。
icon_entries = [
    ('iphone', '20x20', '2x', 40), ('iphone', '20x20', '3x', 60),
    ('iphone', '29x29', '1x', 29), ('iphone', '29x29', '2x', 58), ('iphone', '29x29', '3x', 87),
    ('iphone', '40x40', '2x', 80), ('iphone', '40x40', '3x', 120),
    ('iphone', '60x60', '2x', 120), ('iphone', '60x60', '3x', 180),
    ('ipad', '20x20', '1x', 20), ('ipad', '20x20', '2x', 40),
    ('ipad', '29x29', '1x', 29), ('ipad', '29x29', '2x', 58),
    ('ipad', '40x40', '1x', 40), ('ipad', '40x40', '2x', 80),
    ('ipad', '76x76', '1x', 76), ('ipad', '76x76', '2x', 152),
    ('ipad', '83.5x83.5', '2x', 167),
    ('ios-marketing', '1024x1024', '1x', 1024),
]

# Windows share extension app icons (secondary).
secondary_entries = [
    ('iphone', '20x20', '2x', 40), ('iphone', '20x20', '3x', 60),
    ('iphone', '29x29', '2x', 58), ('iphone', '29x29', '3x', 87),
    ('iphone', '40x40', '2x', 80), ('iphone', '40x40', '3x', 120),
    ('iphone', '60x60', '2x', 120), ('iphone', '60x60', '3x', 180),
]

def rounded_icon(background):
    icon = Image.new('RGBA', (1024, 1024), background + (255,))
    icon.alpha_composite(foreground)
    rounded = icon.copy()
    corners = Image.new('L', (1024, 1024), 0)
    ImageDraw.Draw(corners).rounded_rectangle((0, 0, 1023, 1023), radius=236, fill=255)
    rounded.putalpha(corners)
    return rounded

for name, seed in themes.items():
    if name == 'star':
        continue  # 默认星星主题沿用主图标，不生成 alternate icon。
    background = pastel(seed)
    rounded = rounded_icon(background)
    icon_set = output / f'ios/Runner/Assets.xcassets/AppIcon-{name.title()}.appiconset'
    icon_set.mkdir(parents=True, exist_ok=True)
    entries = []
    for idiom, size, scale, px in icon_entries:
        filename = f'icon_{idiom}_{size.replace("x", "x")}_{scale}.png'
        rounded.resize((px, px), Image.Resampling.LANCZOS).save(icon_set / filename)
        entries.append({'idiom': idiom, 'size': size, 'scale': scale, 'filename': filename})
    (icon_set / 'Contents.json').write_text(
        json.dumps({'images': entries, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n',
        encoding='utf-8',
    )
    for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
        legacy = round(48 * scale)
        save_legacy = output / f'android/app/src/main/res/mipmap-{density}/ic_launcher_{name}.png'
        save_legacy.parent.mkdir(parents=True, exist_ok=True)
        rounded.resize((legacy, legacy), Image.Resampling.LANCZOS).save(save_legacy)
    adaptive_xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background_'
        f'{name}"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n'
    )
    adaptive = output / f'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_{name}.xml'
    adaptive.parent.mkdir(parents=True, exist_ok=True)
    adaptive.write_text(adaptive_xml, encoding='utf-8')

backgrounds = [
    f'    <color name="ic_launcher_background_{name}">#{"%02X%02X%02X" % pastel(seed)}</color>'
    for name, seed in themes.items() if name != 'star'
]
backgrounds_file = output / 'android/app/src/main/res/values/ic_launcher_theme_backgrounds.xml'
backgrounds_file.parent.mkdir(parents=True, exist_ok=True)
backgrounds_file.write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n' + '\n'.join(backgrounds) + '\n</resources>\n',
    encoding='utf-8',
)

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

print(f'基准色相 {base_hue:.1f}°, 已生成 {len(themes)} 张球体变体 + {len(themes) - 1} 套图标变体')
