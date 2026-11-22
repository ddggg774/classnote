#!/usr/bin/env python3
# tools/make_icons.py
# 从 assets/branding/app_icon_source.jpg 生成 Android / iOS 的全套启动图标。
#
# 为什么要一个脚本而不是手动切图：
#   图标有 5 个 Android 密度、5 个自适应图标前景、15 个 iOS 尺寸，
#   手改一次就得重来 25 张，还很容易漏掉某一档。脚本化之后换图只要重跑一次。
#
# 裁剪取的是原图里眼睛到下巴那一块（600,420 为中心、640 见方），
# 这样在 48px 的启动器里仍能看出是人像，而不是一片浅色线条。
#
# 依赖 Pillow。运行：
#   python tools/make_icons.py

import os
from PIL import Image, ImageEnhance

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "branding", "app_icon_source.jpg")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
IOS = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")

# 裁剪框：中心 (520, 420)，边长 640
# 为什么不是正中间：这张画的脸偏左、右侧是脸颊与发梢，
# 直接用画面中心裁会让脸贴到左边去；往左取一点，脸才落在视觉中心。
CROP = (200, 100, 840, 740)

# Android 传统图标（API < 26）
LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Android 自适应图标前景（108dp 画布）
FOREGROUND = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# iOS AppIcon.appiconset 里的文件名 -> 像素
IOS_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

ADAPTIVE_ICON_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Android 8.0+ 自适应图标：白色背景 + 同一张画的前景层。
     颜色定义在 values/ic_launcher_background.xml。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""

BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- 图标底色：与插画白底一致，这样圆角/圆形遮罩下不会出现一圈灰边 -->
    <color name="ic_launcher_background">#FFFFFF</color>
</resources>
"""


def main():
    im = Image.open(SRC).convert("RGB")
    square = im.crop(CROP)
    # 轻推对比与饱和度：这张线稿很淡，不推的话 48px 下几乎是一片白
    square = ImageEnhance.Contrast(square).enhance(1.10)
    square = ImageEnhance.Color(square).enhance(1.15)

    for folder, size in LEGACY.items():
        out_dir = os.path.join(RES, folder)
        os.makedirs(out_dir, exist_ok=True)
        square.resize((size, size), Image.LANCZOS).save(
            os.path.join(out_dir, "ic_launcher.png"), "PNG", optimize=True
        )

    for folder, size in FOREGROUND.items():
        out_dir = os.path.join(RES, folder)
        os.makedirs(out_dir, exist_ok=True)
        square.resize((size, size), Image.LANCZOS).save(
            os.path.join(out_dir, "ic_launcher_foreground.png"), "PNG", optimize=True
        )

    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(ADAPTIVE_ICON_XML)

    values = os.path.join(RES, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "ic_launcher_background.xml"), "w", encoding="utf-8") as f:
        f.write(BACKGROUND_XML)

    if os.path.isdir(IOS):
        for name, size in IOS_SIZES.items():
            square.resize((size, size), Image.LANCZOS).save(
                os.path.join(IOS, name), "PNG", optimize=True
            )

    branding = os.path.join(ROOT, "assets", "branding")
    square.resize((512, 512), Image.LANCZOS).save(
        os.path.join(branding, "app_icon_512.png"), "PNG", optimize=True
    )

    print("icons generated")
    for folder, size in LEGACY.items():
        print(f"  {folder}/ic_launcher.png  {size}x{size}")
    print(f"  ios appiconset: {len(IOS_SIZES)} files" if os.path.isdir(IOS) else "  ios: skipped")


if __name__ == "__main__":
    main()