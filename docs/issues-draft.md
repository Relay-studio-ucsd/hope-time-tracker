# App Store 发布：任务链（按依赖切，不按人切）

- 仓库：`Relay-studio-ucsd/hope-time-tracker`；main 受保护，改动走分支 + PR，CODEOWNERS 把审核路由给 @dan9574。
- 原则：链按依赖切，不按人切；人认领链，不预分配；谁快谁多拿。追求总产出，不追求人人有事做。
- 链的优先级就是下面的顺序：A 今天页 → B 活动页 → C 统计页 → D 设置与主题 → E 账号 → F 发布 → G 真机。
- GitHub 上标签 = 链，issue 编号不变，标题前缀是链内序号。

规则：
1. 一条链一个人从头做到尾；做完回来按优先级认领下一条。
2. 一人同时只认领一条；认领 = 把自己 assign 到那条 issue。没有 assignee 的就是没人在做。
3. 链内严格顺序，链间不等。唯一的跨链等待：F 等 D1、E3；C1 的「点一天跳转」等 A1。
4. 一条链 3 天没有 PR（草稿也算）就是停滞：谁空谁接走，原认领人换下一条。

现在：A1 由 Claude 做（Daniel 过目）；ipo 在 B1；Jerry 在 D1；E1 / E2 / D3 / F1 / G1 是 Daniel 自己的。

每条 issue 共同的验收标准（写进 issue 模板，不逐条重复）：
1. PR 里贴模拟器截图 / 录屏（真机任务贴真机）。
2. 改了 `HopeCore` 必须 `cd apple/HopeCore && swift test` 全绿。
3. 新文案进 `apple/Shared/Localizable.xcstrings`，中英两份。
4. 不加新依赖；要加先在 issue 里问。

环境：`apple/README.md` 的「Run in the simulator」一节；不配 `.env` 也能跑（本地模式）。

---

# A 链：今天页

## A1. 手机看过去的天的底层：HopeCore 起床 / 睡觉日规则 + Tab 选中状态（#22）

桌面已能翻看过去的天（PR #21）。手机端 A2 / A3 / C1 都要用同一套规则和同一个「正在看的那天」，先把这两块铺好，三条 issue 只管界面。

- HopeCore：把桌面 `src/lib/useToday.ts` 的规则移植成纯函数并补 `swift test`：凌晨归属（默认睡觉与次日默认起床的中点之前仍算前一天）；一天的范围 = 前一天 `sleep_ms` → 当天 `sleep_ms`，今天没睡算到 now，过去的天没按过睡觉按默认睡觉时间收尾；`daySummary(on:now:)` 取代按自然日的 `todaySummary`。
- `RootTabView`：`TabView(selection:)`；`AppModel` 里加「正在看的那天」（nil = 今天）和 `openDay(_:)`，统计页调一下就能跳到今天页的某天；再点「今天」Tab 回到今天。

涉及：`HopeCore/Timer.swift`（或新文件 `DayRules.swift`）、`apple/iOS/RootTabView.swift`、`apple/iOS/HopeApp.swift`。
依赖：无；A2 和 C1 的跳转依赖它。（可以让 Claude 写，你过目。）

## A2. 今天页（#3）

- 顶部圆环：今日总时长，按活动色分段，排除课表组（`todaySummary`，与桌面同规则）。
- 计时卡：开始 / 暂停 / 继续 / 结束 / 换活动（现有逻辑搬过来）。
- 今日记录列表：色点、活动名、起止、时长、等宽数字。
- "今天"按起床 / 睡觉日（`day` 表），与桌面一致：规则由 A1 放进 HopeCore，这里只调用 `daySummary(on:)`，不要自己再算。
- **能翻到之前的天**（对照桌面 PR #21）：导航栏 ‹ ›，一次一天，不能翻到未来；不在今天时标题改成相对日期（昨天 / 前天 / 3 天前，`Date.RelativeFormatStyle`），并出现「回到今天」；再点一次「今天」Tab 也回到今天。
- 过去的天只看那天的记录：隐藏计时卡，空状态写「这天没有记录」。左右滑切天是加分项。

涉及：`apple/iOS/TodayView.swift`、`apple/Shared/Components.swift`；用 A1 的「正在看的那天」。
依赖：A1。

## A3. 记录编辑（#4）

- 今日列表左滑删除；点开改起止时间与备注；右上角「补录」。
- 三种都要确认对话框。
- 用 `HopeCore/Editing.swift` 已有的 `editSession` / `addSession` / `deleteSession`。
- 改 / 删 / 补录都作用在 A2 里正在看的那天，不只是今天；补录的默认日期就是那天。编辑器要有日期选择，能把记录挪到别的天（桌面编辑器已有）。周三记错、周五才发现，就是这条要解决的场景。

涉及：`apple/iOS/TodayView.swift`、新建 `SessionEditor.swift`。
依赖：A2。

# B 链：活动页

## B1. 活动页（管理活动：新建、改名、换色、子活动、归档）（#2）

"活动"= 计时的类别（工作、阅读、线性代数……）。桌面端有「活动」页管理它们，手机现在没有，只能在选活动的弹窗里新建顶层活动。这条就是把桌面的「活动」页搬到手机「活动」Tab。
- 树形列表：顶层活动 + 可折叠子活动；色点；运动类、课表组小标签；归档的折到底部一组。
- 新建 / 改名 / 改色（8 色板）/ 加子活动（只一层，颜色随父）/ 归档 / 运动类开关。
- 课表组只读（与桌面 13.7 一致）。

涉及：新建 `apple/iOS/ActivitiesView.swift`、`ActivityEditor.swift`；`HopeCore/Timer.swift` 已有 `createActivity`，补 archive / setKind / setColor。
依赖：无。颜色先用 SwiftUI 语义色（`.primary` / `.secondary` / `.tint` / `Color(.systemBackground)`），主题 D2 之后统一换成 token。

# C 链：统计页

## C1. 统计页（#8）

- 分段控件：本周 / 本月；上一段 / 下一段。
- 每活动一行：色点、名字、时长、占比条（不用图表库）；点进看该区间的记录。
- 排除课表组，受「总时长计入课表」设置影响。
- 本周 / 本月里要有按天的元素可以点：本周一天一列，本月一个月历格子（日期 + 当天总时长，像桌面本月页）。点一下切到「今天」Tab 并定位到那天（用 A1 的选中状态）；未来的天不响应。对照桌面 PR #21。

涉及：新建 `apple/iOS/StatsView.swift`；`HopeCore/Timer.swift` 的 `summary(from:to:)`；跳转用 A1 的 `openDay`。
依赖：无；点一天跳转那一条等 A1 合并后补。颜色先用系统语义色，主题 D2 之后统一换。

# D 链：设置与主题

## D1. 设置页补全（#9）

- 分组：账号 / 同步状态 / Apple Watch / 离开提醒 / 主题 / 总时长计入课表 / 数据 / 关于。
- 数据：JSON 导出走分享表单，导入走文件选择器，格式 `hope/1`（rebuild-plan 3.3），导入前确认。
- 关于：版本号、隐私政策链接（链接由 F1 提供）。

涉及：`apple/iOS/SettingsView.swift`；`HopeCore` 加 JSON 导入导出。
依赖：无。

## D2. 主题：三套配色（#7）

目标：三套风格明显不同的完整配色，用户在设置里选。
- `apple/HopeCore/Sources/HopeCore/Theme.swift`：`enum Theme { case paper, night, forest }`（名字可改），每套定义 7 个颜色：背景、卡片、分隔线、正文、次要文字、强调色、强调色上的文字。
- 通过 `@Environment` 注入；把现有页面（今天页、账号页、活动选择弹窗）换成主题 token，不写死色值。
- 选择器做成独立的 `ThemePicker.swift`；放进设置页的「主题」分组（D1 之后）。`@AppStorage("theme")` 本机存，不同步。
- 边界：活动的 8 色板（`Palette.swift`）不动；禁止渐变背景；间距、圆角、字体不随主题变。

验收：**先在 issue 里贴三张截图**（今天页 × 三套主题）给 D3 拍板色值，再合并。
依赖：D1（选择器放进设置页；把那时已有的页面一次换成 token）。

## D3. 拍板主题色（反馈）（#17）

D2 贴出三张截图后，选定或要求改色值。

# E 链：账号

## E1. Supabase 后台：域名、SMTP、验证码模板、限流（#14）

- 买域名；Resend 或 Brevo 配发件域（DNS 记录）；Supabase → Auth → SMTP 填入。
- 邮件模板 Confirm signup / Reset password 改为显示 `{{ .Token }}`（6 位码）。
- Auth 设置：最短密码 8；验证码有效期 10 分钟；重发间隔 60 秒；每小时发信上限。
- 顺手：SQL Editor 跑 `supabase/schema.sql` 末尾的 `add column if not exists`（阶段 10 的 `kind` / `skip_dates` 和阶段 12 的 `session.break_ack_ms`），重推本地课表组与带假期的计划。

验收：新邮箱走一遍"注册 → 收到 6 位码"；写进 `supabase/README.md`。E3 联调要它。

## E2. 删号 RPC（#16）

`supabase/schema.sql` 加 `delete_account()`：`security definer`，删当前 `auth.uid()` 在五张表的行，再删 `auth.users` 该行；`grant execute to authenticated`。SQL Editor 执行，测试账号验证。E3 联调要它。

## E3. 账号客户端：验证码注册、忘记密码、删除账号（桌面 + Apple）（#10）

- GoTrue 请求：`/auth/v1/signup` → `/auth/v1/verify`（type=signup，6 位码）；`/auth/v1/recover` → `/auth/v1/verify`（type=recovery）→ `PUT /auth/v1/user` 改密码；`POST /rest/v1/rpc/delete_account`。
- Rust：`src-tauri/src/sync/http.rs` 加三个请求；Settings → Sync 加"输入验证码""忘记密码""删除账号（确认框）"；i18n `zh-CN` / `en`。
- Swift：`apple/HopeCore/Sources/HopeCore/Sync/Supabase.swift` 同样三个请求；iPhone 设置页同样三个入口。
- 两端假服务端测试补这三种请求的形状。
- 可以先对着假服务端写完，等 E1、E2 就绪再联调。

验收：桌面与 iPhone 各走一遍注册、找回、删号；`cargo test`、`swift test`。
依赖：无，可先对假服务端写完；联调要 E1、E2。设置页的入口若 D1 还没合并，先放在现有账号页。

# F 链：发布

## F1. 文档：rebuild-plan 第 16、17 节、4.3.1 修订、CLAUDE.md 当前状态（#15）

- 第 16 节「iPhone v1」（第 15 节已是阶段 12 休息提醒）：四个 Tab 与每页内容；今天按起床 / 睡觉日；今天页可翻看过去的天、本周 / 本月点一天直达（桌面 PR #21 为参考实现，规则见 A1）；不做日程页；Live Activity 与小组件延后。
- 4.3.1：主题改为三套完整配色，活动 8 色不变。
- 第 17 节「账号体系」：6 位验证码、忘记密码、删除账号、最短密码、限流。
- CLAUDE.md「当前状态」加一段：App Store 发布计划见 `docs/issues-draft.md`，已知手表问题归 G2 / G5。
- 隐私政策页放到新域名，链接给 D1。

（可以让 Claude 写，你过目。）

## F2. 发布准备（#18）

- App Privacy 声明（邮箱、位置、使用数据）；定位用途文案中英。
- 审核演示账号；App Store Connect 不勾中国大陆。
- 版本号已是 2.0.0（`apple/Config/Base.xcconfig`，build 号 `CURRENT_PROJECT_VERSION` 每次上传 +1）；发版时推 `v2.0.0` tag 触发桌面出包。
- TestFlight 上传；iPhone 与 Watch 截图。

依赖：D1、E3。

# G 链：真机

## G1. 列出手表的已知问题（反馈，不急）（#13）

写进 G2：什么时候、做了什么、看到什么。G2 开工前给到即可。

## G2. 手表 bug 收集与修复（需要 Apple Watch）（#12）

- 带表用三天，把所有不对劲的现象记成勾选清单，逐个修，每修一个一个 commit。
- G1 会先列已知现象；自己发现的也加进来（计时状态不同步？复杂功能不刷新？启动慢？登录掉？）。

涉及：`apple/Watch/`、`apple/WatchWidget/`。
验收：清单全部勾掉或写明原因；真机录屏。
依赖：G1 给到清单即可（要 Apple Watch）。

## G3. 表盘复杂功能真机验证与修正（需要 Apple Watch）（#5）

- 四种家族各放到一个表盘上；着色表盘下检查对比度。
- 计时中 / 暂停 / 空闲三态各截图；午夜归零。
- 修发现的问题。

涉及：`apple/WatchWidget/`、`apple/Watch/ComplicationPublisher.swift`。
依赖：无（要 Apple Watch）。

## G4. 手表界面打磨（需要 Apple Watch）（#6）

- 活动列表行：色点、名字、今日时长右对齐、等宽数字。
- 计时页：大号时间、活动色强调、暂停态变灰；开始 / 暂停 / 结束各一个触感（`WKInterfaceDevice.play`）。
- Smart Stack 相关性（计时中置顶）。

涉及：`apple/Watch/WatchRootView.swift`、`apple/WatchWidget/`。
依赖：G3。

（可选，先不建）Live Activity / 灵动岛；主屏小组件。

## G5. 离开提醒真机验证与修正（需要 iPhone）（#11）

- 走出 300 米收到通知，**通知要带震动**（`UNNotificationSound.default`）；三个按钮各一次；30 分钟勿扰到期再提醒。
- 修发现的问题；参数要调就改 `HopeCore/AwayReminder.swift` 常量并补测试。

涉及：`apple/iOS/AwayMonitor.swift`、`apple/HopeCore/Sources/HopeCore/AwayReminder.swift`。
依赖：无（要 iPhone）。

# 已完成

- #1 iPhone 导航骨架：四个 Tab（PR #20，10 月 30 日合并）。
- 桌面 Today 页可翻看过去的天（PR #21，10 月 30 日合并），是 A 链的参考实现。
