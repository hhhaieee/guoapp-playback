import argparse
import io
import json
from pathlib import Path

import resvg_py
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='生成 8 种主题色的桌面图标变体（默认星星主题沿用主图标，不重复生成）；需要 Pillow 和 resvg-py。')
parser.add_argument('--output', type=Path, default=root)
options = parser.parse_args()
output = options.output
source = (root / 'scripts/brand_icon.svg').read_text(encoding='utf-8')

themes = {
    'White': 0xFFFFFF,
    'Orange': 0xFFFF664F,
    'Rose': 0xFFC25485,
    'Amber': 0xFFB37000,
    'Teal': 0xFF009C84,
    'Blue': 0xFF0089D0,
    'Violet': 0xFF7970D5,
}

def pastel(seed):
    channels = [(seed >> shift) & 255 for shift in (16, 8, 0)]
    return tuple(round(255 * 0.78 + value * 0.22) for value in channels)

def render(svg):
    png = resvg_py.svg_to_bytes(svg_string=svg, width=1024, height=1024)
    return Image.open(io.BytesIO(bytes(png))).convert('RGBA')

foreground = render(source)

def rounded_icon(background):
    icon = Image.new('RGBA', (1024, 1024), background + (255,))
    icon.alpha_composite(foreground)
    rounded = icon.copy()
    corners = Image.new('L', (1024, 1024), 0)
    ImageDraw.Draw(corners).rounded_rectangle((0, 0, 1023, 1023), radius=236, fill=255)
    rounded.putalpha(corners)
    return rounded

alternate_contents = {
    'images': [
        {
            'filename': 'icon.png',
            'idiom': 'universal',
            'platform': 'ios',
            'size': '1024x1024',
        }
    ],
    'info': {'author': 'xcode', 'version': 1},
}

for name, seed in themes.items():
    background = pastel(seed)
    rounded = rounded_icon(background)
    icon_set = output / f'ios/Runner/Assets.xcassets/AppIcon-{name}.appiconset'
    icon_set.mkdir(parents=True, exist_ok=True)
    save = icon_set / 'icon.png'
    rounded.resize((1024, 1024), Image.Resampling.LANCZOS).save(save)
    (icon_set / 'Contents.json').write_text(
        json.dumps(alternate_contents, indent=2) + '\n', encoding='utf-8'
    )
    for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
        legacy = round(48 * scale)
        save_legacy = output / f'android/app/src/main/res/mipmap-{density}/ic_launcher_{name.lower()}.png'
        save_legacy.parent.mkdir(parents=True, exist_ok=True)
        rounded.resize((legacy, legacy), Image.Resampling.LANCZOS).save(save_legacy)
    adaptive_xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background_'
        f'{name.lower()}"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n'
    )
    adaptive = output / f'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_{name.lower()}.xml'
    adaptive.parent.mkdir(parents=True, exist_ok=True)
    adaptive.write_text(adaptive_xml, encoding='utf-8')

backgrounds = [
    f'    <color name="ic_launcher_background_{name.lower()}">#{"%02X%02X%02X" % pastel(seed)}</color>'
    for name, seed in themes.items()
]
backgrounds_file = output / 'android/app/src/main/res/values/ic_launcher_theme_backgrounds.xml'
backgrounds_file.parent.mkdir(parents=True, exist_ok=True)
backgrounds_file.write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n' + '\n'.join(backgrounds) + '\n</resources>\n',
    encoding='utf-8',
)
