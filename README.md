# 巨魔录音机 浏览器选择 (TrollRecorderBrowserPicker)

越狱插件：拦截巨魔录音机（TrollRecorder，包名 `wiki.qaq.trapp`）登录时弹出的「只能用 Safari 登录」鉴权流程（`ASWebAuthenticationSession`），让你可以选择用 **第三方浏览器** 打开登录页。

## 为什么需要它

巨魔录音机登录默认用 `ASWebAuthenticationSession`（iOS 13+ 与 Safari 共享 Cookie）。如果你想用别的浏览器（Alook / Chrome / 夸克）登录，或者想隔离 Cookie 不污染 Safari 登录态，原生是不支持的——它锁死在 Safari。

本插件在 `start` 阶段拦截登录请求，按你的设置把鉴权 URL 丢给 **Alook / Chrome / 夸克** 打开。登录完成后回调由插件 hook 的 AppDelegate 接收并喂回原回调，完成登录。

## 支持的模式

| 模式 | 说明 |
|---|---|
| 禁用 | 不改任何行为（原始流程） |
| Safari（默认） | 原始行为，与 Safari 共享 Cookie |
| Safari（独立会话） | `prefersEphemeralWebBrowserSession`，隔离 Cookie，不影响 Safari 登录态 |
| Alook | `Alook://<完整 URL>` |
| Chrome | `googlechromes://`（自动替换 https://） |
| 夸克 | `quark://web?target=<编码 URL>` |
| 每次询问 | 每次登录弹窗让你选（默认） |

## 安装

1. 下载 Release 里的 `com.mosheng.trappbrowserpicker_1.0.0_iphoneos-arm64e.deb`
2. 用 Sileo / Filza 安装（需已装 ElleKit 与 PreferenceLoader）
3. 重启巨魔录音机（TrollRecorder）
4. 打开 **设置 → 巨魔录音机 浏览器选择**，启用并选择浏览器

> 适用环境：Dopamine 2.0 / iOS 15+ / rootless 越狱（arm64e）。
> 注入目标：`wiki.qaq.trapp`。

## 工作原理（简述）

1. Hook `ASWebAuthenticationSession -initWithURL:callbackURLScheme:completionHandler:`，**自动捕获**回调 scheme（不写死，适配巨魔录音机的真实 scheme）
2. Hook `-start`：根据偏好决定走原生 Safari、Safari 独立会话，或把 URL 丢给第三方浏览器（返回 YES 假装已启动）
3. Hook `UIApplication -setDelegate:`，运行时对 AppDelegate 交换 `application:openURL:options:`
4. 第三方浏览器完成登录后回调，被交换方法拦截并直接调用原回调 block
5. 若用户在 1.2s 内回到 App 却没完成登录，自动以 `canceledLogin` 取消，避免卡死

## 已知限制

- **夸克** 的 URL Scheme 为多方推测值，若点击后无反应，请反馈，我会调整候选格式。
- 第三方浏览器需已安装，否则 `openURL:` 会失败（可重试或在设置里换模式）。
- 外部浏览器（Alook/Chrome/夸克）模式依赖巨魔录音机在 Info.plist 里注册了登录回调 scheme；若未注册，回调可能回不来。此时请用 Safari（默认/独立会话）模式，那两条路径不依赖 scheme 注册，必定可用。

## License

MIT
