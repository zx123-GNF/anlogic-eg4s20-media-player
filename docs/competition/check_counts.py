# -*- coding: utf-8 -*-
"""Report per-section character counts against the template budgets."""
import re
import sys

from docx import Document

PATH = r"C:\Users\31860\Desktop\安路赛道第1题_作品报告_图文混排多媒体播放器.docx"
d = Document(PATH)
paras = list(d.paragraphs)

LIMITS = {"摘要": 800, "1.1": 400, "1.2": 400, "1.3": 400, "1.4": 200,
          "1.5": 200, "1.6": 200, "4.1": 300, "4.2": 1000}


def find(pat, start=0):
    for i in range(start, len(paras)):
        t = paras[i].text.strip()
        if t.endswith(pat) or t.startswith(pat):
            return i
    return -1


HEADS = [("摘要", "摘要", "功能与特性"), ("1.1", "功能与特性", "应用领域"),
         ("1.2", "应用领域", "主要技术特点"), ("1.3", "主要技术特点", "主要性能指标"),
         ("1.4", "主要性能指标", "主要创新点"), ("1.5", "主要创新点", "设计流程"),
         ("1.6", "设计流程", "第二部分"), ("4.1", "可扩展之处", "心得体会"),
         ("4.2", "心得体会", "参考文献")]

prev = 0
ok = True
for name, head, nxt in HEADS:
    a = find(head, prev)
    if nxt is None:
        b = len(paras)
    else:
        b = find(nxt, a + 1)
    n = len(re.sub(r"\s", "", "".join(p.text for p in paras[a:b])))
    lim = LIMITS[name]
    flag = "OK" if n <= lim else "OVER"
    if n > lim:
        ok = False
    print("%-4s %5d / %-5d %s" % (name, n, lim, flag))
    prev = a
print("total chars:", len(re.sub(r"\s", "", "".join(p.text for p in paras))))
print("tables:", len(d.tables), "pictures:", len(d.inline_shapes))
print("ALL WITHIN LIMITS" if ok else "SOME SECTIONS OVER")
