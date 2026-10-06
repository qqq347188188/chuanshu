"""生成 LanShare iOS 端 1024x1024 AppIcon（需要 Pillow：pip install pillow）"""
import os
from PIL import Image, ImageDraw

SIZE = 1024
TOP = (76, 102, 242)
BOTTOM = (115, 76, 235)
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")


def gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)],
               fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def draw_arrow(d, cx, cy, w, h, head, right):
    body_h = int(h * 0.42)
    x0, x1 = cx - w // 2, cx + w // 2
    top, bottom = cy - body_h // 2, cy + body_h // 2
    if right:
        d.rectangle([x0, top, x1 - head, bottom], fill=(255, 255, 255))
        d.polygon([(x1 - head, cy - h // 2), (x1 - head, cy + h // 2), (x1, cy)],
                  fill=(255, 255, 255))
    else:
        d.rectangle([x0 + head, top, x1, bottom], fill=(255, 255, 255))
        d.polygon([(x0 + head, cy - h // 2), (x0 + head, cy + h // 2), (x0, cy)],
                  fill=(255, 255, 255))


def main():
    img = gradient(SIZE)
    d = ImageDraw.Draw(img)
    draw_arrow(d, SIZE // 2, int(SIZE * 0.38), int(SIZE * 0.54), int(SIZE * 0.20),
               int(SIZE * 0.12), True)
    draw_arrow(d, SIZE // 2, int(SIZE * 0.62), int(SIZE * 0.54), int(SIZE * 0.20),
               int(SIZE * 0.12), False)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, "PNG")
    print("icon ->", OUT)


if __name__ == "__main__":
    main()
