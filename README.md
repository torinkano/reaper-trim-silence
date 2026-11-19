# Trim Leading/Trailing Silence — voice-safe REAPER script

一个面向**配音/旁白**的 REAPER ReaScript：只清理选中音频媒体项**首尾接近数字静音**的部分，保留中间所有停顿、呼吸、弱尾字和自然衰减；保留音频的绝对时间轴位置不变。

> 设计目标：**宁可少裁，不要切掉人声细节**。  
> 默认阈值 `-80 dBFS` 不会把普通录音底噪当成静音；需要清底噪时再自行提高阈值。

## 功能

- 只处理**选中的音频媒体项**，不读取时间选区，不需要播放头位置。
- 用 take AudioAccessor 读取**源音频**（pre-FX、不含 take/item 音量、包络、淡变），按采样幅度寻找首尾真实声音。
- **只裁首尾**：中间停顿一动不动，不切割、不删除、不分割媒体项。
- 保持保留音频的**时间轴绝对位置**不变：不改吸附、不重排、不做波纹移动。
- 仅在**真正移动过的边**写短淡变；默认把被裁边的旧淡变重置为 2 ms / 5 ms 线性淡变。
- 支持**实时预览**：设置窗口打开后立即对选中项应用当前参数；拖动滑条/右键输入时实时更新。
- **右键滑条**可直接键入精确数值。
- **头/尾边界导航**：多选 10 个以上媒体项时，按时间轴顺序依次跳转每个项的 HEAD/TAIL；跳转后编辑光标自动居中到编排窗口。
- **Run** 提交预览（一个撤销块）；**Cancel / 关闭窗口**恢复到打开窗口前的媒体项、编辑光标和视图状态。
- 不依赖 SWS。

## 环境要求

- REAPER 7.x（ReaScript Lua 5.4）。
- 可选：[ReaImGui](https://github.com/cfillion/reaimgui) 0.10+。没有 ReaImGui 时会退回原生输入框，但**没有实时预览**。
- 不需要 SWS。

## 安装

### 通过 ReaPack（推荐）

在 REAPER 中：

```text
Extensions → ReaPack → Import repositories...
```

粘贴仓库地址：

```text
https://github.com/Jzpi/reaper-trim-silence/raw/main/index.xml
```

然后打开 `Browse packages`，找到 `Trim Leading/Trailing Silence (voice-safe)` 安装；以后用 `Synchronize packages` 更新。

### 手动安装

把 `TrimLeadingTrailingSilence.lua` 放到 REAPER 资源目录下的 `Scripts/` 中，例如：

```text
<REAPER resource path>/Scripts/TrimLeadingTrailingSilence.lua
```

然后在 REAPER 中：

```text
Actions → Show action list → New action... → Load ReaScript...
```

选择该文件。也可以直接拖入 Actions 窗口，或通过 ReaPack 自行建立仓库索引。

> 如果使用 ReaPack 覆盖安装，请保留独立文件名，避免上游脚本更新时被覆盖。

## 使用

1. 选中一个或多个**音频媒体项**。
2. 运行脚本，设置窗口打开后会立即出现实时预览。
3. 调整参数：
   - 拖动滑条；
   - 或**右键滑条**，键入精确值后按 Enter/OK；
   - 观察媒体项首尾边界和淡变变化。
4. 用 `Head` / `Tail` / `< Prev` / `Next >` 快速试听每个处理后的头尾。
5. 点 **Run** 提交（一次 Ctrl+Z 可回到运行前）；点 **Cancel** 或关闭窗口恢复原状。

## 设置窗口

| 控件 | 说明 |
|---|---|
| Threshold (dBFS) | 超过该电平视为声音；默认 `-80`，越负越保守 |
| Leading pad (ms) | 首个声音前保留，默认 `30` |
| Trailing pad (ms) | 最后声音后保留，默认 `100` |
| Fade in / Fade out (ms) | 被裁边的新淡变长度，默认 `2` / `5` |
| Minimum trim (ms) | 小于该值的边裁剪忽略，默认 `1` |
| Live preview interval (ms) | 实时预览最小刷新间隔，默认 `250`，可调 `50~1000` |
| Keep existing fade lengths | 勾选 = `preserve`，按裁剪量缩短原淡变；不勾 = `short`，被裁边重置为短线性淡变 |
| Preview only | Run 只报告统计，然后恢复，不提交 |
| Show summary after Run | 结束后弹统计框 |
| Center view on cursor | 边界跳转后自动把编辑光标居中到编排窗口，默认开启 |

### 头/尾边界导航

所有选中项按时间轴位置排序，每项产生 `HEAD`、`TAIL` 两个边界，共 `2 × N` 个：

```text
Boundary 3/20 - item 2/10 HEAD @ 12.345 s
[< Prev] [Next >] [Head] [Tail] [Play/Stop]
```

- `< Prev` / `Next >` 依次遍历全部头尾（循环）；
- `Head` / `Tail` 跳到当前项对应边界；
- `Play/Stop` 调用 Transport Play/Stop，配合 Head 试听；
- 跳转时编辑光标移动，并自动居中到编排窗口（保留横向缩放）；
- Cancel 恢复打开窗口前的编辑光标和视图范围。

## 默认参数

脚本顶部 `CFG`：

| 参数 | 默认 | 含义 |
|---|---|---|
| `threshold_db` | `-80` | 绝对电平阈值 |
| `leading_pad_ms` | `30` | 首个声音前保留 |
| `trailing_pad_ms` | `100` | 最后声音后保留 |
| `fade_in_ms` / `fade_out_ms` | `2` / `5` | 被裁边的新淡变 |
| `fade_policy` | `"short"` | `short` 重设被裁边淡变；`preserve` 保留并缩短原淡变 |
| `min_trim_ms` | `1` | 小于该值的边裁剪忽略 |
| `block_frames` | `4096` | 每次读取帧数 |
| `preview_refresh_ms` | `250` | 实时预览刷新间隔 |
| `preview_only` | `false` | 只预览不提交 |
| `show_settings_window` | `true` | 是否显示设置窗口 |
| `show_summary` | `true` | 结束后是否显示统计 |
| `console` | `false` | 控制台逐项输出 |

## 阈值与底噪

- 阈值是**绝对电平**，作用在 accessor 返回的源音频上。
- 普通录音底噪常在 `-45 ~ -65 dBFS`；默认 `-80` 时这些底噪会被当成“声音”，脚本不会修剪。这是按“只删真正接近零的静音、不硬裁底噪”的目标刻意设计的。
- 如果希望连底噪一起裁，需要把阈值改到“不那么负”的值（如 `-60`），并先在副本上试听确认没有吃掉呼吸/尾字。
- 统计框会显示本次实际使用的 Threshold / Pads / Fades。若文件首尾是纯数字零、语音电平又远高于阈值，那么不同阈值检测到的首尾边界可能相同，裁剪量相同是正常的。

## 支持范围

**支持**

- 普通音频源（WAV/AIFF/MP3/FLAC 等）。
- 一个或多个音频 take（均为音频、`playrate=1`、无 stretch markers、非反向）。
- 媒体项在时间轴任意位置。
- `D_STARTOFFS` 正/负偏移。
- 中间任意长停顿（不动）。
- Loop source 勾选但媒体项没有超出源末尾（不会发生实际循环）。
- 多声道（任一声道超过阈值即算声音）。
- 已有手动淡变（默认被裁边重设；未移动的边保留）。
- 自动交叉淡变/重叠边：跳过该边并统计。

**跳过并统计（不修改）**

- MIDI take、空 take
- 锁定 item
- take playrate ≠ 1.0
- 有 stretch markers
- loop source 实际发生重复（媒体项超出源末尾）
- 反向源
- 节拍型源（beat-based，如 REX；长度以 QN 返回）
- 所有 take 同时播放（`B_ALLTAKESPLAY`）
- 源采样率无效
- 全静音媒体项
- 裁剪后过短
- 自动交叉淡变边 / 同轨重叠边
- take 包络点在待裁的首部区域内

## 测试

- 模拟 REAPER API 的单元测试：**47/47 通过**。
- 真实 REAPER 7.78 x64 上：合成素材 **13/13 通过**；当前选中音频的复制项也验证了处理、淡变和原项不变。
- 测试方法与结果见 [docs/TESTING.md](docs/TESTING.md)。

```bash
# mock 测试（需要 Lua 5.4）
lua tests/test_trim.lua

# 生成真实 REAPER 测试素材
python tests/reaper/make_test_media.py

# 在已打开的 REAPER 中运行合成测试
"C:\Program Files\REAPER (x64)\reaper.exe" -nonewinst tests/reaper/run_synthetic_tests.lua
```

> 真实测试会创建临时轨并在结束后删除；`run_actual_item_test.lua` 会复制当前选中项测试，原始项不变，测试后恢复选中。

## 目录

```text
.
├─ TrimLeadingTrailingSilence.lua   # 最终脚本
├─ README.md
├─ index.xml                        # ReaPack repository index
├─ LICENSE                          # GPL v3
├─ docs/
│  └─ TESTING.md
└─ tests/
   ├─ test_trim.lua                 # 模拟 API 测试（47）
   └─ reaper/
      ├─ make_test_media.py         # 生成合成 WAV
      ├─ run_synthetic_tests.lua    # 真实 REAPER 合成测试（13）
      └─ run_actual_item_test.lua   # 复制当前选中项测试
```

## 已知限制

- 实时预览/边界导航依赖 ReaImGui；没有 ReaImGui 时只有原生输入框，没有实时预览。
- 音频扫描是 source-level，不是轨道输出；如果你靠 item/take 音量或 FX 改变听感，阈值仍按源音频计算。
- 首尾检测是“高于阈值的采样”，不是瞬态检测，也不识别语义上的呼吸/停顿。
- 测试未覆盖真实鼠标点击 GUI 的完整回归；核心处理、预览状态恢复、右键输入和边界导航已用模拟/真实 REAPER 验证。

## 许可与致谢

- 本脚本受 X-Raym 的 “Trim selected items at first and last transient” 启发，原脚本为 GPL v3。
- 本实现同样以 **GPL v3** 发布，见 [LICENSE](LICENSE)。
