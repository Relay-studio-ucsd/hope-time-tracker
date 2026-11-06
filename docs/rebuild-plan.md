# Hope 重构方案（v2）

> 本文是重构的唯一权威来源。实现时遇到文档未覆盖的问题，按"更像苹果原生 app"的方向决定；遇到与本文冲突的旧代码，以本文为准。

## 1. 目标

| 诉求 | 方案 |
|---|---|
| macOS + Windows 桌面 | Tauri 2（Rust 内核 + WebView），包体 10–15MB |
| 后续 iPhone + Apple Watch | 原生 Swift 工程（iOS + watchOS 两个 target），见第 9 节 |
| 多设备共用一份数据 | Supabase 作为云端唯一真相，各端本地优先 + 同步，见第 9 节 |
| 苹果审美 | 自建设计系统（第 4 节），系统材质 + 克制色彩，无渐变光斑 |
| 壁纸层透明记录 | 独立 Overlay 窗口：透明、无边框、always-on-bottom、点击穿透（第 5 节） |
| 多语言 | i18next，`zh-CN` / `en` 起步，所有 UI 文案走 key |
| 历史数据不丢 | 一次性从旧 SQLite 导入（第 3.3 节） |

## 2. 技术栈（固定，不要换）

```
前端   React 18 + TypeScript (strict) + Vite
样式   原生 CSS + CSS 变量（设计 token），不用 Tailwind，不用 CSS-in-JS
状态   Zustand（只存 UI 状态；数据以 Rust 侧为准，前端通过 query 拉取）
路由   不用路由库；单窗口 + 一个 `view` 状态切换
图标   lucide-react（唯一图标来源）
文件   tauri-plugin-dialog（导入/导出的原生打开、存储面板）
图表   自写 SVG（环、柱），不引入 d3
动画   CSS transition 为主；framer-motion 不引入
i18n   i18next + react-i18next，文案在 src/locales/{zh-CN,en}.json
后端   Rust：rusqlite（bundled）+ serde + uuid（v4）；通过 tauri command 暴露，前端用 tauri-specta 生成类型化绑定
       ID 只在 Rust 侧生成，前端永远不造 ID
标识   App identifier `io.github.dan9574.hope`；iOS 用 `.ios` 后缀，Watch 由 Xcode 自动派生
macOS  开启 macOSPrivateApi（透明材质与 Overlay 需要），放弃 Mac App Store，dmg 分发
存储   SQLite，单文件，位于 app data 目录
日期   date-fns（tz 用系统时区，去掉 PST/Beijing 枚举）；一周固定从周一开始
```

依赖准则：每加一个 npm 包都要说明为什么不能用 50 行代码替代。

## 3. 数据模型

### 3.1 表

```sql
activity  (id, name, color, symbol, sort, archived_at, *sync)
session   (id, activity_id, start_ms, end_ms, note, continues_id, *sync)  -- end_ms NULL = 进行中
plan      (id, activity_id, date, start_hm, end_hm, rule, *sync)          -- rule: NULL=单次, 'weekly:1,3,5'=每周
journal   (id, date, text, *sync)
setting   (key, value)                                                     -- 仅本机，不同步

-- *sync = 每张可同步表都带这 3 列，从第一天就有：
--   updated_ms INTEGER NOT NULL   后写的赢
--   deleted_ms INTEGER            软删除，NULL = 存活
--   device_id  TEXT NOT NULL
```

说明：
- **所有 `id` 用 UUID v4 字符串**，不用自增整数，多设备离线写入不会冲突。
- `activity.color` 存色名（`'blue'` 等 8 个之一，CHECK 约束），不存 hex；hex 在 `tokens.css` 的 `--activity-*`。Supabase 表用同样的 CHECK。
- **表之间不加外键**：同步可能乱序到达。UI 和统计必须容忍孤儿记录——找不到 activity 的 session 显示为灰色"未知活动"，照常计入总时长。
- `plan.rule` 的星期用 ISO 编号：1=周一 … 7=周日，`'weekly:1,3,5'` = 一三五；`date` 为首个生效日。重复计划没有单次例外，修改/删除作用于整个系列。
- `journal` 每天一篇：同一 `date` 只保留一条存活记录（Rust 按 date upsert，不加唯一索引，以免同步时冲突）。
- `session.continues_id`：暂停后恢复，新 session 指向被暂停的那条；UI 把链上的几段显示成一条。
- "进行中"全局唯一：任何设备开始新 session 时，先结束所有 `end_ms IS NULL` 的记录（本地和服务端都执行这条规则）。
- 旧库的 `weekly_schedule_events` / `manual_study_plans` / `daily_instantiated_plans` 三张表合并为 `plan`。
- 旧库的 `activity_colors` 合并进 `activity`；`text_color` / `background_color` 删除，文字颜色由 token 决定。
- 子活动保留，但不单独建表：`activity.parent_id` 自引用，只允许一层。详见第 10 节（6.5 阶段）。
- `symbol` 存 SF Symbol 风格的图标名（前端用 Lucide 图标集映射）。

### 3.2 Rust command 清单（最小集）

```
activity.list / upsert / archive
session.start(activity_id) / pause() / resume() / stop() / current() / list(range) / upsert / delete
sync.push / sync.pull / sync.status
plan.list(range) / upsert / delete
journal.list(range) / upsert / delete
stats.day(date) / stats.week(date) / stats.month(date)
setting.get / set
data.export / import   （格式见 3.3）
overlay.show / hide / set_position
```

### 3.3 导入 / 导出（唯一的数据进出口）

不做旧 Electron 库的直接导入。所有外部数据都先转成下面的 JSON，再走 `data.import`。

```json
{
  "format": "hope/1",
  "exported_at": 1760000000000,
  "activity": [{ "id": "…", "name": "Study", "color": "blue", "symbol": "book", "sort": 0, "archived_at": null, "parent_id": null, "updated_ms": 0 }],
  "session":  [{ "id": "…", "activity_id": "…", "start_ms": 0, "end_ms": 0, "note": "", "continues_id": null, "plan_id": null, "updated_ms": 0 }],
  "plan":     [{ "id": "…", "activity_id": "…", "date": "2026-10-02", "start_hm": "09:00", "end_hm": "11:00", "rule": null, "auto_log": true, "until": null, "updated_ms": 0 }],
  "journal":  [{ "id": "…", "date": "2026-10-02", "text": "", "updated_ms": 0 }],
  "day":      [{ "date": "2026-10-02", "wake_ms": 0, "sleep_ms": 0, "utc_offset_min": 480, "updated_ms": 0 }]
}
```

规则：
- 第 6.5 阶段新增的 `parent_id`、`plan_id`、`auto_log`（缺省为 true）、`until` 和整张 `day` 表都是可选的（`day` 按 `date` upsert），旧文件照常导入；格式名仍是 `hope/1`。
- `format` 版本号必须校验；`id` 缺失时导入端生成 UUID；`updated_ms` 缺失时取导入时刻。
- 导入是 upsert（按 `id`，后写的赢），重复导入同一份文件不会产生重复记录。
- `data.export` 输出完全相同的结构，保证导出 → 导入是无损往返。
- 以后要迁旧 Electron 数据，写一个独立脚本把 `timeglass.db` 转成这份 JSON 即可，不进主程序。

## 4. 设计系统

### 4.1 原则

1. **界面无色，内容有色。** 窗口、卡片、分隔线只用灰阶材质；颜色只属于"活动"。
2. **材质代替渐变。** 背景 = 半透明 + backdrop blur，透出壁纸。禁止 blur(200px) 光斑。
3. **层级靠字重和灰度，不靠框。** 卡片尽量不加边框，用 1px 10% 白线分隔即可。
4. **8pt 网格，连续圆角。** 间距只用 4 / 8 / 12 / 16 / 24 / 32 / 48。
5. **数字用等宽数字字形。** `font-variant-numeric: tabular-nums`，计时器不会抖。

### 4.2 Token（`src/styles/tokens.css`）

```css
:root {
  /* 字体 */
  --font-ui: -apple-system, "SF Pro Text", "Segoe UI Variable", "PingFang SC", "Microsoft YaHei UI", sans-serif;
  --font-display: -apple-system, "SF Pro Display", "Segoe UI Variable Display", "PingFang SC", sans-serif;
  --text-xs: 11px; --text-sm: 13px; --text-md: 15px; --text-lg: 17px;
  --text-xl: 22px; --text-2xl: 28px; --text-3xl: 40px;

  /* 圆角 */
  --r-sm: 8px; --r-md: 12px; --r-lg: 20px; --r-xl: 28px;

  /* 间距 */
  --s-1: 4px; --s-2: 8px; --s-3: 12px; --s-4: 16px; --s-6: 24px; --s-8: 32px; --s-12: 48px;

  /* 材质（浅色） */
  --mat-window: rgba(246, 246, 248, 0.72);
  --mat-card:   rgba(255, 255, 255, 0.55);
  --mat-hover:  rgba(0, 0, 0, 0.04);
  --line:       rgba(0, 0, 0, 0.08);
  --blur:       saturate(180%) blur(28px);

  /* 文字 */
  --fg:   rgba(0, 0, 0, 0.88);
  --fg-2: rgba(0, 0, 0, 0.55);
  --fg-3: rgba(0, 0, 0, 0.32);

  --accent: #0A84FF;
}

@media (prefers-color-scheme: dark) {
  :root {
    --mat-window: rgba(28, 28, 30, 0.72);
    --mat-card:   rgba(255, 255, 255, 0.06);
    --mat-hover:  rgba(255, 255, 255, 0.06);
    --line:       rgba(255, 255, 255, 0.10);
    --fg:   rgba(255, 255, 255, 0.92);
    --fg-2: rgba(255, 255, 255, 0.58);
    --fg-3: rgba(255, 255, 255, 0.34);
  }
}
```

### 4.3 活动色板（低饱和、高明度，叠在壁纸上不脏）

```
blue    #6AA9FF   green   #5FD39A   orange  #FFAB6B   pink    #FF8FB8
purple  #B08CFF   teal    #5CD0D0   yellow  #F5D56A   gray    #A5A5AC
```

用户只能从这 8 个里选，不开放任意取色。

### 4.3.1 主题（Settings 里的三个选项，仅此三个）

1. 材质色温：Clear（默认，无色）/ Warm（叠 12% 的 #F5E6C8）/ Cool（叠 12% 的 #C8D8E6），同时作用于侧栏和内容区（见第 10 节 B）。
2. 强调色：从 4.3 的 8 色里选一个作为 `--accent`（默认 blue），影响按钮、选中态、当前时刻圆点。文字用派生的 `--accent-text`（浅色模式混 40% 黑，深色模式等于 `--accent`），保证低饱和色做文字时可读。
3. 环线宽：10px / 16px。

主题不改变布局、字体、圆角；禁止任何形式的渐变背景。

### 4.4 主窗口布局

- macOS：`titleBarStyle: Overlay`，交通灯内嵌；Windows：系统标题栏（不自绘）。
- 窗口必须真正透出壁纸：macOS 用 `transparent: true` + vibrancy（`sidebar` 材质给导航列，`under-window` 给内容区）；Windows 用 Mica / Acrylic。看起来是平灰色就是没配对，要修。
- 左侧 200px 导航列（材质更透），项：今天 / 本周 / 本月 / 活动 / 设置。无大卡片，一行一项，当前项淡色底。
- 右侧内容区最大宽 720px 居中。
- 页面标题 `--text-2xl` 600 字重，下方一行 `--fg-2` 副标题。

### 4.5 关键页面

**今天**：页面标题 + 日期；中间一个**开口向下的马蹄环**（规格见下）；下方时间线列表，每行 `时间段 · 活动 · 时长`，不加 LOGGED/SCHEDULED 徽章，计划用虚线左边条表示。

马蹄环规格：
- 弧度 300°，底部 60° 缺口代表睡眠。清醒时段 wake→sleep 映射到弧上，左下端 = wake，右下端 = sleep，端点外侧小字标时间（`--text-xs` `--fg-3`）。
- 直径 240–260px，线宽 10px，线端圆头。
- 底色：已过去部分 `--fg-3` 的 40%，未来部分 `--line`。记录按活动色实心着色；计划画成同色 40% 透明的段，叠在底色之上、记录之下。
- 当前时刻在弧上一个 8px 实心圆点（`--fg`）。
- 环中心：今日总时长大数字（`--text-3xl` tabular 600）+ 下方一行 `--fg-2` 小字"已记录"。页面顶部不再单独放这个数字。
- 空状态：弧上仍画计划；无计划时在列表位置显示一行 `--fg-3` 提示，不超过 12 个字。

**本周**：7 根堆叠柱，柱宽 24px，间距 16px，顶部数字；下方按活动汇总。

**本月**：7 列月历（周一起），每格：日期 + 当天总时长 + 一条按活动着色的细条（长度按当月最忙一天归一，未来日期不画）；下方按活动汇总。

本周 / 本月都可用标题右侧 ‹ › 翻看过去（不能翻到未来）；不在当前周期时出现「回到本周/本月」，标题改为相对时间（上周、3 个月前）。

**计划与日记**（不单独占导航）：都在今天页。时间线上方「+ 计划」，可选每周重复；点任一条计划可改/删。页底「今天的日记」文本框，自动保存。

**开始计时**：不在页面里。菜单栏 / 托盘图标点一下弹出活动列表，点即开始；再点即停。主窗口右上角也放一个同样的按钮。

## 5. Overlay 窗口（壁纸层记录）

- 独立 Tauri 窗口 `overlay`：`transparent: true, decorations: false, always_on_bottom: true, skip_taskbar: true, focusable: false`，`set_ignore_cursor_events(true)`。
- macOS 额外把 NSWindow level 设为 `kCGDesktopIconWindowLevel - 1`，让它位于桌面图标之下、壁纸之上。
- **模糊是原生的**：透明窗口里 CSS `backdrop-filter` 看不到壁纸。每张卡下面放一块原生 `NSVisualEffectView`（objc2），位置由页面量好后交给 Rust；卡片位置、尺寸、显隐任何变化都要重新量并同步底板。
- Windows：always-on-bottom 定层级；模糊是每张卡下面一个无 webview 的小窗口（Tauri `unstable` feature）开 Acrylic 做底板，位置随卡片和 Overlay 窗口移动同步，DWM 固定 8px 圆角，所以卡片在 Windows 上用 `--r-sm`。2026-10-13 在 Windows 11 真机验证。
- 默认停靠屏幕右侧，宽 320px，距右边 48px，垂直居中；设置里可拖动，「完成」时保存，另有「恢复默认」。
- 设置里的「大小」（100 / 125 / 150%）把三张卡整体缩放（CSS transform），窗口按同一系数变大，默认停靠位置按放大后的尺寸算。
- 内容三块，竖排，每块是独立材质卡（原生模糊底板 + `rgba(255,255,255,0.14)` 填充，1px 白线 15%，圆角 `--r-lg`）：
  1. **Now**：进行中活动名 + 已持续时间（无进行中则显示"今天 · 总时长"）。
  2. **Today**：细环 + 前 3 个活动与时长。
  3. **This Week**：7 根细柱 + 本周总时长 + 与上周**同期**对比（本周一至此刻 vs 上周一至上周同一时刻）。
- 文字固定白色（85% / 55%），不随系统深浅色切换，因为它永远叠在壁纸上。
- 设置里可单独开关每一块、调整透明度（0.6–1.0）。**透明度只作用于卡片填充和文字，不作用于模糊底板**——底板一起淡化会透回清晰壁纸，就不像玻璃了。

## 6. 目录结构

```
hope/
  src-tauri/          Rust：db/、commands/、overlay.rs、tray.rs
  src/
    app/              App.tsx、窗口壳、导航
    overlay/          Overlay 窗口入口与三张卡
    views/            Today、Week、Month、Activities、Settings
    components/       Ring、Bars、Timeline、ActivityDot、Button…
    lib/              bindings.ts（specta 生成）、time.ts、stats.ts
    stores/           ui.ts
    styles/           tokens.css、base.css
    locales/          zh-CN.json、en.json
  legacy/             旧 Electron 代码整体移入，仅供导入参考，不再构建
```

## 7. 实施阶段

每阶段结束时 app 可运行、可演示，再进入下一阶段。

1. **骨架**：Tauri 2 项目初始化、tokens.css、主窗口壳 + 导航、Rust 建表、specta 绑定、i18n 接入。旧代码移入 `legacy/`。
2. **核心闭环**：activity / session 的 command；托盘开始/停止；Today 视图（数字 + 环 + 时间线）。
3. **Overlay 窗口**：三张卡 + 位置/透明度设置。先在 macOS 上做到桌面图标之下，再做 Windows。
4. **本周 / 本月**。
5. **活动管理、计划、日记、设置**（含 4.3.1 主题、3.3 的导入/导出）。
6. **打包**：macOS dmg（arm64 + x64）、Windows nsis；GitHub Actions 出包。
   - 推 `v*` tag → `.github/workflows/release.yml` 先跑类型检查与 Rust 测试，再并行出三个包，放进草稿 Release；手动触发只上传 artifact。
   - 暂不签名（ad-hoc），macOS 首次打开需右键 → 打开；CI 里已预留 Developer ID 签名 + 公证的环境变量，补 Secrets 后取消注释即可。
   - macOS 最低 13.0。Windows 安装为当前用户（无需管理员）。
   - Windows 上 Overlay 的逐卡模糊：2026-10-13 已做（每卡一个 Acrylic 小窗口，第 5 节）。
6.5 / 6.6 **修复与补全**（第 10、11 节）：滚动 bug、子活动、起床/睡觉、记录编辑与删除、周期安排自动计入、主题加强。**必须在同步层之前做完**，因为它改表结构。
7. **同步层**：Supabase 建表 + 桌面端 push/pull + 实时订阅（手表开始计时后 Overlay 卡片实时变化）。
8. **iPhone**：原生 Swift 工程，SwiftData 本地库 + 同步，Live Activity 显示进行中计时。
9. **Apple Watch**：watchOS target，表盘复杂功能 + 开始/暂停/结束。
10. **课表导入与课表时间**（第 13 节）。
11. **离开提醒**（第 14 节）：`kind = 'exercise'`、iPhone 离开开始地点 300 米的通知。
12. **休息提醒**（第 15 节）：连续计时满 90 分钟，手表 → 桌面 → iPhone 依次提醒，`session.break_ack_ms` 跨端去重。

## 8. 环境要求

- Rust stable（`rustup`）
- Node 20+
- macOS：Xcode 完整版（阶段 8、9 需要）
- Apple Developer Program（阶段 8、9 要长期装到真机、上 TestFlight 需要付费账号）
- Supabase 账号（阶段 7）
- Windows 打包：在 Windows 机器或 CI 上做

## 9. 多端与同步

### 9.1 为什么是两个代码库

watchOS app 只能用 Swift/SwiftUI 写，没有 WebView 路线；Windows 又不能用 iCloud/CloudKit。因此：

```
          ┌──────────────┐
          │  Supabase    │  Postgres + Realtime + Auth；云端唯一真相
          └──────┬───────┘
      ┌──────────┼───────────┐
      ▼          ▼           ▼
 Tauri 桌面   iPhone app   Apple Watch
 mac / Win   (Swift)      (Swift, 同一 Xcode 工程)
 SQLite      SwiftData    直接走网络，不依赖手机在旁
```

### 9.2 同步规则（所有端一致）

- 本地优先：每端有完整本地库，离线可用；联网后 push 本地变更、pull 远端变更。
- 以 `updated_ms` 判定，后写的赢。删除是软删除（`deleted_ms`），同步后再物理清理。
- 云端表结构与第 3.1 节完全相同，Supabase 的 `user_id` 列做行级权限。
- Realtime：各端订阅 `session` 表，收到变更即刷新"进行中"状态和当日统计。
- "进行中"全局唯一，规则见 3.1。

### 9.3 Apple Watch 交互

- 表盘复杂功能：当前活动名 + 已持续时间；无进行中则显示今日总时长。
- 打开 app：活动列表，点一下开始。
- 进行中界面：大数字计时 + 两个按钮 **暂停** / **结束**。
- 暂停 = 结束当前 session；恢复 = 同一活动开新 session 并设 `continues_id`。统计自然正确，暂停时长不计入。
- Watch 直接连 Supabase（Wi-Fi / 蜂窝 / 借手机网络），不走 WatchConnectivity 转发，逻辑更简单。

### 9.4 iPhone

- 与桌面同样的五个视图，但导航改为底部 Tab。
- Live Activity：进行中计时显示在灵动岛与锁屏，数据来源与 Watch 相同。
- Overlay 壁纸卡片在手机上对应为 WidgetKit 桌面小组件（Today / This Week 两种尺寸）。

## 10. 阶段 6.5：修复与补全

来自第一轮真实使用的反馈。按 A → F 顺序做，每一项做完 app 能跑再做下一项。表结构改动全部放进一个迁移 `0002_*.sql`，并同步更新 3.3 的 JSON 格式（仍叫 `hope/1`，新字段都是可选的，旧文件照常能导入）。

### 10.0 表结构改动汇总（迁移 0002）

```sql
ALTER TABLE activity ADD COLUMN parent_id TEXT;            -- NULL = 顶层；非 NULL = 子活动，只允许一层
ALTER TABLE session  ADD COLUMN plan_id   TEXT;            -- 非 NULL = 由计划自动计入
ALTER TABLE plan     ADD COLUMN auto_log  INTEGER NOT NULL DEFAULT 1;   -- 到点自动计入
ALTER TABLE plan     ADD COLUMN until     TEXT;            -- 周期计划的最后一天（含），NULL = 一直重复

CREATE TABLE day (                                         -- 每天实际的起床 / 睡觉
  date        TEXT PRIMARY KEY NOT NULL,                   -- 起床那天的本地日期 'YYYY-MM-DD'
  wake_ms     INTEGER,                                     -- NULL = 用设置里的默认值
  sleep_ms    INTEGER,                                     -- NULL = 还没睡 / 用默认值
  utc_offset_min INTEGER NOT NULL,                         -- 当天所在时区，用于回看历史时显示当地时间
  updated_ms  INTEGER NOT NULL,
  deleted_ms  INTEGER,
  device_id   TEXT NOT NULL
);
```

### A. 窗口缩小后无法滚动（bug）

原因：`.shell` 是 grid，没写行高，隐式行按内容撑开；`.content` 是 flex 列但没有 `min-height: 0`，所以 `.content-scroll` 永远不会溢出，而 `body` 是 `overflow: hidden`，下面的内容被直接裁掉。

修复（`src/app/App.css`）：
- `.shell` 加 `grid-template-rows: minmax(0, 1fr)`。
- `.content` 和 `.sidebar` 加 `min-height: 0`；`.sidebar-list` 加 `overflow-y: auto`。
- 验收：窗口缩到最小尺寸（720×480），每个页面都能滚到底，弹出的编辑器也能完整操作。

### B. 主题加强

主题三项已经实现，但色温只有 4%，肉眼看不出来；这是规格定得太保守。
- 色温强度从 4% 提到 12%，并让它同时作用在侧栏和内容区。
- 新增「外观」选项：跟随系统 / 浅色 / 深色（`data-theme`，覆盖 `prefers-color-scheme`）。
- 强调色除按钮和选中态外，再作用于：Today 环上的当前时刻圆点、侧栏选中项的图标、PeriodNav 的"今天"标记。
- 仍然禁止渐变背景。

### C. 子活动

模型：`activity.parent_id`。只有一层；子活动没有自己的颜色，永远显示父活动的颜色（`color` 列写入时复制父值，读取时以父为准）。父活动归档时子活动一并隐藏。

行为：
- session 和 plan 的 `activity_id` 可以指向父（"学习"）也可以指向子（"学习 / 线性代数"）。
- 统计默认按父活动汇总；本周 / 本月的活动汇总行可以展开看子活动明细。
- 环和柱只用父颜色，不为子活动分色。
- 时间线、托盘、Overlay 的 Now 卡显示为 `父 · 子`。

界面：
- 活动页：父活动行下缩进显示子活动，行尾"＋"添加子活动；子活动可改名、归档、拖动排序，可移到另一个父活动下。
- 所有选择活动的地方（开始计时按钮、托盘菜单、计划编辑器、记录编辑器）改为两级：点父活动直接选父；有子活动的父活动行右侧有展开箭头，展开后选子。托盘用原生子菜单。

### D. 记录的编辑、补录、删除（都要确认）

现在时间线上的记录点不动，Rust 侧的 `session.upsert / delete` 没有界面入口。

- 时间线上的记录行可点击，打开记录编辑器：改活动（两级选择）、开始时间、结束时间、备注。保存前校验结束 ≥ 开始、不与其他记录重叠（重叠时提示并拒绝，不自动裁剪）。
- Today / 任意一天的工具栏加「补录」：手动添加一条过去的记录，用同一个编辑器。
- 「移到另一天」不单独做按钮：编辑器里的日期可以改。
- 删除：编辑器底部的删除按钮 → 原生确认对话框（`tauri-plugin-dialog` 的 `ask`），文案写明活动名和时间段。确认后软删除。
- 活动、计划、日记的删除同样走确认对话框。删除活动时提示它下面有多少条记录；有记录的活动只能归档，不能删除。
- 设置 → 数据 新增「清空全部数据」：必须输入 `DELETE` 才能点确认；清空前自动导出一份 JSON 到下载目录。
- 约定：**任何会丢数据的操作都必须有确认**；新增、修改不需要确认。

### E. 起床与睡觉

设置里的起床 / 睡觉时间只是默认值；每天的实际值存进 `day` 表。

- Today 页环的下方有一个按钮，只在对应的时间窗口内出现，避免白天误触：
  - **「起床」**：当天还没有 `wake_ms`，且现在早于"起床按钮截止时间"（默认 **08:30**）。点击写入 `wake_ms = now`。
  - **「睡觉」**：已起床未睡，且现在晚于"睡觉按钮开始时间"（默认 **21:00**）。点击写入 `sleep_ms = now`，并结束正在进行的计时。
  - **「撤销睡觉」**：已睡之后显示，点击清空 `sleep_ms`。
  - 窗口之外不显示按钮；这时要记录（起晚了、午后才想起来）就点环两端的时间标签手动改。
  - 两个时间点在 设置 → 作息 里可调，存为本机设置 `wake_button_until_hm`、`sleep_button_from_hm`，与默认起床 / 睡觉时间是四个独立的值。
- 托盘菜单同样有「起床 / 睡觉」一项，遵守相同的时间窗口。
- 点击环两端的时间标签可以直接改当天的起床 / 睡觉时间（起晚了事后补、忘按睡觉第二天补）。
- 凌晨归属：没按「睡觉」时，在「默认睡觉时间与次日默认起床时间的中点」（默认 03:00）之前仍算前一天，之后算新的一天。
- 跨午夜：`sleep_ms` 允许落在第二天；一"天"的范围是 `wake_ms → sleep_ms`，凌晨的记录归属于还没睡的那一天。若到了第二天默认起床时间仍没有 `sleep_ms`，按默认睡觉时间收尾。
- 环的范围 = `min(默认起床, 实际起床) → max(默认睡觉, 实际睡觉)`。范围内属于睡眠的部分（晚起的那段、早睡的那段）用 `--activity-purple` 40% 透明度画；按下「睡觉」后，环底部的缺口也变成同样的紫色，中心数字下方的小字改为"已休息"。Overlay 的 Today 卡同步这个状态。
- 睡眠不是一个 activity，不进入活动统计；但 Today 副标题显示昨晚睡了多久（今天 `wake_ms` − 昨天 `sleep_ms`）。
- 时区：所有时间存绝对毫秒，天然不受时区影响。`day.utc_offset_min` 记录当天所在时区，回看历史某天时用那天的时区显示钟点，而不是现在的；跨时区旅行当天以起床时所在时区为准。不做手动选时区。

### F. 周期安排与自动计入

周期计划（`rule = 'weekly:…'`）已能创建，但入口只在 Today 的"添加计划"，而且计划不会计入统计。

- 新增导航项「日程」（放在"本月"和"活动"之间）：一周七列的课表视图，每个周期计划是一个色块；点空白处新建，点色块编辑。一次可以勾选多天，所以"每周 10 节课"是几次操作的事。
- 周期计划编辑器增加「结束日期」（`plan.until`，可空）和「到点自动计入」开关（`plan.auto_log`，默认开）。
- 自动计入：计划的结束时间过去后，如果 `auto_log = 1` 且该时间段内没有任何手动记录，就生成一条真实的 `session`（`plan_id` 指向计划）。
  - **id 用确定性的 UUID v5**（由 `plan.id` + 日期算出），多台设备各自生成也只会得到同一条，不会重复。
    命名空间 `6b9f4c1e-8a2d-4f7b-9e3c-5d1a2b4c6e8f`，名字 `hope-autolog/{plan_id}/{YYYY-MM-DD}/{k}`（`k` 是同一次课被手动记录切开后的第几段，从 0 起）。各端必须用完全相同的规则。
  - 时间段内有部分手动记录时，只计入没被覆盖的部分。
  - 生成时机：app 启动时、每分钟一次、以及补算过去 30 天（应对 app 没开的日子）。
  - 用户删除一条自动计入的记录 = 那次课没上。因为是软删除、id 确定，它不会被重新生成。
  - 修改计划的时间只影响未来；已经生成的记录不改。
  - 实现方式：结束时间早于计划最后一次修改（`plan.updated_ms`）的那次不补记，所以新建周期计划不会补出过去的记录。只对周期计划生效，单次计划不自动计入。
  - 由前端按本地时区算出每次发生的绝对时间交给 Rust（Rust 侧没有时区库），Rust 负责判定与幂等写入。
- 时间线上自动计入的记录带一个小的循环图标，其余与普通记录相同，同样可以编辑和删除。
- 还没到点的计划仍按现状显示为虚线段。

## 11. 阶段 6.6：时长格式、悬停联动、环上的短记录

纯前端，不改表结构。在 6.5 全部完成之后做。

### 11.1 时长格式

`lib/time.ts` 的 `formatDuration` 是唯一出口，所有界面（主窗口、Overlay、托盘）都走它。

| 时长 | 显示 |
|---|---|
| 不满 1 分钟 | `0 min` |
| 不满 1 小时 | `45 min` |
| 满 1 小时 | `2 h 15 min` |
| 整点 | `3 h`（不写 `0 min`） |

- 不用冒号格式，不用小数小时。
- 单位走 i18n：英文 `h` / `min`，中文 `小时` / `分钟`；数字与单位之间一个窄空格。
- 大数字处（Today 环中心、Week / Month 顶部、Overlay 卡）：数字用原字号，单位用 `--text-md` `--fg-2`。
- 唯一例外：**正在进行的计时器**保持跳秒格式 `H:MM:SS`（不满 1 小时 `MM:SS`）。

### 11.2 图表与列表的悬停联动

双向：悬停图形高亮对应的列表行，悬停列表行高亮对应的图形。键盘聚焦与悬停等效。

- 状态：`stores/ui.ts` 里一个 `hoverKey: string | null`，图形和列表都读写它。
- **Today**：环上一段 ↔ 时间线一行，一一对应，key 为记录（或计划）的 id。
- **本周 / 本月**：key 为活动 id（子活动归到父活动）。悬停任意一段 → 所有柱子里同一活动的段一起高亮 + 下方汇总里该活动的行高亮；悬停汇总行效果相同。
- 高亮表现：
  - 环上的段：线宽 +3px（向外侧加粗，不挤压内部文字）。
  - 柱子里的段：左右各 +2px。
  - 其余段不透明度降到 60%。
  - 列表行：背景 `--mat-hover`。
  - 过渡 120ms ease；`prefers-reduced-motion` 时无过渡。
- 悬停图形时显示一个小标签（材质卡，`--text-xs`）：`活动名 · 时间段 · 时长`；本周 / 本月的标签为 `活动名 · 当天时长`。
- 不自动滚动页面。

### 11.3 环上的记录：细轨道 + 圆珠

苹果的图形语言里最小单位是圆，不是矩形。平头小片段读起来像刻度或划痕（试过，已否决）；细轨道上串珠子也试过，已否决——环显得单薄，记录像是另一层东西。定案：**一条完整的粗环，记录是环本身被染色的一段**。

轨道：
- 底环（已过去 / 未来两段）与记录**同宽**，都等于"环线宽"设置（10 / 16px），圆头。Overlay 的 Today 卡里同样同宽。
- 记录不是放在环上的东西，而是环的一部分换了颜色：短记录是环上一块圆形的染色，正好填满环的宽度；长记录是一段染色。

记录与计划：
- 记录段线宽 = 环线宽设置，**圆头**。计划段同样形状，40% 不透明度。
- 圆头不能让时间失真：路径两端各向内收半个线宽，使圆头的最外缘正好落在真实的起止时间上。
- 弧长不足一个线宽的记录画成一颗**正圆**（直径 = 线宽），圆心在该记录的时间中点。
- 相邻两段之间保持 2px 可见间隙（各再内收 1px）。收完不足一个线宽的，按正圆画。
- **合并绘制**：属于同一顶层活动、且**时间上**间隔不超过 2 分钟（前一条结束到后一条开始）的相邻记录，画成一粒胶囊；与屏幕上的像素距离无关（按"间距小于一个线宽"合并试过，已否决——10px 线宽下会把相隔约 14 分钟的记录并在一起，藏掉真实的休息）。只影响画法，不改数据。合并的胶囊对应时间线里的多行：悬停胶囊高亮它包含的所有行，悬停其中任意一行高亮这粒胶囊。
- 间隔超过 2 分钟的同一活动记录各画各的，即使屏幕上贴得很近，按下面的间隙 / 重叠规则处理。
- 不同活动的圆珠靠得太近而重叠时不做处理，后开始的画在上面。
- 悬停：线宽 +3px；命中区域比可见线宽宽 6px（透明描边）。

睡眠：
- 环内属于睡眠的时段（晚起、早睡）按记录的形状画：环线宽、圆头、`--activity-purple` 40%。
- 睡后底部缺口的紫色与环同宽。

"现在"标记：
- 空心圆：半径 = 线宽 / 2 + 1，填充 `--now-fill`，描边 `--fg` 2px。画在所有记录之上。
- 新 token `--now-fill`：浅色 `#FFFFFF`，深色 `#1C1C1E`。
- 它不再使用强调色（覆盖 10.B 里"强调色作用于当前时刻圆点"那一条），否则会和蓝色活动混淆。

本周 / 本月的柱子不变：段最小高度 2px、段间 1px 间隙、只有整根柱子的顶和底是圆角。

## 12. 阶段 7：同步协议（所有端共用，Swift 端照此实现）

第 9.2 节是原则，这里是可执行的规格。与 9.2 冲突处以本节为准。

### 12.1 云端表（`supabase/schema.sql`，用户在 Supabase SQL Editor 里执行）

- 同步五张表：`activity`、`session`、`plan`、`journal`、`day`。列与本地完全相同，另加：
  - `user_id uuid not null default auth.uid()`
  - `server_seq bigint not null`，取自全局序列 `sync_seq`
- 主键 `(user_id, id)`；`day` 为 `(user_id, date)`。`activity.color` 的 CHECK 与本地一致。表与表之间无外键（`user_id` 指向 `auth.users` 的外键见 17.4）。
- RLS：四种操作都要求 `user_id = auth.uid()`。
- BEFORE INSERT OR UPDATE 触发器（每张表）：
  - UPDATE 时若 `(NEW.updated_ms, NEW.device_id) <= (OLD.updated_ms, OLD.device_id)`，返回 OLD（丢弃旧写入）。时间相同时 device_id 大的赢，保证各端结论一致。
  - 否则 `NEW.server_seq = nextval('sync_seq')`。
- "进行中唯一"触发器（`session`，AFTER INSERT OR UPDATE）：同一用户有多条 `end_ms IS NULL AND deleted_ms IS NULL` 时，`start_ms` 最晚的那条保持进行中，其余的 `end_ms` 设为它后面那条的 `start_ms`，并抬高 `updated_ms`。

### 12.2 本地（迁移 0003）

- 五张表各加 `dirty INTEGER NOT NULL DEFAULT 1`。任何本地写入置 1；push 成功且该行 `updated_ms` 未再变化时清 0；pull 写入的行为 0。`dirty` 不进 JSON 导出。
- `setting` 里存：`sync.user_id`、`sync.cursor.<table>`、`sync.last_ok_ms`、`sync.last_error`。

### 12.3 推与拉

- **Push**：PostgREST upsert，`POST /rest/v1/<table>?on_conflict=user_id,id`，`Prefer: resolution=merge-duplicates`，每批 ≤ 500 行。本地写入后 500ms 防抖触发。
- **Pull**：`GET /rest/v1/<table>?server_seq=gt.<cursor - 50>&order=server_seq.asc&limit=1000`，循环到取完。回读最近 50 个序号是为了盖住并发事务乱序提交的窗口；应用是幂等的，重复无害。
- 本地应用远端行时用与云端相同的比较规则；本地更新则保留本地并保持 dirty。
- 节奏：登录状态下每 5 秒 pull 一次；启动时、恢复联网时各做一次完整的 push + pull；出错指数退避，上限 60 秒。
- pull 改动了数据就发出现有的数据变更事件，主窗口、托盘、Overlay 随之刷新。
- Realtime（websocket）先不做，5 秒轮询已满足"手表开始、桌面几秒内变化"。以后作为 7b 再加。

### 12.4 登录与配置

- Supabase Auth，邮箱 + 密码（GoTrue REST：`/auth/v1/signup`、`/auth/v1/token?grant_type=password|refresh_token`）。验证码注册、找回密码、删除账号见第 17 节。
- refresh token 存系统钥匙串（`keyring` crate）；access token 只在内存。
- `SUPABASE_URL`、`SUPABASE_ANON_KEY` 在构建时从根目录 `.env`（已 gitignore，另提交 `.env.example`）读入；CI 用仓库 Secrets。没配置时 app 仍完全可用，只是本地模式，同步设置区显示"未配置"。
- 所有网络请求在 Rust 里发（`reqwest`，rustls）；前端不直接访问 Supabase。
- 设置 → 新增「同步」组：状态（未配置 / 未登录 / 同步中 / 上次同步时间 / 错误）、邮箱、密码、登录 / 注册 / 退出。
- 首次登录：本地已有数据与云端按规则合并。若这台设备上次同步的是另一个账号，先弹确认。退出登录不删本地数据。

### 12.5 批准的新依赖

`reqwest`（`default-features = false`，`rustls-tls` + `json`）、`keyring`。异步运行时用 Tauri 自带的 tokio。

### 12.6 测试

传输层放在 trait 后面；用内存里的假服务端（实现同样的比较规则与序号）做单元测试：两台设备收敛、离线编辑后合并、删除与编辑冲突、进行中唯一、重复 pull 幂等、分页、乱序提交窗口。

### 12.7 Apple 端的落点（阶段 8、9）

- 目录 `apple/`，一个 Xcode 工程：iOS app（先做最小版：登录 + 今日概览 + 承载 Watch app）与 watchOS app。Bundle ID `io.github.dan9574.hope.ios`。
- 两端各自实现 12.3 的协议（URLSession），本地存储用 SwiftData。
- 手表的登录态由 iPhone 通过 WatchConnectivity 传过去；手表之后直接连 Supabase。

### 12.8 拉取合并成一个请求、后台放慢（草案，确认后再实现；美国版公开前要做完）

问题：12.3 的 pull 是每张表一个 GET，五张表、每 5 秒一轮，一台登录的设备约等于每秒 1 个请求。内测无所谓，公开后撑不住，而桌面端只要开着就一直在轮询。

- 云端加函数 `hope_pull(after jsonb, lim int default 1000) returns jsonb`，`security invoker`（照常走 RLS），`grant execute to authenticated`。
  - 入参 `after` 是每张表的游标：`{"activity": 120, "session": 3391, …}`，缺的键当 0。客户端照旧先减 50（12.3 的乱序窗口）。
  - 返回 `{"activity": [...], "session": [...], "plan": [...], "journal": [...], "day": [...]}`，每张表按 `server_seq` 升序、最多 `lim` 行，行的形状与现在 GET 返回的完全一样。
  - 某张表返回了满 `lim` 行就带着新游标再调一次，直到都不满。
- 客户端 `POST /rest/v1/rpc/hope_pull`，一轮一个请求。本地游标仍是每表一个（`sync.cursor.<table>`），不迁移。
- 云端还没有这个函数时（PostgREST 返回 404 `PGRST202`）退回每表一个 GET，本次运行内不再试 RPC。这样先发客户端、后跑 SQL 不会把同步弄断，自架的后端（第 18 节）漏了这一步也能用。
- 节奏：app 在前台（桌面主窗口可见；iPhone、手表 app 处于活动状态）5 秒一轮，与现在相同；桌面主窗口隐藏、只剩托盘和 Overlay 时 30 秒一轮。本地写入照旧 500ms 后立刻 push，不受影响。
- push 不变（有改动才发）。表结构、RLS、触发器都不动，已装出去的旧版客户端继续走每表 GET。
- 测试：两端假服务端加 `hope_pull`，现有的收敛、分页、乱序窗口用例各跑两遍（RPC / 退回 GET）；请求形状两端一致。

## 13. 阶段 10：课表导入与课表时间的区分

动机：Today / 本周 / 本月的总时长应当是**自己决定投入的时间**（额外学习），而不是被安排的上课时间。课表从 `.ics` 文件导入（只做文件导入，不接系统日历），进入一个专门的"课表组"，统计时默认排除。

### 13.1 表结构改动（迁移 0004）

```sql
ALTER TABLE activity ADD COLUMN kind TEXT;        -- NULL = 普通；'schedule' = 课表组（只能是顶层活动）
ALTER TABLE plan     ADD COLUMN skip_dates TEXT;  -- 跳过的日期 'YYYY-MM-DD,YYYY-MM-DD'（如假期），NULL = 不跳过
```

- 两列都可空，旧数据不动。`supabase/schema.sql` 加同样两列（`add column if not exists`），Rust `sync/tables.rs` 与 Swift `SyncTable` 的列表同步加上。
- `activity.kind` 只允许 `NULL` 或 `'schedule'`；带 `kind` 的活动必须是顶层。本机**最多一个存活的课表组**（upsert 校验）；同步可能带来第二个，UI 和统计把所有 `kind = 'schedule'` 的组都当课表，`activity_schedule_ensure` 取 `sort` 最小的那个。
- `plan.skip_dates`：库里和云端存逗号分隔、排序去重的日期文本；Rust command 和 JSON `hope/1` 里是 `string[]`（`skip_dates`，缺省空数组）。只对周期计划有意义，单次计划存 `NULL`。
- `occursOn`（前端）和 `autolog::log`（Rust）都要跳过 `skip_dates` 里的日期：前端不生成那天的 occurrence，Rust 收到也不计入。
- 计划编辑器不提供编辑跳过日期的 UI，但编辑时必须原样传回 `skip_dates`，不能把它清掉；有跳过日时在编辑器里显示一行"跳过 N 天（来自导入）"。
- "重复计划没有单次例外"这条决定仍然成立：`skip_dates` 只是导入时写入的假期，没有"改某一次"。
- JSON 导入导出：`activity.kind`、`plan.skip_dates` 都是可选字段，格式名仍是 `hope/1`。

### 13.2 ICS 解析（前端 `src/lib/ics.ts`，不加依赖）

解析放前端，因为需要时区换算（`Intl`），Rust 侧没有时区库（与 10 F 的分工一致）。Rust 只负责选文件、读文本：`ics_pick() -> Option<String>`（dialog 过滤 `ics`）。

支持的子集：
- 折行（CRLF 后跟空格 / Tab）、属性参数（`DTSTART;TZID=…:…`）、转义（`\,` `\;` `\n` `\\`）。
- `VEVENT` 的 `UID`、`SUMMARY`、`DTSTART`、`DTEND`（或 `DURATION`，支持 `PnDTnHnMnS`）、`RRULE`、`EXDATE`（可多行、可逗号分隔）。
- `RRULE` 只支持 `FREQ=WEEKLY`，`BYDAY`（`MO…SU` 映射到 ISO 1–7）、`UNTIL`（UTC 或本地）、`COUNT`（展开后取最后一次的日期作为 `until`）。`INTERVAL` 缺省或 1；其他 `FREQ`、`INTERVAL ≥ 2`、全天事件（`VALUE=DATE`）、`RECURRENCE-ID` 的事件**跳过并在预览里说明原因**。
- 时间换算：floating 时间原样取钟点；`Z` 结尾按 UTC 转本地；`TZID` 与本机时区（`Intl.DateTimeFormat().resolvedOptions().timeZone`）相同时原样取钟点，不同时把该瞬间换算成本地钟点，并在预览里提示一行"文件时区 X，已换算为本地时间"。`UNTIL` 为 UTC 时先换算到事件自己的时区再取日期（例：`20261205T075959Z` 在 `America/Los_Angeles` 是 12-04）。
- 周期计划的 `date` = `DTSTART` 当天或之后第一个落在 `BYDAY` 里的日期；`until` 来自 `UNTIL` / `COUNT`，没有则 `null`；`skip_dates` 来自 `EXDATE`（只保留落在 `date…until` 内且星期匹配的）。
- 没有 `RRULE` 的事件：同名、同起止钟点的单次事件 ≥ 3 条，且每个出现过的星期至少出现 2 次，就合并成一条周期计划：`date` = 最早、`until` = 最晚、`skip_dates` = 这个星期模式在区间内应出现却没出现的日期。其余单次事件各自成为一条单次计划。
- 每一行的 `source_key` = `UID`（合并出来的周期计划用 `UID` 排序后以 `|` 连接），Rust 用它算确定性 id（下文），重复导入同一份文件是更新不是重复。
- 建议的活动名（可改）：去掉结尾的 section 代码和考试后缀。规则：`/\s*-\s*[A-Z]{2}\d?$/`（`CSE 100-LE` → `CSE 100`）、`/\s*(期末考试|期中考试|Final(?: Exam)?|Midterm)$/i`（`CSE 101 期末考试` → `CSE 101`）。同名的行归到同一个子活动。

### 13.3 导入界面与写入

- 入口：日程页标题右侧 `accessory` 一个「导入 .ics…」按钮。
- 预览 Sheet（沿用 `Sheet.css`）：
  - 标题「导入课表」，副标题：日历名（`X-WR-CALNAME`，没有就用文件名）与条数。
  - 「开始」：`按文件 / 今天 / 自定义`（日期框）；「结束」：`按文件 / 不设结束 / 自定义`。只作用于周期计划（改 `date` / `until`，并丢掉落在新区间外的 `skip_dates`）；单次计划（如期末考试）不受开始 / 结束影响，但落在区间之外的默认不勾选。文件里没有 `UNTIL` 时「按文件」等于「不设结束」。默认都是「按文件」。
  - 课程列表：每行 = 复选框 + 可编辑的活动名 + 说明（周期：`一三五 09:00–09:50 · 9/25–12/4 · 跳过 2 天`；单次：`12/7 11:30–14:29`）。不支持的行灰显、不可勾选、显示原因。
  - 脚注：会放进课表组「课程」（粉色）下并归档（不在开始计时的列表里，上课时间仍自动计入，见 13.7）；按设置排除 / 计入统计。
  - 操作：取消 / 「导入 N 项」。导入完成后用 `dialog_alert` 报告（新建了几个活动、几条计划新增 / 更新），与 JSON 导入一致。
- Rust command `schedule_import(input) -> report`，一个事务：
  - `input = { group_name, courses: [{ name, plans: [{ source_key, date, start_hm, end_hm, rule, auto_log, until, skip_dates }] }] }`。
  - 课表组：`kind = 'schedule'` 的存活顶层活动（归档与否都算）；没有就新建，新建即归档（名字来自前端 i18n `schedule.group`，颜色 `pink`，图标 `graduationcap`；见 13.7）。另有 `activity_schedule_ensure(name) -> Activity` 供设置页用。
  - 子活动：在课表组下按名字（trim 后精确匹配）复用存活的子活动（原样保留，不改归档状态），没有就新建，新建即归档；颜色随父。
  - 计划 id：UUID v5，命名空间 `9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f`，名字 `hope-ics/{source_key}`。存在就更新（按 id upsert），不存在就插入；`auto_log` 默认开。
  - 报告：`{ activities_created, plans_added, plans_updated }`。
- 自动计入沿用 10 F 的规则：计划 `updated_ms` 之前结束的那些次不补记，所以导入上学期开始的课表不会把过去几周补成记录；之后到点才计入。

### 13.3.1 补记已过去的课

10 F 的规则是"新建计划不补出过去的记录"。导入课表是例外：课表里的课默认都去了，所以只要导入的开始日期早于今天，预览 Sheet 里多一行开关「补记已过去的课（视为全部参加）」，默认开，后面显示会补记多少节；开始日期不早于今天时这一行不出现。

- 前端按本地时区算出每条周期计划从 `date` 到今天、已经结束、且不在 `skip_dates` 里的每一次（`{ date, start_ms, end_ms }`），放进 `PlanImportInput.past`（开关关着时为空数组）。单次计划不补记。
- Rust 在 `schedule_import` 的同一个事务里，计划写入后调用 `autolog::log` 的"允许过去"模式记录这些次：跳过 `end_ms <= plan.updated_ms` 的那条规则不生效，其余不变（确定性 id、已有手动记录只补没覆盖的部分、被删过的不再生成、未来的不记）。报告增加 `sessions_logged`。
- 这是唯一会补记过去的入口；`plan_autolog` 命令和 `useAutoLog` 的 30 天回补行为不变。
- 之后再导入同一份文件且开关开着，补记是幂等的，不会重复。

### 13.4 课表组与统计

- 设置「日程」区新增开关「总时长计入课表」（本机设置 `stats.include_schedule`，`"1"` / 缺省 `"0"`），默认**不计入**。脚注说明：课表组下的记录不进总时长，仍在时间线上显示。
- 活动编辑器**没有**「作为课表组」开关（最初有，已按 13.7 去掉）：课表组只由导入器创建。课表组名字旁一个小标签「课表」，它平时在活动页的已归档区里。
- 判定：一条记录的活动本身或其父活动 `kind = 'schedule'` 即为课表时间。`DayEntry` 加 `scheduled: boolean`；`summarizeDay` 接收 `includeSchedule`，返回 `totalMs`（按设置）和 `scheduleMs`（课表时间，始终计算）。`totalsByActivity` / `summarizeDays` / `mergeTotals` 在不计入时把课表记录排除在 `parts` / `totals` 之外。开关的值由 `useToday` / `usePeriod` 读取并传入，所以 Today、本周、本月、Overlay 三张卡全部跟着变，不需要各自处理。
- Today：不计入时，课表记录在环上照画但 40% 不透明度（`RingSegment.dim`），时间线上那一行同样 40% 不透明度、仍可点击编辑；环下方新增一行小字（`--fg-3`）"上课 2 h 30 min"（`today.schedule`），`scheduleMs = 0` 时不显示。
- 本周 / 本月：条形图和活动汇总都不含课表；活动汇总列表末尾加一行灰显的"课程 · X h"（不参与百分比），`scheduleMs = 0` 时不显示。
- 计入时：与现在完全一样，没有任何标记。
- Apple 端：`ActivityRecord.kind`、`PlanRecord.skipDates` 入模型与同步列表；今日总时长（iOS 首页、Watch 列表、表盘快照）排除课表组，暂不做开关（与桌面的默认一致）。`swift test` 必须继续通过。

### 13.5 实施顺序

1. Rust：迁移 0004、`kind` / `skip_dates` 贯穿 db / command / transfer / sync / autolog、`ics_pick`、`schedule_import`、`activity_schedule_ensure`、`supabase/schema.sql`、单元测试、重新导出 bindings。
2. 前端：`ics.ts` 解析、导入 Sheet、日程页入口、`occursOn` 跳过、编辑器保留 `skip_dates`、设置开关、统计过滤与 Today / 周 / 月 / Overlay 的显示、活动编辑器开关、zh-CN 与 en 文案。
3. Apple：两列入模型、同步列表、今日总时长排除课表。
4. 用 `fall2026.ics` 实测：7 条周期 + 4 条单次导入，日程页显示，11/11、11/26、11/27 不出现，Today 的课被排除。

### 13.6 实现时定下的细节

- ~~课表组被归档后再导入：`schedule_ensure` 自动取消归档~~（已被 13.7 取代：课表组本来就是归档的，导入不改它的归档状态）。有多个组时优先未归档、`sort` 最小的。
- 文件时区与本机不同时，整条周期计划按首次换算后的本地钟点和星期平移（例：洛杉矶周一三五 09:00 在上海是周二四六 00:00），夏令时切换后的偏差不单独处理。
- `PlanInput.skip_dates` 在 TS 里是必填，编辑器不可能漏传而把假期清掉；周期计划改成单次时清空。
- 导入时课名相同的行合并为一个子活动；一门课的讲座、讨论、期末考试默认都归到课程代码（`CSE 100`）下。

### 13.7 课表活动一律归档

课只会从课表自动计入，没有人对一门课按开始计时。所以课表组和它下面的课程子活动**创建时就是归档状态**，并一直保持归档。归档的含义不变：不出现在开始计时的选择、托盘菜单和活动页主列表里，但记录照常计入统计。这正是课表需要的，换学期也一样：旧课程留在归档里，记录都还在。

- 写入：`schedule_ensure`（`schedule_import` 与 `activity_schedule_ensure` 共用）新建课表组时 `archived_at = now`，与创建同一次写入（一个 `updated_ms`，一行 dirty）；已有的课表组原样返回，**不再自动取消归档**。新建的课程子活动同样归档；按名字复用的已有课程原样保留，不归档也不取消归档。
- 活动编辑器去掉「作为课表组」开关，课表组只由导入器创建和管理；编辑已有课表组（改名、改色）时原样传回 `kind`。`activity_upsert` 对 `kind` 的校验（`NULL` 或 `'schedule'`、只能顶层、本机最多一个）保留，因为 JSON 导入和同步仍可能带来它。
- 活动页：主列表与 Rust `activity_list(false)` 一致，归档父活动的子活动随父隐藏。已归档区里，归档的父活动下缩进显示它的子活动（课表组下就是各门课），课表组带「课表」标签。顶层行可以「恢复」（允许，什么都不会坏；之后导入也不会再把它归档）；缩进的子行没有恢复按钮，因为父活动仍归档时它恢复了也看不到。父活动没归档、自己被归档的子活动仍以「父 · 子」单独列出，可以恢复。
- 计划编辑器、记录编辑器的活动选择 = 未归档的活动 ∪ 当前计划 / 记录的活动（是子活动时连同父活动），所以编辑课表计划或上课记录时活动仍显示、保存时不变；新建时只有未归档的活动可选。
- 自动计入（`useAutoLog`、`autolog::log`）、统计、日程页和 Today 的计划显示都不看归档状态，不受影响。前端 `scheduleGroup` 与 Rust `schedule_group` 取法一致（归档的组也算，未归档优先），所以本周 / 本月的"课程"行和导入 Sheet 照常找到课表组。
- 导入 Sheet 的脚注写明：课程会放进课表组并归档，不在开始计时的列表里，上课时间仍自动计入。
- 不变：删除规则（有记录的活动只能归档，没有记录的才真正删除）、`activity.kind`、「总时长计入课表」开关。

## 14. 阶段 11：离开提醒（计时中人走开了）

计时的多半是坐着做的事（工作、阅读……）。人带着手机走远了，大概率是忘了关计时。系统在合适的时机问一句，而不是让记录一直跑。运动类活动不问。检测只在 iPhone 上做：计时不管在哪台设备上开的，手机都跟着人走；手表只接收 iPhone 镜像过来的通知，不做检测（watchOS 普通 app 不能在后台定位）。

### 14.1 表结构改动

- `activity.kind` 允许 `'exercise'`（运动类）。规则同课表组：只能是顶层活动，子活动随父；`validate_kind` / `check_kind` 放行它（"本机最多一个"的限制只针对 `'schedule'`）。`kind` 已是 TEXT 列，不需要迁移，Supabase 不用改。
- 活动编辑器：顶层、非课表的活动加一个「运动类（离开时不提醒）」开关，写 `kind = 'exercise'`；活动页列表给运动类一个小标签。
- Apple：`ActivityRecord.isExercise`；"计时的活动或其父活动 `kind = 'exercise'`"即运动类，与课表的判定方式一致。
- JSON 导入导出原样带 `kind`，格式名仍是 `hope/1`。

### 14.2 iPhone：离开开始计时的地方

- 设置（iPhone 账号页）：「离开时提醒」开关，默认关。打开时依次申请通知权限和定位权限，定位要到「始终」——围栏退出事件要在后台唤醒 app，「使用期间」做不到；任一被拒，开关回弹并说明原因。
- 锚点：每当 iPhone 得知一段计时开始（本机开始，或同步拉到别的设备开始的 session），且活动不是运动类、不是课表：取一次当前位置作为锚点（`requestLocation`，百米级精度即可），记 `(sessionId, 经纬度, 时间)`。暂停、结束、换活动都清掉锚点。别的设备开始的计时原本只在 iPhone 下一次拉取时才知道；2026-10-15 起手表每次计时状态变化都通过 WatchConnectivity 的 application context 发一条「计时信标」（`TimerBeacon`），iOS 会在后台拉起手机 app 接收，手机随即 `syncNow()` 拉到这段 session 并在当时所在位置取锚点——对只用手表开计时、从不打开手机 app 的用法这是唯一能响的方式。桌面开的计时仍要等手机 app 打开。
- 检测：以锚点为圆心、300 米为半径建一个 `CLMonitor` 圆形条件，退出事件即"走出 300 米"，系统在后台唤醒 app 处理。iOS 不允许普通 app 在后台每 5 分钟醒一次，所以"每 5 分钟检测一次"用两条规则达到同样效果：(1) 退出事件到达时立即处理；(2) app 因任何原因被唤醒或回到前台时，若距上次检查 ≥ 5 分钟，查一次当前位置到锚点的距离。两条都受下面的节流约束。
- 节流：同一段计时，两次提示间隔 ≥ 5 分钟。「30 分钟内别提醒」把 `snoozeUntil` 设为 now + 30 min，期间退出事件忽略；到期后下一次检查若仍在圈外，再提示一次。
- 提示：本地通知。标题「你离开了开始计时的地方」，正文「「工作」已计时 1 h 12 min」。三个操作按钮，都在后台处理、不打开 app：
  - 继续计时：锚点换成当前位置并重建围栏（已经换了地方，就以新地方为准）。
  - 结束：`stop()` 结束当前 session 并立即推送同步；清锚点。
  - 30 分钟内别提醒：设 `snoozeUntil`。
  - 滑掉通知不处理 = 继续计时，但不换锚点。
- 功耗：围栏由系统用基站 / Wi-Fi 维护，接近零；只在计时开始和「继续计时」时各取一次位置。不开持续定位、不开计步或运动类型更新。
- 状态存 iPhone 本地（`UserDefaults`），不同步：锚点、上次检查时间、`snoozeUntil`、上次提示时间。

### 14.3 桌面端：不做

曾考虑用"电脑 5 分钟无输入、回来时询问"做桌面端的对应物，放弃：没输入不等于人走了——人可能正拿着 iPad 在旁边学习，或在学校的 Mac 上开了计时后回家用 Windows，回到任一台电脑时它都会误报。离开与否只有随身的手机说得准。

### 14.4 实施顺序

1. 表结构与编辑器：`kind = 'exercise'` 贯穿 Rust 校验、编辑器开关与标签、Apple 模型、i18n；`cargo test`、`swift test`。
2. iPhone 离开地点：权限申请、锚点与围栏、通知与三个操作、节流。决策逻辑写成纯函数进 HopeCore（输入：锚点、当前位置、`snoozeUntil`、上次提示时间 → 输出：提示 / 忽略），`swift test` 覆盖。
3. 真机验证：走出 300 米收到通知；三个按钮各一次；30 分钟勿扰到期后再提醒一次；在手表上按「结束」后桌面 Overlay 收敛。

### 14.5 实现时定下的细节（iPhone）

- 规则在 HopeCore 的 `AwayReminder`（纯函数 + `State`，`swift test` 覆盖）；iPhone 的 `AwayMonitor` 只负责定位、围栏、通知和持久化（`UserDefaults` 的 `away.enabled` / `away.state`）。
- `AwayMonitor` 在 `HopeApp.init` 里创建并设为通知代理：围栏事件和通知按钮都可能在后台把 app 拉起来，那时必须已经有人在听。围栏用 `CLMonitor("HopeAway")` 的一个圆形条件，事件流在 app 启动时就开始监听。监视器名字只能是字母和数字——带点的 `"hope.away"` 在真机上让 `CLMonitor.init` 断言崩溃，而且开关一旦存为开，每次启动都崩（2026-10-14）。
- 锚点时机 = 本地库的 `revision` 变化（本机操作或同步拉取），有非运动、非课表的 running session 且 id 与锚点不同就取一次位置；没有 running 就清锚点并移除围栏。
- 围栏退出事件到达时**不再取定位**：事件本身就是测量结果（按 301 米处理），只走节流判断就发通知。后台拉起只有几秒，等 `requestLocation` 常常等不到。取锚点、检查、发通知都包在 `beginBackgroundTask` 里。
- 关键节点打 `os.Logger`（subsystem `io.github.dan9574.hope`，category `away` / `break` / `link`），真机上用 Console.app 或 `log collect` 能看到锚点、围栏事件、提示 / 跳过原因。
- 「继续计时」只换锚点坐标，保留 `lastPromptMs`，所以紧接着再走出去也要等满 5 分钟。「结束」在后台 `stop()` 后 `syncNow()`，等 3 秒再让系统结束这次后台启动。
- 开关在 iPhone 的账号页；打开时先要通知权限，再要定位「使用期间」→「始终」。只有「使用期间」时围栏不会在后台唤醒 app，页面上写明。
- 通知文案和按钮走 `Localizable.xcstrings`（中英）；Info.plist 的两条定位用途说明只有英文。

### 14.5.1 定下的参数

300 米、5 分钟（两次检查 / 提示的最小间隔）、30 分钟（勿扰）都是常量，不进设置；做出来按体感再调。多算的时间 = 走出 300 米本身的几分钟加上检查延迟。

## 15. 阶段 12：休息提醒（连续计时满 90 分钟）

动机：学习、工作一坐就是几小时。累计计时每满 90 分钟，提醒一句"歇一歇"，用户选暂停或继续。不管计时是在哪台设备上开的都要提醒；三端都可能知道这段计时，所以按**手表 → 桌面 → iPhone** 的顺序错开，高优先级的提醒成功了，后面的尽量不再弹。

### 15.1 表结构改动（迁移 0005）

```sql
ALTER TABLE session ADD COLUMN break_ack_ms INTEGER;  -- 最近一次在休息提醒上点「再来一会儿」的时刻，NULL = 没有
```

- 可空，旧数据不动。`supabase/schema.sql` 加同一列（`add column if not exists`，**要在 SQL Editor 里执行**），Rust `sync/tables.rs` 与 Swift `SessionRecord.row()/decode` 的列表加上，JSON `hope/1` 里是可选字段 `break_ack_ms`，格式名不变。
- 写在**当时正在运行的那一段** session 上，和 `end_ms` 一样是普通的同步写（`updated_ms` 前进、`dirty`）。读的时候看整条暂停链里最大的 `break_ack_ms`。
- 它是"用户已经看见并选择继续"的标记，不是"已经弹过"的标记：通知弹出时 app 多半没在运行，写不了库；只有用户点了按钮，app 才被拉起来写。

### 15.2 规则（三端共用，Swift 在 HopeCore `BreakReminder`，Rust 在 `db/break_reminder.rs`，都是纯函数 + 测试）

- 计数 = 暂停链累计时长（不含暂停），即计时器上显示的那个数。第 N 次提醒（N = 1, 2, 3…）在累计满 N × 90 分钟的那一刻到期，记作 `due_N`。暂停不清零：暂停 20 分钟再继续，计数接着算（和计时器显示一致；"长暂停算休息、重新计数"想过，没做，因为那样计时器上的数字和提醒对不上）。
- 不提醒：运动类（`kind = 'exercise'`，含子活动）、课表组及课程。判定和 14.1 / 13.4 一致。
- 已处理：链上有 `break_ack_ms ≥ due_N`，第 N 次就算处理过，不再弹。点「再来一会儿」通常发生在 `due_N` 之后、`due_N+1` 之前，所以只消掉第 N 次；用户拖到第 N+1 次到期后才点，两次一起消掉，可以接受。
- 结束、换活动 = 链结束，一切作废。暂停 = 暂时取消，恢复后按剩余时间重排（`due_N - 已累计`）。
- 每端的提醒时刻 = `due_N + 本端偏移`：手表 +0、桌面 +1 分钟、iPhone +2 分钟。

### 15.3 手表（第一优先）

- 手表 app 每次本地写入或拉取后（`revision` 变化）重算：有可提醒的 running session 就用 `UNTimeIntervalNotificationTrigger` 预排**接下来最多 4 次**（90 / 180 / 270 / 360 分钟）本地通知，标识 `hope.break.<链首 id>.<N>`；系统到点自己弹，app 挂起也行，不需要后台运行权限。没有 running 就全部撤掉。
- 通知两个按钮，都在后台处理、不打开 app：「暂停」= `pause()` + `syncNow()`；「再来一会儿」= 在当前 running 段写 `break_ack_ms = now` 并推送。滑掉不处理 = 继续，不写标记（下次到期还会提醒）。
- 开关在活动列表底部（手表没有设置页），**手表默认开**（计时都在手表开）：第一次有可提醒的计时时才申请通知权限。开关下面一行状态：「下次提醒 HH:MM」/「没有在计时」/「通知权限已关」/「运动类和课表不提醒」，用户一眼能看出有没有排上。
- 每次排完，通过 WatchConnectivity `updateApplicationContext(["timer": 信标, "break": 认领])` 告诉 iPhone 当前计时和"链 X 的这几次我接了"（只报系统真正接受的那几次；2026-10-14 曾把 add 失败的也报上去，手机因此把兜底删了）。application context 是整体替换的，所以两个 key 每次一起发。重排必须串行：曾出现前一轮在查待弹时挂起、后一轮已加好、前一轮醒来把它们全删掉的竞态。

### 15.4 桌面（第二）

- 依赖：`tauri-plugin-notification`（官方插件，macOS / Windows 走系统原生通知）。自己写要分别调 UserNotifications 与 WinRT toast，不值得。桌面通知**没有按钮**，点击只是打开 app，所以桌面不能写 `break_ack_ms`。
- Rust `break_reminder.rs` 在 app 内起一个线程，每 15 秒查一次 running session（桌面每 5 秒拉一次同步，任何地方开的计时它几秒内都知道）：到了 `due_N + 1 分钟`、链上没有 `≥ due_N` 的 ack、本机没弹过这一次，就弹。"本机弹过"记在本地 `setting` 的 `break.notified = "<链首 id>:<N>"`，防止重启后重弹。
- 文案由前端在启动和换语言时用 `break_set_strings` 送进来（和托盘菜单 `tray_set_strings` 同一套路，所有文案仍在 i18next 文件里）。
- 设置 → 通用：「休息提醒」开关，默认开，存 `break.enabled`。macOS 首次弹时系统会问通知权限。

### 15.5 iPhone（第三）与手表的去重

- 同一个 `BreakScheduler`（放 `apple/Shared/`，两端共用）在 iPhone 上以 +2 分钟偏移排本地通知，按钮和处理与手表相同。开关在账号页，默认关，和离开提醒并列。
- 去重：收到手表的 application context 后，把手表已接的那几次从本机待弹里撤掉，并记住手表的声明（链首 id + 到期时刻，`UserDefaults`），之后再排同一条链时跳过这些。iOS 在手机 app 没运行时会把它在后台拉起来接收 WatchConnectivity 数据，所以不依赖用户打开手机 app。手表 app 不运行时不会收到 iPhone 的任何东西——方向是单向的，手表只发不收。
- 手机兜底弹出的通知，在手机锁屏、手表戴着时会被 iOS 自动转到手表上显示——所以"手表不知道这段计时"时，提醒最终还是先到手腕。
- iPhone 上 `AwayMonitor` 和 `BreakScheduler` 都要收通知按钮，但 `UNUserNotificationCenter` 只有一个代理：加一个 `NotificationRouter`（`apple/Shared/`）按 category 分发，两边注册自己的 category。手表 app 也用它。

### 15.6 做不到、接受下来的事

- 手表和 iPhone 只在 app 打开时才同步。桌面开的计时，手表 app 没打开过就不知道，就不会提醒；此时桌面会弹，手机也只有打开过才会弹。要彻底解决需要推送或 Realtime（7b），本阶段不做。
- 桌面不知道手表弹过没有（手表弹的那一刻 app 没在运行、写不了库），所以桌面在 +1 分钟照弹；只有用户在手表上点了「暂停」（链结束，5 秒内同步到）或「再来一会儿」（`break_ack_ms` 同步到）桌面才不弹。桌面和手腕是两个不同的地方，同时各提一句可以接受。
- 桌面弹了之后手机在 +2 分钟仍会弹（桌面写不了 ack），除非手表已经通过 WatchConnectivity 把它消掉。

### 15.7 实施顺序

1. 迁移 0005、`tables.rs`、Swift 列表、JSON `hope/1`、`supabase/schema.sql`；`cargo test`、`swift test` 的往返测试。
2. 规则：Rust `db/break_reminder.rs` 与 Swift `BreakReminder`（输入：链首 id、累计时长、ack、now → 输出：接下来各次的到期时刻 / 哪些已处理），两边测试同一组用例。
3. 手表：`BreakScheduler` + `NotificationRouter` + 开关 + WatchConnectivity 声明。模拟器上验证通知到点弹出、两个按钮。
4. 桌面：插件、Rust 线程、`break_set_strings`、设置开关；macOS 上验证。
5. iPhone：同一个调度器 + 去重 + 账号页开关；`AwayMonitor` 改走 `NotificationRouter`。
6. 真机：手表开计时满 90 分钟（测试时可临时把常量改短）收到提醒；手机不重复弹；桌面 +1 分钟弹；在手表点「暂停」后桌面与手机都安静。

### 15.8 定下的参数与文案

- 90 分钟、+1 / +2 分钟偏移、预排 4 次、桌面 15 秒轮询都是常量，不进设置。
- 标题「歇一歇」，正文「「工作」已连续 1 h 30 min」；英文 "Take a break" / "Work has been running for 1 h 30 min"。按钮「暂停」「再来一会儿」/ "Pause" "Keep Going"。时长格式用 `DurationFormat.duration`（与 Today 一致）。

## 16. iPhone v1（待写）

等 iPhone 的视觉方向定下来再写（issue #15）：四个 Tab 与每页内容、今天按起床 / 睡觉日、翻看过去的天。

## 17. 账号体系（2026-11-06 定）

公开发布前账号要补三件事：注册要验证邮箱、忘了密码能找回、能在 app 里删除账号（App Store 对有注册功能的 app 的硬性要求）。三端共用同一套请求。

### 17.1 范围

- 登录方式只有邮箱 + 密码。不做 Apple / Google 登录：App Store 只在提供了第三方登录时才要求同时提供 Apple 登录；加了之后 Windows 端还要另做一套网页授权。
- 注册和找回都用邮件里的 **6 位验证码**，不用链接：桌面和手机都没有能接住回跳链接的页面（12.4 时代点链接会落到一个报错页）。
- 入口在桌面「设置 → 同步」和 iPhone 账号页。手表不做注册 / 找回 / 删号，登录态照旧由 iPhone 交接。
- 不做：改邮箱；已登录状态下改密码（走一遍找回即可）。

### 17.2 Supabase 后台（用户操作，写进 `supabase/README.md`）

- Authentication → Email：Confirm email 开；最短密码 8；验证码有效期 600 秒；重发间隔 60 秒。
- 邮件模板 Confirm signup 与 Reset password 的正文改为显示 `{{ .Token }}`，不放链接。
- 自定义 SMTP（Resend，发件域用自己的域名）。自带邮件每小时只发几封，公开注册会卡住。
- SQL Editor 重新执行 `supabase/schema.sql`（带上 17.5 的函数和外键）。

### 17.3 请求（Rust `sync/http.rs` 与 Swift `Sync/Supabase.swift` 逐条一致）

| 动作 | 请求 | 结果 |
|---|---|---|
| 注册 | `POST /auth/v1/signup` `{email, password}` | 带 `access_token` = 项目没开确认，直接登录；否则进入输入验证码。返回的用户 `identities` 是空数组 = 邮箱已注册（GoTrue 为防枚举不报错），按 `user_already_exists` 处理 |
| 验证注册 | `POST /auth/v1/verify` `{type: "signup", email, token}` | 会话，按 12.4 登录 |
| 重发注册验证码 | `POST /auth/v1/resend` `{type: "signup", email}` | |
| 找回密码 | `POST /auth/v1/recover` `{email}` | 邮箱不存在也返回成功 |
| 重设密码 | `POST /auth/v1/verify` `{type: "recovery", email, token}`，再 `PUT /auth/v1/user` `{password}`（Bearer） | 会话，按 12.4 登录 |
| 删除账号 | `POST /rest/v1/rpc/delete_account`（Bearer） | 204 |

- 验证码只能用一次。重设密码时验证通过后把这次的会话留在内存里（按邮箱 + 验证码）；改密码这一步失败（比如密码太弱）用户换一个密码重试时不再验证。
- 注册和重设前客户端先检查密码长度 ≥ 8，不够直接报 `weak_password`，不发请求。
- 验证后发现这台设备上次同步的是另一个账号：照 12.4 弹确认；确认后用邮箱 + 密码走一次普通登录（验证码已经用掉，账号此时已可登录）。
- 登录时遇到 `email_not_confirmed`（注册到一半关掉了 app）：直接进入输入验证码，可以重发。
- 新增错误码 `invalid_code`（GoTrue 的 `otp_expired`：验证码错误或已过期）。

### 17.4 删除账号

- 云端函数 `delete_account()`：`security definer`、`search_path = ''`，只 `grant execute to authenticated`。删掉 `auth.uid()` 在五张表里的所有行，再删 `auth.users` 里这一行（它的会话、刷新令牌随之删除）。未登录调用报错。
- 五张表的 `user_id` 加外键 → `auth.users(id) on delete cascade`（`not valid`，不检查已有的行）。原因：账号删除后，别的设备手里的 access token 最长还有 1 小时有效，没有外键它们还能继续往里写，留下没有主人的数据。有了外键这些写入会被拒绝。这是 12.1「无外键」的唯一例外（表与表之间仍然没有外键）。
- 客户端：确认对话框写明后果（云端的账号和全部记录永久删除、其他设备不能再同步、这台设备上的记录保留）→ 调 RPC → 本机等同退出登录，并清掉 `sync.user_id` / `sync.email` / `sync.last_ok_ms`，这样之后登录任何账号都不会再问「切换账号」，本机记录在下次登录时全部重新上传。iPhone 同时通知手表退出。
- 其他设备：刷新令牌已失效，下次刷新时显示「登录已过期」；本地记录都在。

### 17.5 界面

- 桌面「设置 → 同步」未登录时四种状态：邮箱 + 密码（多一个「忘记密码？」）；输入验证码（注册后）；填邮箱发验证码（找回）；验证码 + 新密码。验证码页都有「重新发送」和「返回」。登录后多一行「删除账号…」。
- iPhone 账号页同样四种状态和「删除账号」；验证码输入框用 `.oneTimeCode`，系统会从邮件 / 短信里自动提示。
- 文案：桌面 `sync.*`（`zh-CN` / `en`），Apple `Localizable.xcstrings`。

### 17.6 测试

- Rust：本地起一个只认这几条路径的假 GoTrue（`std::net`，不加依赖），断言每个请求的方法、路径、头、JSON；错误码映射。
- Swift：`FakeHTTP` 断言同样的请求形状；`SyncService` 走通验证注册、重设密码（含改密码失败后重试不再验证）、删号后本地状态。

## 18. 发布范围：先美国版，再国内版（2026-11-06 定）

- **美国版（先做）**：App Store 只勾美国。Supabase 项目放美国西部区域，公开前升 Pro（免费档闲置会被暂停）。欧洲和英国先不上：要声明经营者身份、满足 GDPR 的条款与代表人要求，而以后要加只是在 App Store Connect 里多勾几个地区，不用改代码。
- **国内版（第二个版本）**：不是多勾一个地区，是另一套部署。Supabase 云没有大陆区域、从大陆访问不稳定，大陆上架还要 ICP 备案。做法是在大陆的云上自架 Supabase，同一份代码换构建配置里的服务器地址和密钥。两边账号不通，搬数据靠 3.3 的 JSON 导入导出。
- 为了国内版以后便宜，现在守住两条：
  1. 客户端只用 GoTrue、PostgREST 和 `supabase/schema.sql` 里的 SQL（自架版都有），不用只有 Supabase 云才有的功能。
  2. 服务器地址和密钥只出现在构建配置里（`.env` / `Supabase.generated.xcconfig`），代码里不写死。
- 国内版的登录方式（多半是手机号 + 短信）到时再定；届时只换第 17 节的注册 / 找回这一层，同步协议不动。
