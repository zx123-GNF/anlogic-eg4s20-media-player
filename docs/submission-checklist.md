# 提交清单

安路赛道 第 1 题（EG4S20 HDMI 多媒体播放）· 截止 **2026-11-04 18:00** · 决赛 11-20~22

## 已完成

- [x] **最终版工程** `proj/m6_final`（M6 改名而来，顶层 `m6_top`）
      综合/布局布线通过：5302 LUT / 6282 REG / 33 BRAM / 2 DSP，
      SWNS +0.102 ns、HWNS +0.003 ns，bitstream 629 635 B
- [x] **SPI 配置 Flash 固化**：`program_spi` 约 87 s、`verify_spi` 约 28 s 均通过，断电重启约 2 s 自启动
- [x] **五阶段工程汇报** Word：`docs/report/安路赛道第1题_五阶段工程汇报.docx`
- [x] **作品报告**（官方模板）Word：`docs/competition/安路赛道第1题_作品报告_图文混排多媒体播放器.docx`
- [x] **代码包**：`release/fpga安路一题代码.rar`（M0~M6 全部阶段代码 + 全部调试日志 + 阶段调试报告）
- [x] 上板手册 `docs/board-test-guide.md`、演示脚本 `docs/demo-script.md`（§7 = M6）

## 待办

- [ ] 作品报告里 3 处 `【此处插入实物照片…】` 换成实拍：系统正面/斜 45°、板卡接口与接线、屏幕+数码管读数
- [ ] 录演示视频：上电自启动 → 5 张照片 → 视频带 HDMI 音频 → 短按切换 → 长按暂停/恢复 → 断电重启仍自启动
- [ ] 按 `docs/demo-script.md` §7 走一遍答辩台词（HDMI 每次重新配置要重插、TF 卡不热插拔这两条要提前说）
- [ ] 交稿前复查现场：卡上 8 个文件、数码管左 `08` 右 `0x`、耳机/显示器喇叭出声

## 交付物对照

| 交付物 | 位置 |
|---|---|
| 工程源码 + 约束 + 构建脚本 | `proj/m6_final/`（`rtl/`、`IO.adc`、`timing.sdc`、`build.ps1`、`make_proj_files.ps1`） |
| 片源编码工具 | `tools/m6_encode.py`（`--max-kb 36`） |
| 代码压缩包 | `release/fpga安路一题代码.rar` |
| 五阶段报告 | `docs/report/` |
| 作品报告（模板） | `docs/competition/` |
| 里程碑与 bug 复盘 | `docs/research/m0..m6-report.md`、`bench-bringup-postmortem.md` |
