# 页灯 / Yedeng

面向 HarmonyOS 的本地 EPUB/TXT 阅读器。书籍、阅读进度、书签、笔记和高亮保存在本机；普通阅读和内置英汉词典不依赖账号、密钥或网络。当前应用无互联网权限、活跃AI、云书库或分析SDK。

## 当前状态 — 2026-10-20

**M4-D4（含D4-4）已获Mate60 Pro人工验收并完成本地收尾；整个M4仍有M4-E兼容性验收，尚未结算。**

本次公开同步包括书架/管理更新、目录与图书混合递归删除及反馈、统一阅读记录入口和原生Tabs滑动、书签增删后的集中列表刷新与返回恢复，以及已确认的阅读辅助层、外观和设置交互。

这是经审查的精简源码快照，继承现有公开仓库历史，不公开原开发历史、历史AI模块、私有设备探针/夹具或研究截图日志。公开标签`m4-d4-public-snapshot-20261020`与私有开发线的手机验收标签分开，不表示两个提交SHA相同。源码同步不创建Release，也不发布新的应用安装包。

后续ChatGPT/贡献者请先读[状态](docs/project-status.md)、[M4-E准备](docs/m4-e-compatibility-readiness.md)和[公开范围/验证](docs/public-source-snapshot.md)。

## 本地测试与构建

宿主测试使用Node.js **22.20.0**及锁定的TypeScript **4.9.5**，只作为开发依赖：

```sh
npm ci --ignore-scripts
npm test
```

这些源码/受控行为合同不是ArkUI、ArkWeb或低版本真机验收。GitHub Actions只运行宿主合同。

应用构建组合：SDK/target **26.0.0**（SDK26.0.0.105）、compatible **API21**、Hvigor/plugin **6.26.8**、构建Node **24.14.1**、JBR **21.0.8**。保留API21/25普通回退，不把声明存在当设备验证。

1. 安装匹配的官方DevEco/SDK/命令行工具；`oh-package.json5`和`hvigor/hvigor-config.json5`记录模型版本。
2. 将`build-profile.example.json5`复制为被忽略的`build-profile.json5`，在DevEco Studio配置自己的本地调试签名；不要提交机器配置或签名材料。
3. 安装HarmonyOS工程依赖，在DevEco Studio构建`entry`的`default`目标。公开快照不含私有`ohosTest`目标。
4. Windows/PowerShell 7已配置工具和Hvigor缓存时，可运行下列SDK构建及生产包审计；`-HvigorCache`指向本机已配置的SDK26 Hvigor用户缓存，脚本不下载第二套运行时：

```powershell
.\tools\run-installed-sdk-gate.ps1 -Mode Development -DevEcoHome 'C:\Path\To\DevEco Studio' -Sdk26Tools 'C:\Path\To\command-line-tools' -HvigorCache 'C:\Path\To\configured-hvigor-user-home'
```

`-Mode Release`只在本地构建/审计，不上传；`-Mode Full`运行宿主合同及debug/release/benchmark生产构建，不含私有设备测试。依赖、签名或工具未就绪时先配置本机环境，不能清理用户数据来满足构建。

词典数据、许可和重建步骤见[词典说明](third_party/dictionary/README.md)。生产包不包含测试书籍，也不自动导入示例书。

## 许可

源码依[Apache 2.0](LICENSE)开放；第三方软件、词典与艺术资源保留各自许可，见[第三方声明](THIRD_PARTY_NOTICES.md)与[主题图像来源](docs/ARTWORK.md)。源码许可不授予页灯商标权。贡献前阅读[CONTRIBUTING](CONTRIBUTING.md)。
