# -*- coding: utf-8 -*-
"""Style self-check: AI-ish connectives, sentence length spread, banned words."""
import re
import sys

from docx import Document

PATH = r"C:\Users\31860\Desktop\安路赛道第1题_作品报告_图文混排多媒体播放器.docx"
d = Document(PATH)
body = [p.text.strip() for p in d.paragraphs if p.text.strip()]
text = "\n".join(body)

TELLS = ["综上所述", "总而言之", "总的来说", "首先", "其次", "再次", "最后，", "值得注意的是",
         "值得一提的是", "不难看出", "由此可见", "旨在", "赋能", "助力", "本文将", "本文",
         "不仅", "而且", "一方面", "另一方面", "综上", "显著提升", "极大地", "深入地"]
print("== AI 风格词命中 ==")
hit = 0
for t in TELLS:
    n = text.count(t)
    if n:
        hit += n
        print("  %-6s x%d" % (t, n))
print("  合计", hit)

print("== 段落长度分布 ==")
lens = sorted(len(re.sub(r"\s", "", s)) for s in body)
print("  段落数", len(lens), "最短", lens[0], "中位", lens[len(lens) // 2], "最长", lens[-1])

print("== 句长分布 ==")
sents = [s for s in re.split(r"[。！？]", text) if len(re.sub(r"\s", "", s)) > 4]
sl = sorted(len(s) for s in sents)
print("  句数", len(sl), "最短", sl[0], "中位", sl[len(sl) // 2], "最长", sl[-1])

print("== 禁用内容扫描 ==")
for bad in ["大学", "学院", "学校", "指导老师", "队名"]:
    if bad in text:
        print("  命中", bad)
print("  完成")
