# 页灯 / Yedeng

面向 HarmonyOS 的本地 EPUB/TXT 阅读器。书籍、阅读进度、书签、笔记和高亮保存在本机；普通阅读和内置英汉词典不依赖账号、密钥或网络。当前应用无互联网权限、活跃AI、云书库或分析SDK。

## 当前状态 — 2026-10-31

**M4 已正式完成约定范围验收：标准字号、普通设置、API26 手机、API24 平板、API21 模拟器及代表性折叠模拟器。下一阶段是 M5 全文检索准备，本轮尚未实现 M5。**

本次公开快照补齐 E1 的笔记标记清除、双栏设置返回及设置入场阴影三项修复，并更新 E1/E2/E3 人工验收和 E4 结算记录。API25、真实折叠铰链、KI-015/KI-016、历史 SIGABRT 等风险保留，不把私有宿主35 Pass / 2 Fail或E2 2 Pass / 5 Error改为全绿。

采用已审查精简快照，继承现有公开 main；不公开私有历史、设备探针/夹具、签名、真实数据或原始日志。独立公开标签为 `m4-public-snapshot-20261031`，私有本地 `m4-accepted-20261031` 不推送。源码同步不创建 GitHub Release、不发布或安装新 App 包。

后续请先读[状态](docs/project-status.md)、[M4结算](docs/m4-e4-final-settlement-20261031.md)、[公开范围/验证](docs/public-source-snapshot.md)与[M5准备](docs/m5-search-preparation.md)。公开构建和私有验收包不同，不能据构建通过声称新包设备验收。

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
