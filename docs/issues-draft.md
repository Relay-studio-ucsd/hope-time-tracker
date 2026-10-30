# Apple Store 发布：issue 草稿（按人分三类）

- **A 类**：ipo（@IpoKlay）。**B 类**：Jerry（@yren3861）。**C 类**：Daniel（@dan9574）要做、或要给反馈的事。
- 仓库：`Relay-studio-ucsd/hope-time-tracker`，issue #1–#18；main 受保护，改动走分支 + PR。
- 两条线前四条都是手机页面，**只要 Mac + Xcode 模拟器**，不需要 iPhone 或 Apple Watch。
- 手表和离开提醒的真机任务放在两条线最后，谁有设备谁做；没有就跳过交给另一人。
- 顺序排过，同一时间两人不改同一个文件。前一条合并再开下一条。**A1 与 B1 今天就能开工。**

每条 issue 共同的验收标准（写进 issue 模板，不逐条重复）：
1. PR 里贴模拟器截图 / 录屏（真机任务贴真机）。
2. 改了 `HopeCore` 必须 `cd apple/HopeCore && swift test` 全绿。
3. 新文案进 `apple/Shared/Localizable.xcstrings`，中英两份。
4. 不加新依赖；要加先在 issue 里问。

环境：`apple/README.md` 的「Run in the simulator」一节；不配 `.env` 也能跑（本地模式）。

---

# A 类：成员 A

## A1. iPhone 导航骨架：四个 Tab（练手）

目标：把手机从单页改成四个 Tab：**今天 / 统计 / 活动 / 设置**。
- `TabView` + SF Symbols 图标。
- 现有 `AccountView` 整个搬进「设置」Tab，作为其中「账号」分组；功能不变。
- 现有 `TodayView` 作为「今天」Tab，不改。
- 「统计」「活动」先放一行占位文字。

涉及：`apple/iOS/HopeApp.swift`；新建 `apple/iOS/RootTabView.swift`、`apple/iOS/SettingsView.swift`。
验收：四个 Tab 可切换；原有登录、计时全部可用；中英文。
依赖：无。

## A2. 活动页（管理活动：新建、改名、换色、子活动、归档）

"活动"= 计时的类别（工作、阅读、线性代数……）。桌面端有「活动」页管理它们，手机现在没有，只能在选活动的弹窗里新建顶层活动。这条就是把桌面的「活动」页搬到手机「活动」Tab。
- 树形列表：顶层活动 + 可折叠子活动；色点；运动类、课表组小标签；归档的折到底部一组。
- 新建 / 改名 / 改色（8 色板）/ 加子活动（只一层，颜色随父）/ 归档 / 运动类开关。
- 课表组只读（与桌面 13.7 一致）。

涉及：新建 `apple/iOS/ActivitiesView.swift`、`ActivityEditor.swift`；`HopeCore/Timer.swift` 已有 `createActivity`，补 archive / setKind / setColor。
依赖：A1。颜色用 B1 的主题 token（B1 先合并）。

## A3. 今天页

- 顶部圆环：今日总时长，按活动色分段，排除课表组（`todaySummary`，与桌面同规则）。
- 计时卡：开始 / 暂停 / 继续 / 结束 / 换活动（现有逻辑搬过来）。
- 今日记录列表：色点、活动名、起止、时长、等宽数字。
- "今天"按起床 / 睡觉日（`day` 表），与桌面一致。

涉及：`apple/iOS/TodayView.swift`、`apple/Shared/Components.swift`。
依赖：A2。

## A4. 记录编辑

- 今日列表左滑删除；点开改起止时间与备注；右上角「补录」。
- 三种都要确认对话框。
- 用 `HopeCore/Editing.swift` 已有的 `editSession` / `addSession` / `deleteSession`。

涉及：`apple/iOS/TodayView.swift`、新建 `SessionEditor.swift`。
依赖：A3。

## A5. 表盘复杂功能真机验证与修正（需要 Apple Watch）

- 四种家族各放到一个表盘上；着色表盘下检查对比度。
- 计时中 / 暂停 / 空闲三态各截图；午夜归零。
- 修发现的问题。

涉及：`apple/WatchWidget/`、`apple/Watch/ComplicationPublisher.swift`。
依赖：A4。

## A6. 手表界面打磨（需要 Apple Watch）

- 活动列表行：色点、名字、今日时长右对齐、等宽数字。
- 计时页：大号时间、活动色强调、暂停态变灰；开始 / 暂停 / 结束各一个触感（`WKInterfaceDevice.play`）。
- Smart Stack 相关性（计时中置顶）。

涉及：`apple/Watch/WatchRootView.swift`、`apple/WatchWidget/`。
依赖：A5。

（可选，先不建）A7 Live Activity / 灵动岛；A8 主屏小组件。

---

# B 类：成员 B

## B1. 主题：三套配色（练手）

目标：三套风格明显不同的完整配色，用户在设置里选。
- `apple/HopeCore/Sources/HopeCore/Theme.swift`：`enum Theme { case paper, night, forest }`（名字可改），每套定义 7 个颜色：背景、卡片、分隔线、正文、次要文字、强调色、强调色上的文字。
- 通过 `@Environment` 注入；把现有页面（今天页、账号页、活动选择弹窗）换成主题 token，不写死色值。
- 选择器做成独立的 `ThemePicker.swift`；A1 没合并前先放在现有账号页最上面一组，A1 合并后搬进「设置」Tab。`@AppStorage("theme")` 本机存，不同步。
- 边界：活动的 8 色板（`Palette.swift`）不动；禁止渐变背景；间距、圆角、字体不随主题变。

验收：**先在 issue 里贴三张截图**（今天页 × 三套主题）给 C 拍板色值，再合并。
依赖：无。

## B2. 统计页

- 分段控件：本周 / 本月；上一段 / 下一段。
- 每活动一行：色点、名字、时长、占比条（不用图表库）；点进看该区间的记录。
- 排除课表组，受「总时长计入课表」设置影响。

涉及：新建 `apple/iOS/StatsView.swift`；`HopeCore/Timer.swift` 的 `summary(from:to:)`。
依赖：B1、A1（挂到「统计」Tab）。

## B3. 设置页补全

- 分组：账号 / 同步状态 / Apple Watch / 离开提醒 / 主题 / 总时长计入课表 / 数据 / 关于。
- 数据：JSON 导出走分享表单，导入走文件选择器，格式 `hope/1`（rebuild-plan 3.3），导入前确认。
- 关于：版本号、隐私政策链接（链接由 C3 提供）。

涉及：`apple/iOS/SettingsView.swift`；`HopeCore` 加 JSON 导入导出。
依赖：B2。

## B4. 账号客户端：验证码注册、忘记密码、删除账号（桌面 + Apple）

- GoTrue 请求：`/auth/v1/signup` → `/auth/v1/verify`（type=signup，6 位码）；`/auth/v1/recover` → `/auth/v1/verify`（type=recovery）→ `PUT /auth/v1/user` 改密码；`POST /rest/v1/rpc/delete_account`。
- Rust：`src-tauri/src/sync/http.rs` 加三个请求；Settings → Sync 加"输入验证码""忘记密码""删除账号（确认框）"；i18n `zh-CN` / `en`。
- Swift：`apple/HopeCore/Sources/HopeCore/Sync/Supabase.swift` 同样三个请求；iPhone 设置页同样三个入口。
- 两端假服务端测试补这三种请求的形状。
- 可以先对着假服务端写完，等 C2、C4 就绪再联调。

验收：桌面与 iPhone 各走一遍注册、找回、删号；`cargo test`、`swift test`。
依赖：B3；联调要 C2、C4。

## B5. 离开提醒真机验证与修正（需要 iPhone）

- 走出 300 米收到通知，**通知要带震动**（`UNNotificationSound.default`）；三个按钮各一次；30 分钟勿扰到期再提醒。
- 修发现的问题；参数要调就改 `HopeCore/AwayReminder.swift` 常量并补测试。

涉及：`apple/iOS/AwayMonitor.swift`、`apple/HopeCore/Sources/HopeCore/AwayReminder.swift`。
依赖：B4。

## B6. 手表 bug 收集与修复（需要 Apple Watch）

- 带表用三天，把所有不对劲的现象记成勾选清单，逐个修，每修一个一个 commit。
- C1 会先列已知现象；自己发现的也加进来（计时状态不同步？复杂功能不刷新？启动慢？登录掉？）。

涉及：`apple/Watch/`、`apple/WatchWidget/`。
验收：清单全部勾掉或写明原因；真机录屏。
依赖：B5。

---

# C 类：项目所有者（要做的事、要给的反馈）

## C1. 列出手表的已知问题（反馈，不急）

写进 B6：什么时候、做了什么、看到什么。B6 开工前给到即可。

## C2. Supabase 后台：域名、SMTP、验证码模板、限流

- 买域名；Resend 或 Brevo 配发件域（DNS 记录）；Supabase → Auth → SMTP 填入。
- 邮件模板 Confirm signup / Reset password 改为显示 `{{ .Token }}`（6 位码）。
- Auth 设置：最短密码 8；验证码有效期 10 分钟；重发间隔 60 秒；每小时发信上限。
- 顺手：SQL Editor 跑 `supabase/schema.sql` 末尾的 `add column if not exists`（阶段 10 的 `kind` / `skip_dates` 和阶段 12 的 `session.break_ack_ms`），重推本地课表组与带假期的计划。

验收：新邮箱走一遍"注册 → 收到 6 位码"；写进 `supabase/README.md`。B4 联调要它。

## C3. 文档：rebuild-plan 第 16、17 节、4.3.1 修订、CLAUDE.md 当前状态

- 第 16 节「iPhone v1」（第 15 节已是阶段 12 休息提醒）：四个 Tab 与每页内容；今天按起床 / 睡觉日；不做日程页；Live Activity 与小组件延后。
- 4.3.1：主题改为三套完整配色，活动 8 色不变。
- 第 17 节「账号体系」：6 位验证码、忘记密码、删除账号、最短密码、限流。
- CLAUDE.md「当前状态」加一段：App Store 发布计划见 `docs/issues-draft.md`，已知手表问题归 B5 / B6。
- 隐私政策页放到新域名，链接给 B3。

（可以让 Claude 写，你过目。）

## C4. 删号 RPC

`supabase/schema.sql` 加 `delete_account()`：`security definer`，删当前 `auth.uid()` 在五张表的行，再删 `auth.users` 该行；`grant execute to authenticated`。SQL Editor 执行，测试账号验证。B4 联调要它。

## C5. 给 B1 拍板主题色（反馈）

B1 贴出三张截图后，选定或要求改色值。

## C6. 发布准备（与 B 一起）

- App Privacy 声明（邮箱、位置、使用数据）；定位用途文案中英。
- 审核演示账号；App Store Connect 不勾中国大陆。
- 版本号已是 2.0.0（`apple/Config/Base.xcconfig`，build 号 `CURRENT_PROJECT_VERSION` 每次上传 +1）；发版时推 `v2.0.0` tag 触发桌面出包。
- TestFlight 上传；iPhone 与 Watch 截图。

依赖：B3、B4。
