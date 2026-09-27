"""Build the original sample EPUB for local screenshots or the app package."""

import argparse
from io import BytesIO
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".hvigor" / "listing-capture" / "under-the-lamp.epub"
FONT_DIR = Path("C:/Windows/Fonts")


def cover_jpeg() -> bytes:
    width, height = 900, 1280
    image = Image.new("RGB", (width, height), "#172a40")
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / height
        draw.line((0, y, width, y), fill=(int(23 + 19*t), int(42 + 13*t), int(64 + 7*t)))
    gold = "#dfbd77"
    ivory = "#f5efdf"
    draw.line((84, 90, 816, 90), fill=gold, width=3)
    draw.line((84, 1190, 816, 1190), fill=gold, width=3)
    draw.ellipse((330, 225, 570, 465), outline=gold, width=4)
    draw.arc((365, 260, 535, 430), 10, 170, fill=gold, width=3)
    draw.polygon([(390, 325), (450, 342), (450, 433), (390, 416)], fill=ivory)
    draw.polygon([(450, 342), (510, 325), (510, 416), (450, 433)], fill="#e7d5a9")
    title = ImageFont.truetype(str(FONT_DIR / "NotoSerifSC-VF.ttf"), 104)
    subtitle = ImageFont.truetype(str(FONT_DIR / "NotoSansSC-VF.ttf"), 31)
    english = ImageFont.truetype(str(FONT_DIR / "constan.ttf"), 34)
    draw.text((450, 570), "在灯下", anchor="mm", font=title, fill=ivory)
    draw.text((450, 682), "UNDER THE LAMP", anchor="mm", font=english, fill=gold)
    draw.text((450, 1060), "一册关于阅读时刻的小书", anchor="mm", font=subtitle, fill=ivory)
    draw.text((450, 1130), "页灯 · 原创示例", anchor="mm", font=subtitle, fill=gold)
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=94)
    return buffer.getvalue()


chapters = [
    ("序 · 把时间留给阅读", [
        "晚上的城市终于安静下来。桌上的书没有催促，也没有提醒；它只在你翻开时，重新接住那段未读完的故事。",
        "读书不必追赶进度。有时是一页，有时是一章。把注意力放回文字，剩下的交给一盏安静的灯。",
        "窗外还有几盏灯亮着。有人刚踏上回家的路，有人坐在桌前，把今日最后一点时间交给一本书。",
        "书页上的空白让句子有了呼吸。读到喜欢的地方，可以停一停，让一个想法在心里慢慢展开。",
        "她想起上一次读到这里，正是一个下雨的午后。此刻没有雨，故事却仍能把那天的声音带回来。",
        "有些词第一次读并不明白。她把它轻轻标出，继续往下看；上下文常常会给出另一把钥匙。",
        "桌边的杯子已经凉了。她没有急着换水，仍想再读完眼前这一段，让结尾自然落下。",
        "读书是很私人的事。每个人都有自己的速度，也都有不必向谁展示的感受和笔记。",
        "灯光照着正在读的文字，未读的部分留在阴影里。她知道，明天再来时，书会从这里接着讲。",
        "夜深了，她合上书。故事没有结束，只是暂时停在一枚安静的书签旁。",
    ]),
    ("第一章 · 清晨的窗", [
        "清晨的光从窗边缓慢移过，落在纸页的边缘。街道尚未热闹，杯中的水仍有余温。",
        "她读到一个熟悉的句子，却在今天发现了不同的意思。文字没有改变，改变的是她与它相遇的时刻。",
        "她在页边留下一条短短的笔记：不必一次读懂全部。明天回来，仍能从这里继续。",
        "日光渐渐明亮，书页上的阴影退到桌角。她合上书，记住了这段安静的开始。",
        "第二天，她从留下的书签继续。窗外的景色变了，书里的道路依然清晰。",
        "她试着换一种更舒适的字号，又把行距调宽。文字依旧是那些文字，阅读的节奏却轻松了些。",
        "偶尔她会打开目录，看看自己来到故事的什么地方。章节的名字像一张简单的地图，提醒她前面的旅程。",
        "午后的光移到墙上，屋里逐渐安静。她没有听到任何提示音，只听见翻到下一页时短暂的停顿。",
        "一段句子让她想起朋友说过的话。她记下自己的理解，准备过几天回来，看看是否仍有同样的感受。",
        "她喜欢那种随时可以放下，也随时能够继续的自由。读完一章并不意味着要立刻开始下一章。",
        "到了黄昏，她关上书。窗边又亮起那盏小灯，照着下一次阅读的起点。",
    ]),
    ("第二章 · The Quiet Page", [
        "A small lamp stood beside the window. Its light reached only the open book, leaving the rest of the room at ease.",
        "The reader paused at an unfamiliar word. She looked it up, returned to the sentence, and found that the paragraph had opened a little further.",
        "There was no need to finish the chapter tonight. One page, read with care, was enough.",
        "Outside, the city kept moving. Inside, the next line waited patiently.",
    ]),
    ("尾声 · 留一处书签", [
        "阅读的位置可以保存，读到这里时的心情却只属于此刻。",
        "放下书以后，故事仍在。下次打开，继续从你停下的地方读起。",
    ]),
]


def xhtml(title: str, paragraphs: list[str]) -> str:
    body = "\n".join(f"<p>{p}</p>" for p in paragraphs)
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head><title>{title}</title></head>
<body><h1>{title}</h1>{body}</body></html>'''


def build(out: Path = OUT) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    manifest = "".join(f'<item id="c{i}" href="chapter{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1, len(chapters)+1))
    spine = "".join(f'<itemref idref="c{i}"/>' for i in range(1, len(chapters)+1))
    opf = f'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="book-id" xml:lang="zh-CN">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="book-id">urn:uuid:dd8745d9-d0a0-4765-8e45-93ad880e3eaf</dc:identifier>
<dc:title>在灯下</dc:title><dc:creator>页灯</dc:creator><dc:language>zh-CN</dc:language>
<meta name="cover" content="cover"/></metadata>
<manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="cover" href="cover.jpg" media-type="image/jpeg"/>{manifest}</manifest>
<spine toc="ncx">{spine}</spine></package>'''
    ncx_items = "".join(
        f'<navPoint id="p{i}" playOrder="{i}"><navLabel><text>{title}</text></navLabel><content src="chapter{i}.xhtml"/></navPoint>'
        for i, (title, _) in enumerate(chapters, 1)
    )
    ncx = f'''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head>
<meta name="dtb:uid" content="urn:uuid:dd8745d9-d0a0-4765-8e45-93ad880e3eaf"/></head>
<docTitle><text>在灯下</text></docTitle><navMap>{ncx_items}</navMap></ncx>'''
    with ZipFile(out, "w") as z:
        def add(name: str, content: str | bytes, compression: int = ZIP_DEFLATED) -> None:
            info = ZipInfo(name, date_time=(2026, 9, 28, 0, 0, 0))
            info.compress_type = compression
            z.writestr(info, content.encode("utf-8") if isinstance(content, str) else content)

        add("mimetype", "application/epub+zip", ZIP_STORED)
        add("META-INF/container.xml", '<?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        add("OEBPS/package.opf", opf)
        add("OEBPS/toc.ncx", ncx)
        add("OEBPS/cover.jpg", cover_jpeg())
        for i, (title, paragraphs) in enumerate(chapters, 1):
            add(f"OEBPS/chapter{i}.xhtml", xhtml(title, paragraphs))
    print(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", action="store_true", help="write the ignored generated rawfile for app builds")
    args = parser.parse_args()
    build(ROOT / "entry" / "src" / "main" / "resources" / "rawfile" / "demo" / "under-the-lamp.epub"
          if args.package else OUT)
