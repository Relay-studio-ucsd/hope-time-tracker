# Hope

正在从 Electron 重构为 Tauri 2。**开工前先读 `docs/rebuild-plan.md`**，它是架构、数据模型、设计系统和阶段顺序的唯一权威来源。

## 硬性规则

- 技术栈按 rebuild-plan 第 2 节固定；不引入 Tailwind、d3、framer-motion、路由库。
- 所有颜色、间距、圆角、字号只能用 `src/styles/tokens.css` 里的变量；禁止硬编码色值。
- 活动颜色只能从 rebuild-plan 4.3 的 8 色板中取。
- 禁止渐变光斑背景、禁止 `!important`。
- 所有用户可见文案通过 i18next key，`zh-CN` 和 `en` 两个文件同步更新。
- Rust command 是数据唯一入口；前端不直接碰 SQLite。
- 新增 npm / crate 依赖要在 PR 说明里写清为什么不能自己写。
- `legacy/` 是旧 Electron 代码，只读，不修改、不构建、不导入。

## 工作方式

- 版本号三端一致，2026-10-16 起为 2.0.0（内测）：桌面在 `package.json` / `src-tauri/tauri.conf.json` / `src-tauri/Cargo.toml`，Apple 在 `apple/Config/Base.xcconfig`（`MARKETING_VERSION`，`CURRENT_PROJECT_VERSION` 跟着加）。手表活动列表最底下显示「Hope 2.0.0」，只显示版本不显示构建号。**每次往真机装新包前把补丁号加 1**（2.0.0 → 2.0.1 → …），用户靠这个判断手表有没有更新到。

- 严格按 rebuild-plan 第 7 节的阶段顺序推进；一次只做一个阶段，每阶段结束 app 必须能跑并给用户演示。
- 做 UI 前先想"苹果原生 app 会怎么做"，不确定时选更克制的方案。
- 中文沟通，代码与注释用英文。

## 已经定死、不要重新讨论的决定

- 桌面 = Tauri 2；手机 + 手表 = 原生 Swift；云端 = Supabase。
- 数据模型（rebuild-plan 3.1）含 UUID 主键和同步三列，从第 1 阶段建表时就要有。
- 暂停 = 结束 session，恢复 = 新 session + `continues_id`，不另加暂停表。
- 子活动用 `activity.parent_id` 实现，只有一层，颜色随父（rebuild-plan 第 10 节 C）。时区枚举、activity_colors 表已删除。
- 睡眠不是 activity；每天实际起床 / 睡觉存 `day` 表。
- 周期计划到点生成真实 session，id 用确定性 UUID v5。
- 任何会丢数据的操作都必须有确认对话框。

## 遇到以下情况停下来问用户，不要自行决定

- 想增加或替换任何依赖。
- 想改数据模型、设计 token、色板。
- rebuild-plan 没写到、且会影响后续阶段的设计选择。

## 当前状态

- 阶段 1–6、6.5、6.6 已完成：桌面端功能齐全（Today / 本周 / 本月 / 日程 / 活动与子活动 / 记录编辑 / 起床睡觉 / 日记 / 设置与主题 / Overlay / JSON 导入导出），macOS dmg 与 Windows nsis 由 `.github/workflows/release.yml` 出包。
- 不做旧库直接导入；数据进出口只有 rebuild-plan 3.3 的 JSON 格式。
- 欠账：
  - Windows 版 2026-10-13 已在真机（Windows 11）上用 `npm run tauri dev` 跑通，并对真实 Supabase 登录、同步成功。Windows 开发要 Node ≥ 20.19（Vite 8；旧版 npm 会静默跳过 rolldown 的原生绑定）。Windows 上 `cargo test` 的测试 exe 没有 Tauri 嵌给主程序的 comctl32 v6 清单，会以 STATUS_ENTRYPOINT_NOT_FOUND（TaskDialogIndirect）退出：在 `target/debug/deps/hope_lib-<hash>.exe` 旁放一个声明 Microsoft.Windows.Common-Controls 6.0.0.0 的 `.exe.manifest`、更新 exe 的修改时间后直接运行它即可（CI 只在 macOS 跑 cargo test）。Overlay 在 Windows 上的逐卡模糊已做（每卡一个 Acrylic 小窗口）。**从 Claude 桌面版（MSIX 包）的 shell 里跑安装器或 app 时，对 AppData 的写入会被重定向到 `AppData\Local\Packages\Claude_*\LocalCache`**：安装、开始菜单快捷方式、app 数据库都只存在于那个虚拟视图里，系统看不到；真正安装 / 启动要用 WMI `Win32_Process.Create` 在包外起进程，或让用户自己双击。任务栏图标：Tauri 只设窗口小图标，`src-tauri/src/taskbar_icon.rs` 用 exe 内嵌图标补上大图标。
  - 安装包未签名、未公证（需要 Apple Developer ID）。
  - 版本号已定为 2.0.0（仓库里旧 Electron 时代的 `v1.0.0` tag 保留）；推 `v2.0.0` tag 才会触发出包。
  - 本机 dmg：2026-10-03 复查，`npm run tauri build -- --target aarch64-apple-darwin` 连跑两次 dmg 都成功，问题不在仓库配置。之前那次失败留下的 `bundle/macos/rw.39387.Hope_0.1.0_aarch64.dmg` 显示脚本已走完 Finder AppleScript 和 SetFile，卡在最后的 `hdiutil detach`（卷被占用 EBUSY，重试 3 次后退出 16，镜像一直挂着到 20:06 才被卸下）——是偶发的环境问题（Finder / Spotlight / 安全扫描仍占着刚生成的卷）。再遇到时：关掉 Finder 里打开的 `dmg.*` 窗口，`hdiutil info` 查残留镜像并 `hdiutil detach`，删掉 `bundle/macos/rw.*.dmg` 后重跑。注意别单独用 `--bundles dmg`：它构建完会删掉 `bundle/macos/Hope.app`。
- 阶段 7（同步层，rebuild-plan 第 12 节）：已对真实 Supabase 项目跑通（`.env` 已配置，桌面与手表都在同步）。注意：**本地加列后必须同步在 Supabase SQL Editor 里执行 `supabase/schema.sql` 里的 `alter table … add column if not exists`**。2026-10-14 实测：云端缺列时 PostgREST 对 upsert 直接返回 HTTP 400 `PGRST204 Could not find the '…' column`，桌面端会每 5 秒重试、同步一直失败，直到列加上（阶段 12 的 `break_ack_ms` 就撞上了）。
- 阶段 8、9（`apple/`，说明见 `apple/README.md`）：一个 Xcode 工程 `Hope.xcodeproj`（iOS 18+ / watchOS 11+）+ 本地 Swift 包 `HopeCore`（SwiftData 存储、计时规则、同步协议、表盘快照的 Swift 移植，`swift test` 45 个测试）。iOS 与 Watch 有 App 图标（由桌面图标 `sips` 裁切）。
  - iPhone 是最小版：今天总时长 + 今日记录 + 开始/暂停/继续/结束 + 两级活动选择 + 账号；承载 Watch app，并通过 WatchConnectivity 把**另一个独立的登录会话**交给手表（refresh token 会轮换，不能共用）。
  - Watch：活动列表（今日总时长、两级）、计时页（大号跳秒、暂停/结束，暂停后继续/结束），直连 Supabase，无账号也能纯本地用。
  - 表盘复杂功能（`apple/WatchWidget/`，WidgetKit 扩展，圆形 / 矩形 / 单行 / 角落）：计时中显示活动名 + 活动色 + 系统自走计时（整条暂停链、不含暂停）；暂停显示冻结时间；空闲显示 Hope 圆环 + 今日总时长；点按打开 Watch app。数据走 App Group `group.io.github.dan9574.hope` 里的 `widget-snapshot.json`，由 Watch app 在每次本地写入 / 拉取变更后重写；扩展不打开 SwiftData。免费个人团队可以签 App Group（已验证）。开关 `HOPE_COMPLICATION_LIVE_DATA`（`Config/Base.xcconfig`），设 `NO` 即退回只开 app 的启动器版。SwiftData 库固定在 app 自己的容器（`groupContainer: .none`），否则加了 App Group 后库会被挪进共享容器、旧数据看起来丢失。
  - 已验证：`swift test`；对已注册的 iPhone 签名编译成功（含 Watch app 与复杂功能扩展，App Group 已进描述文件）；iOS 与 watchOS 模拟器上开始 / 暂停 / 继续 / 结束 / 切换活动、中文界面；watchOS 27 模拟器上快照文件内容正确，复杂功能各视图在 app 内渲染截图正常。
  - 真机安装：2026-10-14 用 `xcrun devicectl device install app` 把签名的 `Hope.app`（含 Watch app）装到 iPhone 16 Pro 并启动，界面正常；描述文件一年期（到 2027-10-12）。手表端装到没有要在 iPhone 的 Watch app 里看，Mac 对手表的 devicectl 隧道会超时。
  - **未验证**：复杂功能真正放到表盘上的样子（模拟器无法驱动表盘编辑）及着色表盘下的效果；对真实 Supabase 的登录、同步、手机→手表交接（模拟器上没有建账号）；手表上文本输入（模拟器无法驱动）。
  - 偏离文档：没有 Live Activity、底部 Tab；"今天"按自然日而不是起床/睡觉日；Apple 端不生成计划自动计入的记录；暂停状态只在本机（与桌面一致）。
- 阶段 10（课表导入与课表时间区分，rebuild-plan 第 13 节）：已完成桌面端与 Apple 模型层。迁移 0004 加了 `activity.kind`（`'schedule'` = 课表组）和 `plan.skip_dates`（假期）；日程页「导入 .ics…」→ 预览 Sheet（开始 / 结束范围、可改课名）→ `schedule_import`（UUID v5 确定性 id，重复导入即更新；开始日期早于今天时可勾选「补记已过去的课」，走 autolog 的允许过去模式，幂等）；课表组与课程子活动创建即归档（rebuild-plan 13.7：不出现在开始计时 / 托盘里，记录照常统计；活动编辑器没有「作为课表组」开关，课表组只由导入器管理）；设置「总时长计入课表」默认关，Today / 本周 / 本月 / Overlay / Apple 今日总时长都排除课表组。ICS 解析器 `src/lib/ics.ts` 无依赖，`npm run test:ics` 用 Node 自带 test runner；`src-tauri/src/db/fixtures/fall2026-import.json` 是用它解析真实课表得到的导入输入，Rust 有端到端测试。Supabase 的两列已写进 `supabase/schema.sql`（含 `add column if not exists`），需要在 SQL Editor 里执行后再把本地的课表组和带假期的计划重新推送。
- 阶段 11（离开提醒，rebuild-plan 第 14 节）：2026-10-13 代码写完，桌面端 / Rust / 前端部分已在 Windows 上测过（`kind = 'exercise'`、编辑器开关、80 个 Rust 测试）。Apple 端 `apple/HopeCore/Sources/HopeCore/AwayReminder.swift`（规则 + 6 个测试）与 `apple/iOS/AwayMonitor.swift`（CLMonitor 围栏 + 通知三个按钮）2026-10-14 已在 Mac 上验证：`swift test` 54 个测试全过，`xcodebuild`（Hope scheme，签名，含 Watch app）无错误无警告，定位用途说明已进 Info.plist，新文案 zh-Hans 齐全。真机：2026-10-14 打开开关即崩、之后每次启动都崩，原因是 `CLMonitor` 名字 `"hope.away"` 带点（只允许字母数字），已改成 `"HopeAway"`。**未真机验证**（14.4 第 3 条）：围栏事件后台唤醒 app 后 `requestLocation()` 能否在系统给的几秒内拿到定位、通知三个按钮在后台的处理、Always 权限升级提示。
- 阶段 12（休息提醒，rebuild-plan 第 15 节）：2026-10-14 三端代码写完。迁移 0005 加了 `session.break_ack_ms`（同步列，JSON `hope/1` 可选字段，`supabase/schema.sql` 已含 `add column if not exists`，**要在 SQL Editor 里执行**）。规则是纯函数：Rust `src-tauri/src/db/break_reminder.rs`、Swift `HopeCore/BreakReminder.swift`，两边同一组用例。手表 / iPhone 共用 `apple/Shared/BreakScheduler.swift`（本地通知预排 4 次，按钮「暂停」「再来一会儿」）和 `NotificationRouter.swift`（唯一的通知代理，离开提醒也改走它）；手表通过 WatchConnectivity 向 iPhone 声明已排的提醒，iPhone 去重并晚 2 分钟兜底。桌面端新增依赖 `tauri-plugin-notification`，`src-tauri/src/break_reminder.rs` 每 15 秒轮询、晚 1 分钟弹系统通知（无按钮、不能写 ack），文案由前端 `break_set_strings` 送入；设置 → 通用「休息提醒」默认开，Apple 端开关默认关（要通知权限）。已验证：`cargo test` 89 个、`swift test` 60 个、`tsc`、iOS 签名编译与模拟器编译（含 Watch app）；桌面 `tauri dev` 能启动；iPhone 模拟器上开始计时后系统日志出现 4 条 `Adding notification request`、暂停后无待弹（模拟器没授权通知，所以 add 带 error；SwiftUI Toggle 在模拟器里不接受合成点按，开关是写 `break.enabled` 的 UserDefaults 打开的）。2026-10-14 晚真机 18 小时（手表开的计时）三端一声没响：手机从未打开过 app（用户习惯只用手表），所以手机既无锚点也无认领；手表端查出两处 bug——重排竞态会删掉刚排好的通知、认领不看 add 是否成功。2026-10-15 修法：重排串行、只认领成功的、手表每次计时变化发 `TimerBeacon` 让 iOS 后台拉起手机 app 去同步 + 锚点、围栏事件直接提示不等定位、`beginBackgroundTask`、`os.Logger` 日志、开关下显示「下次提醒 HH:MM」状态行、手表开关默认开。**未验证**：以上修复在真机上的效果（到点弹出、信标后台投递、围栏唤醒）、手表通知按钮在后台的处理、桌面通知在 macOS 的首次权限提示。
- 发布方向（2026-11-06 定，rebuild-plan 第 18 节）：先美国版（App Store 只勾美国，欧洲先不上），再做国内版（大陆自架 Supabase，同一份代码换构建配置）。协作者不再参与，所有 issue 都由用户自己（配合 Claude）做；`docs/issues-draft.md` 里的认领制和「ipo / Jerry 在做」已过时。
- 账号体系（rebuild-plan 第 17 节）：2026-11-06 三端代码写完——注册用邮件 6 位验证码（`/auth/v1/verify`）、忘记密码（`/auth/v1/recover` → verify → `PUT /auth/v1/user`）、删除账号（`supabase/schema.sql` 的 `delete_account()` + 五张表 `user_id` → `auth.users` 的 `on delete cascade` 外键）。桌面 `src/views/settings/SyncSettings.tsx` 四种未登录状态 + 「删除账号…」；iPhone `AccountView.swift` 同样；错误码新增 `invalid_code`。已验证：`cargo test` 92 个（含本地假 GoTrue 的请求形状测试）、`swift test` 72 个、`tsc`。**未验证**：对真实 Supabase 的注册 → 收码 → 登录 / 找回 / 删号（要先做 17.2 的后台设置：模板改 `{{ .Token }}`、SMTP、最短密码 8，并重跑 `schema.sql`）。12.8（拉取合并成一个 RPC、后台放慢）只有草案，未实现。
- 下一步：Supabase 后台按 17.2 配好、重跑 `schema.sql`（同时补上阶段 10 的两列和阶段 12 的 `session.break_ack_ms`）并实测账号三流程；确认 12.8 草案后实现；iPhone 视觉方向定下后写第 16 节。把阶段 8/9 装到真机、把 Hope 加到表盘，实测手机→手表交接与三端收敛。Realtime（7b）先不做。
