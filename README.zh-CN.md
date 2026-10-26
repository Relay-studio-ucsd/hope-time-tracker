<p align="center">
  <img src="src-tauri/icons/128x128@2x.png" alt="Hope" width="96" />
</p>

<h1 align="center">Hope</h1>

<p align="center">
  一个安静的时间记录器。把你醒着的一天画成一个环。<br />
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/Relay-studio-ucsd/hope-time-tracker/releases"><img src="https://img.shields.io/github/v/release/Relay-studio-ucsd/hope-time-tracker?include_prereleases&style=flat-square" alt="Release" /></a>
  <a href="https://github.com/Relay-studio-ucsd/hope-time-tracker/releases"><img src="https://img.shields.io/github/downloads/Relay-studio-ucsd/hope-time-tracker/total?style=flat-square" alt="Downloads" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Relay-studio-ucsd/hope-time-tracker?style=flat-square" alt="License" /></a>
</p>

<p align="center">由 <a href="https://github.com/dan9574">@dan9574</a> 创建并维护 · <a href="https://github.com/Relay-studio-ucsd">Relay Studio UCSD</a></p>

---

## 下载之前

- **现在可用：macOS 和 Windows。** 安装包在 [Releases](https://github.com/Relay-studio-ucsd/hope-time-tracker/releases)。安装包暂未签名，第一次打开多一步：macOS 右键 `Hope.app` → **打开**；Windows 在 SmartScreen 提示里点 **更多信息 → 仍要运行**。没有有效期。
- **暂不提供：iPhone 和 Apple Watch。** 两个 app 都已经做出来、在我们自己的设备上跑着（下面有截图），但**还没上 App Store**，前端和后端也还在继续开发，所以目前只发桌面版。
- **Android：** 暂不支持，除非后续有人提需求。

---

## 这是什么

Hope 记录你**主动选择**投入的时间，一次一个计时器，把一天画成从起床到睡觉的一个环。它刻意安静：没有连续打卡，没有游戏化，整个界面没有颜色，颜色只属于你自己的活动。

<p align="center">
  <img src="docs/screenshots/desktop-today.png" alt="今天" width="85%" />
</p>

## 功能

### 每天、每周、每月

- **今天** — 环从起床展开到睡觉，每条记录画在环上，正在跑的计时器在上面走，下面是当天的时间线。起床、睡觉各一个按钮，记下实际时间。
- **本周**、**本月** — 按活动、按天的总时长，看清时间去了哪里。
- **日程** — 单次和周期安排，周期安排到点可以自动计入。可以导入学校的 `.ics` 课表：课程成为单独一组，默认不计入总时长，因为上课时间不是你自己决定投入的时间。

<p align="center">
  <img src="docs/screenshots/desktop-week.png" alt="本周" width="48%" />
  <img src="docs/screenshots/desktop-month.png" alt="本月" width="48%" />
</p>

<p align="center">
  <img src="docs/screenshots/desktop-schedule.png" alt="日程" width="85%" />
</p>

想把上课时间也看进去，在设置里打开**「总时长计入课表」**：本周、本月就会把它算进来，用课表组自己的颜色显示，每门课列在组下面。

<p align="center">
  <img src="docs/screenshots/desktop-week-classes.png" alt="计入课表的本周" width="48%" />
  <img src="docs/screenshots/desktop-month-classes.png" alt="计入课表的本月" width="48%" />
</p>

### 活动、日记、桌面卡片

- **活动**：一层子活动，八种颜色，拖动排序，不再做的可以归档。
- **记录**可以编辑、拆分、移动、删除；每天一条**日记**。
- **桌面卡片**：三张小卡（现在、今天、本周）贴在桌面图标下面，macOS 和 Windows 上都有真实的毛玻璃。
- **菜单栏 / 托盘计时**：不开窗口也能开始、暂停、结束。
- **主题**：浅色、深色或跟随系统；暖色或冷色调；自选强调色；细环或粗环。
- **数据是你的**：全部存在本地 SQLite 文件里，随时可以导出、导入 JSON。

<p align="center">
  <img src="docs/screenshots/desktop-overlay.png" alt="桌面卡片" width="36%" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/desktop-settings.png" alt="外观与桌面卡片设置" width="58%" />
</p>

### 同步

Hope 完全离线可用。想在多台电脑上用同一份数据，在**设置 → 同步**里注册一个账号（邮箱加密码；数据存到我们的 Supabase 项目里，在你自己的账号下，别人读不到）。另一台机器登录同一账号，两边就会收敛一致。

### 时间提醒与距离提醒

两种提醒，手机上默认关、手表上默认开，运动类活动和课表时间都不提醒：

- **歇一歇** — 连续计时每满 90 分钟（不含暂停），弹一条通知问你要暂停还是再来一会儿。手表先提醒，桌面晚一分钟，iPhone 再晚两分钟、只在前两者都没提醒时兜底。
- **你离开了** — iPhone 发现你离开开始计时的地方超过 300 米时，问你要不要结束：*继续计时*（以现在的位置为准）、*结束*、*30 分钟内别提醒*。

iPhone 版还没发布，所以桌面版目前只有歇一歇这一种提醒。

## iPhone 与 Apple Watch

还不能下载，先看看长什么样。

<p align="center">
  <img src="docs/screenshots/iphone-today.png" alt="iPhone" width="30%" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/watch-list.png" alt="Apple Watch" width="24%" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/watch-running.png" alt="Apple Watch 计时中" width="24%" />
</p>

- **Apple Watch** — 开计时的地方：活动列表带今日总时长，大号跳秒计时器配暂停和结束，表盘复杂功能用活动的颜色显示正在跑的计时（空闲时显示今日总时长），歇一歇提醒直接在手腕上。
- **iPhone** — 极简的伴侣：今日总时长和记录，开始 / 暂停 / 结束，账号，以及离开提醒。它把登录交接给手表。

## 接下来

以下都在开发中，后续都会支持：

- iPhone 和 Apple Watch 上架 **App Store**。
- **在 app 里连接你自己的数据库**。现在一个包在编译时绑定一个 Supabase 项目（上面的安装包用的是我们的，你注册即可）；这个设置会搬进 app 里，让你指向自己的项目。
- **实时同步**：手表上开的计时一秒内出现在桌面卡片上。
- **Android**：有需求再做。

## 自己编译

- 桌面：Node ≥ 20.19 和 Rust。`npm ci`，然后 `npm run tauri dev`；`npm run tauri build` 生成本平台的安装包。
- 用自己的 Supabase 项目：见 [supabase/README.md](supabase/README.md)。没有 `.env` 时编出来的是纯本地版。
- iPhone 与 Apple Watch：Xcode 26，见 [apple/README.md](apple/README.md)。

架构、数据模型和设计系统都写在 [docs/rebuild-plan.md](docs/rebuild-plan.md) 里。

## 许可

[MIT](LICENSE)
