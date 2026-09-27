# 页灯 / Yedeng

页灯是面向 HarmonyOS 的本地 EPUB 阅读器，也支持将 TXT 在设备上转换为阅读副本。书籍、阅读进度、书签、划线和笔记保存在本机；基础阅读和内置英汉词典无需账号、密钥或网络。当前发布的源码不包含启用中的 AI 或应用内联网功能。

本仓库提供当前应用源码、源码契约、构建脚本和一册原创示例书《在灯下》。历史 AI 实现和历史设备探针不属于当前应用，未收进公开快照。仓库不包含签名凭据、商店上架包或用户书籍。源码公开不代表某个二进制包已经通过华为审核。

## 本地构建

开发环境：Windows、DevEco Studio 6.0.1、HarmonyOS SDK 6.0.1、Node.js 22.20.0、PowerShell 7；运行源码测试需要 Node.js，重新生成示例书需要 Python、Pillow 和脚本列出的字体。

1. 将 `build-profile.example.json5` 复制为 `build-profile.json5`，在 DevEco Studio 中配置**自己的**调试签名。这个本机文件被 Git 忽略。
2. 用 DevEco Studio 打开仓库根目录，安装 `oh-package.json5` 中的开发依赖。
3. 运行 `node tools/run-source-contracts.cjs` 检查公开版源码契约。
4. 使用 DevEco Studio 构建 `entry` 模块。Windows 上也可运行 `pwsh -NoProfile -File tools/run-installed-sdk-gate.ps1 -DevEcoHome 'C:\Path\To\DevEco Studio'`，执行源码检查、构建和包体审计；此命令要求本机签名配置及 SDK 齐全。

原创示例 EPUB 已包含在 `entry/src/main/resources/rawfile/demo/`。`tools/build-listing-demo-epub.py` 是其生成源码；通常无需重新生成。词典数据库随应用提供，重建流程见 `third_party/dictionary/README.md`。

## 结构

- `AppScope/`、`entry/`：应用配置、ArkTS/ArkUI 源码及资源。历史设备探针依赖私有生成夹具，未收进公开快照。
- `tools/`：构建、源码契约和本地包体检查。
- `docs/public/privacy-policy/`：与应用内离线隐私文本对应的政策源文件。
- `third_party/dictionary/`：词典来源和重建说明。

## 许可和来源

项目源码依 [Apache License 2.0](LICENSE) 开放；第三方软件、词典数据和艺术作品保留各自的权利状态及要求。详见 [第三方声明](THIRD_PARTY_NOTICES.md)与[主题图像来源](docs/ARTWORK.md)。页灯名称与视觉标识不因源码许可而授予商标使用权。

贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。
