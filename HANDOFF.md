# 星星夜剧 · 接手必读

> 给后续接手的 AI / 开发者：读完本文即可上手。详细版见 `DEVELOPMENT.md`，给 AI 的约定见 `CLAUDE.md`。

## 1. 项目是什么

- **产品**：星星夜剧（原「小果影视」，英文名 GuoApp）——Flutter 多端短剧/影视应用。
- **平台**：Android / iOS / Windows / macOS，另有电视（TV）适配模式。
- **站源机制**：红果随安装包内置，其余站源为运行时加载的 JS 模块（可在线安装/更新，无需发版）。
- **来源**：fork 自 `Xanerix/guoapp`，改编自 `fish2018` 源码；当前主仓库 `hhhaieee/guoapp-playback`。

## 2. 技术栈

| 层 | 技术 |
| --- | --- |
| 界面/逻辑 | Flutter 3.47.9 + Dart 3.12+（状态管理仅用 ChangeNotifier） |
| 原生核心 | Go 1.24+（`native/core`），经 FFI 与 Dart 桥接 |
| 播放器 | media_kit / libmpv；下载转码用 FFmpegKit min-gpl |
| 站源 | 运行时 JS 模块（goja 执行），`manifest.json` + `main.js` |
| CI/CD | GitHub Actions 手动触发，产物发布到 GitHub Release |

## 3. 架构一句话

**Flutter 只管界面、播放器与本地用户数据；站源请求/解析/签名/缓存/下载调度/播放代理全在 Go 核心里完成。** 站源不是硬编码，是 JS 模块。

- FFI：`native/bridge`（c-shared，导出 `DuanjuRequest`/`DuanjuFree`）↔ `lib/core_bridge.dart`；action 分派在 `native/core/app_runtime.go`。新增能力两端都要改。
- 站源：`module_loader.go` 读取清单并注册，`module_script.go`（goja）执行并适配成内部 `Provider` 接口。

## 4. 目录速查

| 目录 | 内容 |
| --- | --- |
| `lib/ui/` | 界面：主题、导航壳、各页面、播放器、公共组件 |
| `lib/` | 逻辑层：FFI、站源目录、播放、下载、本地存储、用户 |
| `native/core/`、`native/bridge` | Go 运行时（缓存、下载、播放代理）+ C ABI |
| `native/module_example` | 示例站源（假数据、不联网） |
| `android` / `windows` / `ios` / `macos` | 平台工程与资源 |
| `scripts/` | 构建、图标生成、数据清理脚本 |
| `test/` | 逻辑层测试（公共假仓库在 `test/support/`） |
| `.github/workflows/build.yml` | 发布工作流 |
| `worker/` | 检查更新/使用统计的 Cloudflare Worker |

## 5. 关键文件

| 文件 | 作用 |
| --- | --- |
| `pubspec.yaml` | 版本号与构建号（发布前必改） |
| `CHANGELOG.md` | 更新日志（每版本一节，标题=完整版本号） |
| `lib/ui/theme/app_theme.dart`、`lib/theme_color.dart` | 主题系统（含默认「星星」主题） |
| `lib/ui/player/` | 播放器（竖屏/横屏/画中画/音量键） |
| `lib/ui/modules/modules_page.dart` | 模块页（已安装/在线仓库/内置/百宝袋/手动） |
| `native/core/module_index.go` | 模块商店索引 + 百宝袋仓库 |
| `ios/Runner/AppDelegate.swift` | iOS 画中画、音量键监听、前后台中断 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/` | iOS 图标（星空主题，全尺寸已生成） |

## 6. 发布流程（最重要）

1. **改版本号**：`pubspec.yaml` 的 `version: x.y.z+NNN` 中版本号与构建号**同时** +1。
2. **写日志**：`CHANGELOG.md` 顶部新增 `## x.y.z+NNN` 一节（每条简短；未实机验证标「开发快照」；单节 ≤3500 字）。
3. **推送 main**，在 Actions 手动运行 **Build app packages**（工作流只在 main 上手动触发，push/PR 不自动跑）。
4. **产物**：Android APK / Windows 安装包+便携 zip / iOS 未签名 IPA / macOS dmg；**全部平台成功才建 tag 与 Release**。
5. **IPA 直链**（TrollStore 侧载）：

   ```
   https://github.com/hhhaieee/guoapp-playback/releases/download/app-v{x.y.z-NNN}/guoapp-{x.y.z}%2B{NNN}-ios-unsigned.ipa
   ```

> 同名 tag/Release 已存在会导致 CI 失败——发布前先确认版本号未被用过。

## 7. 百宝袋插件上架/维护

「百宝袋」是 App 内「模块 › 百宝袋」联动 GitHub 仓库 `hhhaieee/baobaodai` 的在线插件源：任何版本 IPA 都能远程拉取安装，插件更新无需发版。

**上架一个新插件（4 步）：**

1. 把插件打成两个文件 `manifest.json` + `main.js`，放到任意 GitHub 仓库的某个 tag（如 `v1.0.0`）下。
2. 计算两个文件的 SHA-256：`sha256sum manifest.json main.js`。
3. 在 `baobaodai/index.json` 的 `modules` 数组追加一条记录（格式见下）。
4. 提交推送；App 内「模块 › 百宝袋」刷新即可安装。

**index.json 记录格式：**

```json
{
  "id": "example",
  "name": "示例插件",
  "version": "1.0.0",
  "description": "插件说明",
  "api": 1,
  "adult": false,
  "repo": "owner/repo",
  "tag": "v1.0.0",
  "sha256": {
    "manifest.json": "<64位SHA-256>",
    "main.js": "<64位SHA-256>"
  }
}
```

**规则：**

- `id`：小写字母/数字/`-`/`_`，以字母或数字开头，最长 32 位，须与插件目录同名。
- `version`：三段式 `x.y.z`；`tag` 为 `v` + 三段式版本号。
- `repo`：只写 `owner/repo`，不含 `https://github.com/` 前缀。
- `sha256`：App 下载后据此校验完整性。
- **同一个 `id` 只展示最新版本**：发新版时直接追加一条更高 `version` 的记录，旧记录无需删除（客户端按版本取最高）。

> index.json 只是「目录」，插件文件本体放在各自仓库的 tag 下，不要塞进 baobaodai 仓库。

## 8. 必须遵守的约定

- 访问任何站点前先看 `CLAUDE.md` 的「站源」硬性规定：**只允许直接访问 红果/韩小圈/鬼片/青空**，其余站点不得直接访问、不得跑会输出站点内容的测试。
- 不新增解释性代码注释（必要的编译/工具指令除外）；清晰命名 + 模块边界即可。
- UI 类改动不写单测，让用户看实际界面；测试统一带 `DISABLE_REMOTE_IMAGES=true`。
- 合并外部 PR 用 `git merge --no-ff` 原样合入，不 squash / cherry-pick / amend。
- 本地数据存储须兼容旧版；新增设置存为快照外的独立键。

## 9. 高频踩坑记录

- **Dart 3 严格类型**：`const {}` 必须写 `const <String, String>{}`，否则 iOS 构建失败。
- **iOS 音量键私有通知**：需先 `beginReceivingRemoteControlEvents()` 才能稳定接收（尤其音量边界按键）。
- **红果 CENC 加密流**：系统 AVPlayer 无法解密，画中画需经 `pipStream` 申请本地已解密流地址。
- **品牌名**：App 名统一「星星夜剧」，英文名 GuoApp，构建标识/安装包前缀 `guoapp`；改品牌涉及 iOS/Android/macOS/Windows/脚本多处。
- **版本号分隔符**：`+` 在 tag 中转 `-`，在 URL 中转 `%2B`。

## 10. 常用命令

```sh
# 编译 Go 核心（flutter run 前必做）
python3 scripts/build_native.py --platform android --abi arm64-v8a

# 检查
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos lib test
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true

# 出包
python3 scripts/build_ios.py        # iOS 未签名 IPA
python3 scripts/build_android.py    # Android APK
```

## 11. 相关仓库

| 仓库 | 用途 |
| --- | --- |
| `hhhaieee/guoapp-playback` | 应用主仓库 |
| `hhhaieee/baobaodai` | 「百宝袋」在线插件仓库（`index.json` 登记插件，上架/维护流程见第 7 节） |
| `guoapp-modules/hongguo` | 红果站源（CI 检出后内置） |
| `guoapp-modules/index` | 模块商店索引 |
