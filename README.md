# Codex Meter

一个原生 macOS 菜单栏额度工具，用来显示 Codex 的 5 小时额度、周额度和可用重置次数。

![竖版吸附栏](吸附栏-竖版.png)
![横版吸附栏](吸附栏-横版.png)

## 功能

- 菜单栏实时显示 Codex 剩余额度，点击或悬停查看详情
- 独立小组件与始终置顶
- 跟随 Codex 窗口显示、隐藏和移动
- 拖拽吸附到窗口上、下、左、右侧，并自动切换横竖布局
- 可单独隐藏 5 小时额度、周额度或重置次数
- 自动、浅色和深色三种外观
- 自适应跟踪频率：移动时保持流畅，静止后降低资源占用

## 下载

下载仓库中的 [`Release/Codex Meter.zip`](Release/Codex%20Meter.zip)，解压后把 `Codex Meter.app` 放入“应用程序”文件夹。

首次使用窗口吸附时，macOS 可能要求授予辅助功能权限。

## 构建

需要 macOS 14 或更高版本和 Xcode。运行：

```bash
./build.sh
```

构建结果会写入上级目录：`Codex Meter.app` 和 `Codex Meter.zip`。

## 自检

```bash
../Codex\ Meter.app/Contents/MacOS/CodexMeter --self-test
../Codex\ Meter.app/Contents/MacOS/CodexMeter --probe
../Codex\ Meter.app/Contents/MacOS/CodexMeter --diagnose-follow
```

吸附栏可以直接拖到 GPT 窗口的上、下、左、右侧。拖动期间停止搜索窗口；松手后选择最近边缘，并按横向或纵向自动调整。跟随查询会在窗口移动时临时提高频率，静止后降频，减少空闲占用。

## 系统要求

- macOS 14 或更高版本
- Apple 芯片 Mac
- 已安装并登录 Codex 桌面端
