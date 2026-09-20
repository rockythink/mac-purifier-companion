# Mac 净化器伴侣

免费开源的原生 macOS 菜单栏工具：监测 Mac 状态，手动调节小米净化器风量，或按 CPU 温度自动联动。

**[下载最新版 → Releases](https://github.com/rockythink/mac-purifier-companion/releases)**

## 功能

- **菜单栏实时状态**：CPU 温度、负载、内存、风扇转速，净化器实测 RPM
- **手动控制**：0–17 档最爱模式直调，支持静音/均衡/散热模板及个人预设
- **自动联动**：CPU 温度超过阈值且持续满足条件后自动调节净化器档位，降温后恢复
- **联动对照图**：CPU 温度与净化器转速共享时间轴，直观看清联动效果
- **历史趋势**：本机 30 天温度、负载、内存、风扇、净化器转速记录
- **实物设备图**：Mac 与净化器显示真实产品照片，非线条图标
- **不配对也能用**：仅监测 Mac 本机状态，无需连接米家

## 平台

- Apple Silicon / macOS 14+
- 已实机验证：Apple M4 / macOS 27 + 小米空气净化器 2 (`zhimi.airpurifier.m1`)
- 其他旧版 miIO 协议净化器为 SDK 候选范围，未逐一实机验证

## 安装

1. 从 [Releases](https://github.com/rockythink/mac-purifier-companion/releases) 下载 `.dmg`
2. 拖入「应用程序」，从「应用程序」启动
3. 可选：用 `SHA256SUMS` 校验文件完整性

应用显示名为 **Mac 净化器伴侣**；Bundle ID 和安装路径保留 `MacFanLink`，不影响使用。

## 从源码构建

```bash
# 需要：macOS 14+、Swift 6.3、uv、macmon 0.8.2、Python 3.12（uv 可自动管理）
git clone https://github.com/rockythink/mac-purifier-companion.git
cd mac-purifier-companion
bash scripts/build_app.sh        # 产出 dist/MacFanLink.app
bash scripts/package_distribution.sh  # 产出 DMG + 源码包
```

## 详细文档

完整的功能规格、安全边界、隐私说明、兼容性范围见 [REQUIREMENTS.md](REQUIREMENTS.md)。

## 许可证

[GPL-3.0-only](LICENSE)。第三方组件、图片和商标的权利见 [第三方声明](Resources/ThirdPartyNotices.txt)。
