# Tracks 当前待办与状态（合并版）

> 审计基线：`ff92434 Keep stored disc totals in Get Info`
> 审计日期：2026-10-29
> 本文档合并自 `TODO/library01.md`、`TODO/library01answer.md`、`TODO/MPD_TODO.md`、
> `TODO/review01.md`、`TODO/settings.md`、`TODO/window.md`。旧文档已删除，本文件是
> 当前唯一的 backlog。

## 结论

- **媒体库安全方案已基本落地**：Quick Scan、Full Scan、缺失审核、Relocate、禁用/两阶段删除、
  SQLite Online Backup、运行时缺失提示都已实现。
- **MPD 仍有明显协议缺口**：稳定队列 ID 和大部分 idle 状态源已修，但空壳命令、`stats`
  占位值、主线程同步、过滤器/`lsinfo`/`update`/权限与版本号声明仍需处理。
- **Settings 重设计基本完成**：侧边栏分组、字体层级、卡片/表单规范、渐进展开已经存在；
  剩余工作主要是把 `AudiaApp.swift` 里的设置域拆成独立 View。
- **窗口拖动已改为原生 `performDrag`**：旧的碰撞、磁吸、12pt breakaway 和
  `WindowDragConstraint.swift` 都已删除；旧的 `window.md` 不再适用。
- **最近一次全量审查的 13 项问题**：已修 3 项，部分修复 1 项，仍未关闭 9 项。

### 文档级审计计数

按合并后的主题条目计数（`library01answer.md` 没有独立有效条目，不重复计数；
`review01.md` 的 MPD 条目已并入 MPD 主题，不重复计数）：

| 来源 | 完成/已解决 | 部分完成 | 未开始 | 过时 | 小计 |
|---|---:|---:|---:|---:|---:|
| `library01.md` | 9 | 2 | 1 | 0 | 12 |
| `MPD_TODO.md` | 1 | 4 | 12 | 0 | 17 |
| `review01.md` | 3 | 1 | 2 | 0 | 6 |
| `settings.md` | 5 | 1 | 1 | 0 | 7 |
| `window.md` | 2 | 0 | 0 | 1 | 3 |
| **合计** | **20** | **8** | **16** | **1** | **45** |

状态说明：**完成**表示当前源码已实现且已有验证；**部分**表示主路径可用但仍有明确缺口；
**未开始**表示尚未实现或尚未做决策；**过时**表示旧方案已被替代，不再作为待办。

补充：最近一次全量审查的 13 项问题单独计数为 **3 已修 / 1 部分 / 9 未修**。这 13 项与上面的
45 项有交叉（例如 MPD、私有 API），下表会在对应位置标注，不重复累加。

---

## 1. 媒体库

### 1.1 已完成的行为基线（不要回退）

以下内容来自 `library01.md`，当前源码已经实现，后续修改应保持这些语义：

- **Quick Scan**
  - 启动时自动执行，和 Settings 里的 Quick Scan 走同一策略。
  - 只发现并导入数据库中尚未存在的新文件。
  - 不重新解析已有文件，不检查缺失，不删除任何数据库记录。
  - 实现位置：`Library.rescanAll()` / `Library.rescan(_:)` 使用
    `LibraryScanner.scan(mode: .quick)`；`LibraryScanner.enumerateFiles` 对已知路径直接跳过。
- **Full Scan**
  - 扫描前验证根目录存在、可读、目录遍历完整；不检查卷标、卷 UUID 或文件系统身份。
  - 导入新文件；只对 mtime 或 file size 变化的已有文件重新读取 metadata。
  - 收集“数据库中存在、但本次完整遍历没有发现”的歌曲，生成缺失报告。
  - 不自动删除缺失记录；没有缺失时不弹审核窗口。
  - 实现位置：`Library.fullScan(_:)`、`LibraryScanner.scan(mode: .full)`、
    `LibraryDatabase.missingSongIDs(libraryID:discoveredPaths:)`。
- **缺失审核窗口**
  - 可搜索歌曲名、艺人、专辑、路径；支持 Select All / Deselect All。
  - Full Scan 左侧按钮是 **Keep**；Relocate 左侧按钮是 **Cancel**。
  - 只有用户勾选的条目才会从 Tracks 索引和 playlist item 中删除。
  - 实现位置：`MissingFilesReviewView`。
- **Relocate（外部库换位置）**
  - 按旧根目录下的**完整相对路径**匹配，不做 basename 猜测。
  - 先生成预览：匹配数、未匹配数、新位置额外文件数；不立即改数据库。
  - 无未匹配项时直接迁移；有未匹配项时复用缺失审核窗口。
  - Cancel 不改变库根或歌曲路径；未勾选删除的歌曲也会更新到新根下的相对路径，
    即使目标文件当前缺失。
  - 更新库路径、歌曲路径和删除选中项在 SQLite transaction 内；提交前先做
    SQLite Online Backup。
  - 额外文件随后作为新歌导入；Song ID、playlist、播放次数、stars、history、queue
    关联保持不变。
  - 实现位置：`Library.previewRelocation`、`Library.applyRelocation`、
    `LibraryRelocationMatcher`、`LibraryDatabase.relocateLibrary`。
- **禁用 / 启用外部库**
  - `libraries.enabled` 持久化；禁用只改来源级状态，不批量改写歌曲、playlist item、
    播放次数或 stars。
  - 禁用时停止播放、清空整个播放队列和播放历史；这些动作作用于全局播放器状态。
  - 禁用来源的歌曲在所有内容位置隐藏；playlist item 仍保留，重新启用后恢复。
  - Settings 中仍能看到禁用库，可重新启用或删除。
  - 实现位置：`Library.setExternalLibrary(_:enabled:)`、`PlayerState.stopAndClear()`、
    `PlayerState.clearHistory()`、`LibraryDatabase.setLibraryEnabled`。
- **两阶段删除外部库**
  - 只有禁用状态才显示红色 Delete；点击后还有第二次破坏性确认。
  - 删除前用 SQLite Online Backup 生成带毫秒时间戳的备份；备份失败则中止。
  - 删除在一个 transaction 内按 `library_id` 删除歌曲、playlist item，并清理无引用
    album/artist；不删除音频文件。
  - 用户创建的 playlist 即使变空也保留。
  - 实现位置：`Library.deleteDisabledExternalLibrary`、`LibraryDatabase.deleteLibraryAndSongs`、
    `LibraryDatabase.backup`。
- **运行时缺失文件**
  - 缺失状态只保存在 `PlayerState.missingFileIDs`，不写数据库。
  - 播放前检查父目录和文件可读性；区分“文件不存在”和“不可访问/权限/网络错误”。
  - 单曲缺失显示叹号并跳过；连续 100 首确认缺失时暂停并提示外置存储可能断开；
    成功播放后计数归零。
  - 只在 AVPlayer 确认 `readyToPlay` 后记播放次数和历史。
  - 歌曲表、专辑详情、播放列表行已有缺失图标。
  - 实现位置：`PlayerState.beginCurrentTrack`、`PlayerState.tick`、
    `PlayerState.handleMissingFile`、`MissingFileStreak`。
- **数据库与测试**
  - `songs.library_id`、`libraries.enabled` 已存在；当前 schema 不支持旧库自动迁移，
    这是明确决定（`createSchema()` 只定义当前 schema）。
  - 21 个测试覆盖：Quick/Full Scan、mtime/size 变化、目录名伪装成音频扩展名、
    disable/restore、备份/Relocate/删除、缺失连续计数、多 disc、稳定 MPD ID 等。

### 1.2 媒体库剩余项

| ID | 优先级 | 项目 | 状态 | 说明 |
|---|---|---|---|---|
| L11 | P2 | 数据库批量写入和内部删除的 transaction/rollback | 未开始 | `LibraryDatabase.sync` 只 `BEGIN`/`COMMIT`，不检查单条 upsert 失败也不 `ROLLBACK`；`deleteSongs` 未包 transaction；`Library.deleteSongs` 先把文件移到废纸篓再删索引，数据库失败时可能文件已移走、索引还在。建议复用 `relocateLibrary`/`deleteLibraryAndSongs` 的 `executeThrowing` + `ROLLBACK` 模式，并把内部删除改成“先确认数据库可写/事务，再移文件”或明确失败报告。 |
| L7 | P3 | Relocate 冲突预览 | 部分完成 | 当前已按完整相对路径匹配，并 canonicalize 符号链接；但预览没有显式列出“两个旧歌曲映射到同一新路径”、大小写差异、目标路径冲突。数据库 unique path + transaction 会回滚，但用户看不到原因。建议在 `LibraryRelocationMatcher` 返回冲突列表并加测试。 |
| L12 | P3 | 媒体库缺失 UI 的自动化覆盖 | 部分完成 | `MissingFileStreak` 有单测；缺失图标、100 首暂停提示、Full Scan 审核窗口、Relocate 审核窗口仍主要靠手工验证。 |

---

## 2. MPD 协议

当前 MPD 已有：播放控制、队列增删改、音量（含系统音量锁定）、random/repeat/consume、
封面、库读取与基本 find/search/list/count、存储播放列表 CRUD、输出枚举/切换、密码、
idle/noidle、command list、稳定队列 ID。

### 2.1 主题状态

| ID | 优先级 | 项目 | 状态 | 说明 |
|---|---|---|---|---|
| M1 | — | 稳定队列 song id | 完成 | `QueueEntry.id`、`nextQueueID` 持久化；`status.songid`/`nextsongid`、`playlistinfo`、`playlistid`、`plchangesposid`、`deleteid`/`moveid`/`seekid`/`playid` 已按 ID 工作；非法 ID 返回 `ACK 50`。 |
| M2 | P1 | idle 覆盖所有状态源 | 部分完成 | 已观察 `PlayerState` 的队列、当前曲目、播放状态、音量/静音、shuffle/repeat，以及输出设备和 `Library.playlists`；App UI 操作能触发事件。缺口：扫描开始/结束没有 `update` / `database` 事件；`libraryDidChange` 目前只在切换数据库时 post。建议观察 `Library.isScanning` 或扫描完成统一 post，避免和 MPD 命令路径重复发事件。 |
| M3 | P1 | playlist 版本号语义 | 部分完成 | 队列变化会递增 `playlistVersion`，但 `plchanges` / `plchangesposid` 不解析请求版本，总是返回全量；`play` 命令还会无条件 `bumpPlaylist()`，即使队列没变。需要只在队列结构变化时递增，并至少正确处理“版本已是最新”的情况。 |
| M4 | P1 | 能力声明与空壳命令 | 未开始 | greeting 仍是 `OK MPD 0.24.0`，但 `channels`/`subscribe`/`unsubscribe`/`sendmessage`/`readmessages`、`mount`/`unmount`/`listmounts`、`partition` 直接返回 `OK`；`commands` 仍列出部分空壳；`notcommands` 恒为 `OK`。要么补齐，要么降低 greeting/能力声明，让未实现命令返回明确 ACK。 |
| M5 | P1 | MPD 命令主线程同步 | 未开始 | `MPDClientSession.executeOnMain` 仍使用 `DispatchQueue.main.sync` 进入 `@MainActor` 的 `MPDServer.execute`；搜索、列表、全库读取等重查询会阻塞 UI。建议把只读查询/响应格式化移出主线程，状态修改仍由明确的 actor 隔离。 |
| M6 | P2 | 过滤器语法 | 未开始 | 只支持 `==` 和隐式 `TAG VALUE`；缺 `!=`、`contains`、`starts_with`、`=~`、`!~`、括号、`!`、`AND`、`base`、`modified-since`、`added-since`、`AudioFormat`、`prio`。`find` 目前也不区分大小写。`find`/`search`/`findadd`/`searchadd` 不支持 `sort` / `window`；`list`/`count` 不支持 `group`，`list` 不支持 `window`。 |
| M7 | P2 | `lsinfo` 目录语义 | 未开始 | 当前根目录平铺全部歌曲 + playlist；子目录递归返回全部匹配歌曲。MPD 期望只返回直接子项：`directory:`、`file:`、`playlist:`；`listall`/`listallinfo` 才保持递归。 |
| M8 | P2 | `update` / `rescan` | 未开始 | 忽略 `[URI]` 参数；`updating_db` 恒为 `1`；扫描期间 `status` 恒带 `updating_db: 1`；完成后没有 `update` / `database` 事件。需要真实 job id、扫描状态和完成通知。 |
| M9 | P2 | URI 形式 | 未开始 | 当前 `file:` 使用绝对路径。需要决定是改成相对 `music_directory` 的 URI，还是保留绝对路径并在 README/本文件记录 deviation，确认目标客户端可接受。 |
| M10 | P2 | `status` / `stats` 字段 | 未开始 | `status` 缺 `partition`、`xfade`、`mixrampdelay`、`error`；`audio` 硬编码 `44100:16:2`，`bitrate` 恒 `0`；`single`/`consume` 不支持 `oneshot`；`consume` 报告为 1 但不会移除已播歌曲。`stats.playtime` 恒 `0`，`db_update` 用当前时间而不是真实扫描时间。 |
| M11 | P2 | 队列命令细节 | 部分完成 | `add` 不支持位置；`addid` 的目录/相对位置 `+N`/`-N` 不完整；`move`/`shuffle` 不支持 `START:END`；`load` 不支持第三个 `POSITION`；`playlistmove` 只支持单条；缺 `prio`/`prioid`/`swap`/`swapid`/`rangeid`。`seekid`/`deleteid`/`moveid` 的 ID 校验已基本完成。 |
| M12 | P2 | 存储播放列表 | 部分完成 | `save NAME` 无 mode 时当前会覆盖；MPD 默认应按 `create` 处理，已存在时报错。缺 `playlistlength`、`searchplaylist`、废弃别名 `playlist`（返回 queue）；`listplaylist*`/`playlistfind` 的 `sort`/`window` 未实现。 |
| M13 | P3 | 标签与 `tagtypes` | 未开始 | `songInfoLines` 缺 Composer/Performer/Work/Movement/Label/Name/ArtistSort/AlbumArtistSort/AlbumSort/MusicBrainz 等；`tagtypes` 只返回固定子集；缺 `enable`/`disable`/`clear`/`all`/`available`/`reset` 和 per-client tag mask。 |
| M14 | P2 | 错误状态与命令表 | 未开始 | 没有 `error` 状态和 `clearerror`；`notcommands` 恒 `OK`；`commands` 与实际能力不完全一致；`mount`/`partition` 等未在命令表中声明却返回成功。 |
| M15 | P3 | 播放选项 | 未开始 | 缺 `crossfade`、`mixrampdb`、`mixrampdelay`、`replay_gain_mode`；目前只有恒为 `off` 的 `replay_gain_status`。 |
| M16 | P3 | 低优先级/可选命令 | 未开始 | Sticker、partition、mount、client-to-client channel、`protocol` 特性、`config`、`readcomments`、`listfiles`、`getfingerprint`、`searchcount`、`searchaddpl`、`outputset`/`moveoutput`、`idle` 未知子系统报错、command list 嵌套/未闭合校验、真实 `decoders`/`urlhandlers`。`kill` 不建议实现。 |
| M17 | P1 | `play` 不应递增 playlist 版本 | 未开始 | `MPDServer.execute` 的 `play` 分支调用 `bumpPlaylist()`；`play`/`playid` 只改变播放位置，不改变队列结构，应只发 `player` 事件。当前实现会让 `playlist` 版本和 idle 事件产生假变化。 |

### 2.2 建议的 MPD 处理顺序

1. **M4 + M14**：先让协议声明诚实；未实现命令返回 ACK，或明确降低 greeting/能力声明。
2. **M2 + M8**：补扫描完成事件和真实 `update` job 状态，远程端才能正确刷新。
3. **M5**：把只读查询移出主线程，避免大库搜索/列表卡住 UI。
4. **M3 + M17**：修正 playlist 版本和 `play` 的假变化。
5. **M10 + M11 + M12**：补 `status`/`stats` 和队列/存储列表细节。
6. **M6 + M7 + M9**：过滤器、目录语义和 URI 兼容性。
7. **M13/M15/M16**：按目标客户端需求补齐，不要求一次性做到 0.24 全量。

### 2.3 验证清单

```sh
mpc status
mpc idle                 # 在 App UI 里切歌、暂停、改音量、改队列
mpc add "<path>" 0
mpc addid "<path>" +0
mpc playlistinfo
mpc find "(Artist == 'X')"
mpc search "(Title contains 'foo')" sort Album window 0:20
mpc list Artist group AlbumArtist
mpc lsinfo
mpc update
mpc save test create
mpc playlistlength test
```

建议同时用 ncmpcpp、MALP / MPD Remote 验证：切歌自动刷新、进度拖动、idle 状态更新、
封面分块加载、存储播放列表、扫描期间的 `updating_db`。

---

## 3. 性能与稳定性

这些项来自最近一次全量审查，和上面的主题审计有交叉，不重复计入 45 项。

| 优先级 | 项目 | 状态 | 说明 |
|---|---|---|---|
| P1 | 播放时 CPU 偏高 | 未开始 | 2026-10-29 release 构建实测播放时约 **14–16% CPU**（暂停时约 0.1%）。`ContentView` 仍 `@EnvironmentObject` 观察整个 `PlayerState`；`ContentPane.recentAlbums` 每次更新都会重排；`PlayerToolbar` 多个子视图也直接观察 player。建议先用 Instruments 确认是 SwiftUI 重绘、`elapsed` 0.2s 更新还是 AVPlayer/音频路径导致，再缩小观察范围/缓存排序。 |
| P2 | `ArtworkCache` 内存无上限、`maxPixel` 未生效 | 未开始 | `NSCache` 没有 `countLimit`/`totalCostLimit`；`image(for:maxPixel:)` 的 `maxPixel` 在 inline/cache 路径都被忽略，始终按 500px 读盘。Settings 只显示缓存大小，没有容量上限。 |
| P2 | 全屏过渡缺少通用 watchdog | 未开始 | 只有 MiniPlayer 退出全屏有 2 秒超时；普通进入/退出全屏若 `willEnter`/`willExit` 后没收到 `didEnter`/`didExit`，`isFullScreenTransitioning` 可能卡住。建议给两条路径都加重置/超时，并在 `didFailToEnterFullScreen` 类通知可用时清理。 |
| P2 | 编译警告 | 未开始 | 当前至少有：`GetInfo.swift:86` main actor 隔离的 `text` 被 nonisolated 上下文引用；`AudiaApp.swift:1710` `NSApp.windowsMenu` 在 Sendable closure 中访问。 |
| P2 | 数据库 transaction/rollback | 未开始 | 见 **L11**。 |
| P3 | 历史扫描线程崩溃日志 | 未开始 | `~/Library/Logs/DiagnosticReports/Audia-2026-10-28-194213.ips` 显示 `LibraryScanner.enumerateFiles` 在 cooperative 线程访问 `URL.pathExtension` 时崩溃；之后未复现。建议做一次大库/异常路径压力测试，并审查扫描线程对 Foundation URL 的使用。 |
| P3 | 大文件职责集中 | 未开始 | 当前约：`MPDServer.swift` 1616 行、`ContentViews.swift` 2653 行、`AudiaApp.swift` 1976 行、`LibraryDatabase.swift` 1441 行、`Library.swift` 1370 行、`PlayerState.swift` 1289 行、`TagWriter.swift` 930 行。建议按测试边界渐进拆分，不要纯搬文件；先补回归测试，保持 schema、Song UUID、queue 持久化兼容。 |
| P3 | 滚动恢复仍有多套机制 | 部分完成 | 最近提交已修 viewport 漂移，但 `ContentViews` 仍同时使用 `ScrollPosition` + `ViewScrollStore`/`ViewPositionStore` + 200–300ms `Task.sleep` 兜底。建议统一成一个可取消的 viewport helper，并补 UI 回归。 |

---

## 4. Settings 与窗口

### 4.1 Settings

| ID | 项目 | 状态 | 说明 |
|---|---|---|---|
| S1 | 侧边栏分组导航 | 完成 | `SettingsView` 已有 General / Library / Shortcuts / Services 四个 section。 |
| S2 | 字体层级 token | 完成 | `SettingsTypography` 统一 pageTitle/sectionTitle/cardTitle/body/help/caption。 |
| S3 | 卡片、表单行、分隔线规范 | 完成 | `SettingsCard`、`SettingsRow`、`SettingsDivider`、`SettingsFootnote`。 |
| S4 | 渐进展开和状态展示 | 完成 | MPD/Tray 详细字段在启用后显示；库扫描/路径状态在对应 section 内。 |
| S5 | 首次打开不自动聚焦文本框 | 完成 | `SettingsFocusSink` 和显式 focus 处理。 |
| S6 | 按设置域拆分 View | 未开始 | 设置仍全部在 `AudiaApp.swift`。建议拆成 `GeneralSettingsView`、`LibrarySettingsView`、`ShortcutSettingsView`、`ServiceSettingsView`（或 MPD/Tray 两个）；保留现有 UserDefaults key 和默认值。 |
| S7 | 窄窗口/长路径/长标签验收 | 部分完成 | 当前布局已统一，但没有自动化或系统性的 UI 验收记录。 |

### 4.2 窗口拖动

| ID | 项目 | 状态 | 说明 |
|---|---|---|---|
| W1 | 用原生 `performDrag` 替代手动拖动 | 完成 | `WindowDragSurface` 直接调用 `NSWindow.performDrag(with:)`；`PlayerToolbar` 和 `MiniPlayerView` 都使用它。 |
| W2 | 删除碰撞/磁吸/12pt 方案和旧文档 | 完成 | `WindowDragConstraint.swift`、`WindowSnapping.swift` 已不存在；README/agent.md 已改为原生拖动描述。 |
| W3 | 双击空白顶栏缩放（可选） | 过时/不需要 | 旧 `window.md` 的 Step 2 未实现；当前产品没有这个要求。若以后需要，先确认 `performDrag` 不会吃掉双击。 |

窗口拖动的手工验收仍建议在每次改事件路由后跑一遍：空白顶栏、音量/搜索控件、
MiniPlayer、非 key 窗口、全屏进出、多屏、系统平铺/贴边。

---

## 5. Mac App Store（仅在上架目标下处理）

当前版本**不能直接提交 Mac App Store**。如果未来要走 MAS，按以下顺序处理：

1. **P0：移除私有 AppKit selector**
   - `Components.swift` 通过 `NSSelectorFromString("_titlebarHeight")` 和
     `_shouldCenterTrafficLights` 替换 AppKit 私有方法，并用 1pt frame nudge 触发重排。
   - MAS Review Guidelines 2.5.1 不允许私有 API。需要二选一：接受系统标准标题栏布局，
     或像 MiniPlayer 一样改用自定义交通灯按钮。
   - 移除私有 hook 后，1pt nudge 也应一起删除；它不是独立问题。
2. **P0：App Sandbox + security-scoped bookmarks**
   - 当前没有 `com.apple.security.app-sandbox`、用户选择文件 entitlement、
     security-scoped bookmark 或 `startAccessingSecurityScopedResource()`。
   - 内部库 `~/Music/Tracks`、外部库路径、扫描、写标签、移废纸篓都依赖路径权限；
     沙盒下必须改为 NSOpenPanel 授权 + bookmark 持久化 + 启动时解析 + 失效重授权。
3. **P1：打包/隐私/网络权限**
   - 需要 Xcode App target/archive、App Store provisioning profile、entitlements、
     `PrivacyInfo.xcprivacy`（UserDefaults、文件时间戳等 required-reason API）。
   - MPD 监听 TCP 需要 `com.apple.security.network.server`；建议 MAS 版本默认只监听
     `127.0.0.1`，在审核说明中解释这是本地音乐控制服务。
4. **Developer ID 分发**
   - 不走 MAS 时，沙盒和 Xcode archive 不是硬性要求；私有 selector 仍是升级兼容风险，
     但不受 MAS 2.5.1 审核约束。

---

## 6. 测试覆盖

当前 **21 个测试**，覆盖：

- 多 disc 检测/排序、Get Info 保留存储的 disc total
- MPD 稳定队列 ID
- 重复专辑名按 song ID 解析封面
- Recent 排序
- 快捷键持久化/冲突
- 队列 ID/重复项持久化
- playlist 重开保留
- 外部库 disable/restore
- 备份、Relocate、外部库删除、空 playlist 保留
- 全相对路径匹配
- 缺失连续 100 次暂停/成功重置
- Quick/Full Scan、mtime/size 变化、目录伪装音频扩展名、扫描阶段顺序
- 滚动 reveal 不移动已完全可见项

仍缺：

- MPD 端到端：idle、空壳命令 ACK、`status`/`stats`、过滤器、`lsinfo`、`update`
- WindowMode/全屏过渡/MiniPlayer
- TrayController
- ArtworkCache 容量/缩放
- PlayerState 播放、缺失文件 UI、播放计数时机
- Settings 拆分后的 UserDefaults 兼容
- 私有标题栏 hook / 原生拖动的 UI 回归
- 大库扫描压力测试（对应历史崩溃日志）

---

## 7. 建议处理顺序

1. **MPD 协议诚实性**：M4/M14（空壳命令、greeting、`commands`/`notcommands`）。
2. **MPD 状态同步**：M2/M8（扫描事件、真实 `update` job）+ M3/M17（playlist 版本）。
3. **MPD 主线程**：M5，把只读查询移出 `DispatchQueue.main.sync`。
4. **播放 CPU**：Instruments + 缩小 `PlayerState` 观察范围 + 缓存 Recent 排序。
5. **ArtworkCache**：加 `NSCache` 上限，真正使用 `maxPixel`。
6. **数据库事务**：L11（`sync`/内部删除 rollback）。
7. **全屏 watchdog + 编译警告**。
8. **Settings 拆分 + 测试补齐 + 大文件渐进重构**。
9. **仅在有 MAS 目标时**：私有 API、Sandbox/bookmark、Xcode archive/Privacy Manifest。

---

## 8. 已过时内容（本次删除/不再执行）

- `library01answer.md`：旧草稿。它主张记录卷/文件系统身份、Full Scan 前校验卷身份；
  最终方案已明确**不检查卷身份**，且禁用时清空全局队列/历史。其余内容已被
  `library01.md` 和当前实现取代。
- `library01.md` 的“当前实现审查”和“自动 prune”描述：当前代码已改为 Quick Scan 不删除、
  Full Scan 只报告缺失；`prune`/`pruneSongs` 旧路径已不存在。
- `MPD_TODO.md` 的“id = 位置 + 1”：已由稳定 `QueueEntry.id` 取代。
- `MPD_TODO.md` 的“idle 只有 MPD 命令会广播”：当前已观察 player/音量/输出/playlist；
  只剩扫描 `update`/`database` 事件。
- `MPD_TODO.md` 的“`commands` 缺 `noidle`”：当前 `commandsList` 已包含 `noidle`。
- `MPD_TODO.md` 的行号：已过期，本文档改用符号名。
- `window.md`：`WindowDragConstraint.swift`、磁吸、12pt breakaway、手动 `setFrameOrigin`
  都已删除；当前是 `WindowDragSurface` + `performDrag(with:)`。旧文档中的 HEAD/工作区状态无效。
- `review01.md` 的“Package.swift 使用 `.unsafeFlags`”：当前 `Package.swift` 没有
  unsafeFlags；SDK 版本由 `scripts/build.sh` 的 linker override 注入，是有意保留的构建策略。
- `review01.md` 的“Command-F 固定 0.30/0.05 秒延时”：当前 Find 命令直接 post
  `.focusSearch`，该固定延时已移除。
- `review01.md` 的“滚动恢复两套机制导致必现问题”：仍有多套恢复路径和 sleep，但最近已修
  viewport 漂移；保留为 P3 维护性/测试项，不再当作已确认 bug。
- `settings.md` 的“Settings 是一个超长单页”：当前已有侧边栏分组；只剩代码拆分和验收。

---

## 9. 不要回退的产品决定

- **多 disc**：`Album.isMultiDisc` 由最高 disc number > 1 或任意 `discTotal > 1` 判定；
  有效总 disc 数取 `max(最高 discNumber, 最高 discTotal)`；歌曲按 disc → track 排序；
  多 disc 行显示 `1-01` 这类标签。
- **Get Info**：只显示存储的 disc 值，不根据 disc number 推断 total；混合/空值保存时
  保持原值，避免覆盖用户故意留空的标签。
- **Quick Scan**：只新增；不更新 metadata、不检查缺失、不删除。
- **Full Scan**：更新变化文件、报告缺失、不自动删除；根目录不可读/遍历不完整时不得生成
  可执行的删除清单。
- **Relocate**：完整相对路径匹配；Cancel 不改数据；未勾选删除的歌曲也更新到新根；
  先备份、再 transaction。
- **禁用外部库**：保留数据库和 playlist item，但停止播放并清空全局队列/历史。
- **删除外部库**：仅禁用后可用；先备份；只删 Tracks 索引；空 playlist 保留；不碰音频文件。
- **运行时缺失**：只存在内存；区分 missing/inaccessible；连续 100 首暂停；成功播放才计数。
- **窗口拖动**：原生 `performDrag`；不要恢复碰撞、磁吸、12pt breakaway 或手工 frame 回读。
- **标题栏**：私有 `_titlebarHeight`/`_shouldCenterTrafficLights` 和 1pt nudge 是当前
  Developer ID 版本的兼容层；如果走 MAS，必须按第 5 节移除，不要只删 nudge。
- **Schema**：`createSchema()` 是唯一支持的 schema；不新增旧库迁移，未来 schema 变化要
  引入版本化 migration。
- **MPD**：稳定队列 ID 不能退回位置 ID；idle 事件要在统一状态入口发，避免 UI 和 MPD 命令
  各发一次。

---

## 10. 相关代码位置（符号名，不依赖行号）

| 内容 | 位置 |
|---|---|
| 媒体库生命周期/扫描 | `Library.swift`：`rescanAll`、`rescan`、`fullScan`、`previewRelocation`、`applyRelocation` |
| 扫描器 | `FLACLibrary.swift`：`LibraryScanner.scan`、`enumerateFiles` |
| 数据库 | `LibraryDatabase.swift`：`sync`、`backup`、`relocateLibrary`、`deleteLibraryAndSongs`、`removeSongsFromLibrary` |
| Relocate 匹配 | `LibraryRelocationMatcher.swift` |
| 缺失审核 UI | `AudiaApp.swift`：`MissingFilesReviewView` |
| 运行时缺失 | `PlayerState.swift`：`beginCurrentTrack`、`tick`、`handleMissingFile`、`MissingFileStreak` |
| MPD 命令 | `MPDServer.swift`：`execute`、`statusLines`、`statsLines`、`songInfoLines`、`lsinfoLines`、`parseFilters` |
| MPD 会话/主线程 | `MPDServer.swift`：`MPDClientSession.executeOnMain`、`handleLine` |
| 标题栏/拖动 | `Components.swift`：`WindowConfigurator`、`refreshLibraryTitlebarLayout`、`WindowDragSurface` |
| 窗口模式 | `WindowMode.swift`：`setMode`、`scheduleFullScreenExitTimeout` |
| Settings | `AudiaApp.swift`：`SettingsView`、`SettingsTypography`、`SettingsCard` |
| Artwork | `ArtworkCache.swift`：`image(for:maxPixel:)`、`memory`、`imageFromCache` |
