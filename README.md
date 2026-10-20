# fanqie.koplugin — 非官方增强版 Fork

[![release](https://img.shields.io/github/v/release/seaneasysaid/fanqie.koplugin-fixed?label=release&labelColor=555555&color=007ec6)](https://github.com/seaneasysaid/fanqie.koplugin-fixed/releases/latest)
[![downloads](https://img.shields.io/github/downloads/seaneasysaid/fanqie.koplugin-fixed/total?label=downloads&labelColor=555555&color=dfb317)](https://github.com/seaneasysaid/fanqie.koplugin-fixed/releases)
[![changelog](https://img.shields.io/badge/%E6%9B%B4%E6%96%B0%E6%97%A5%E5%BF%97-CHANGELOG-2ea44f?labelColor=555555)](CHANGELOG.md)

本项目是 [`hesan1232/fanqie.koplugin`](https://github.com/hesan1232/fanqie.koplugin) 的非官方增强版 Fork。

> 本项目不是上游项目的官方版本。上游来源与代码差异在 Fork 关系与提交历史中公开保留。


## 与原版的主要区别

- **移除上游旧书源**：删除上游内置的「晴天聚合」「大灰狼」两个书源及其全部配置项，不再维护。
- **适配书山聚合源（重写接入）**：完整接入「书山聚合」——原生 Lua 实现，内置多节点镜像池（1 主 + 1 指定备选 + 4 域名兜底）。
- **服务器测速与自动切换**：书山源内置全节点延迟测速，一键切换到**最快可达线路**并持久化记忆；坏节点自动冷却 120s，节点记忆重启不丢。
- **适配知秋四合一源与知秋段评**：支持三件套 / 共享 Token 两种凭据方式，正文与段评双通道可用；Token 过期自动续期。
- **段评弹窗重构（微信「想法」式）**：新增独立的 `review_popup` 模块（分页器、滚动容器、自定义组件等 11 个文件），段评弹窗为富排版卡片：段落原文置顶、评论流可滚动、左右半屏翻页、支持继续加载；取数在子进程完成，阅读与翻页全程不冻结，等待可取消。各书源的段评通道独立工作、互不影响。
- **段评气泡改造**：评论数气泡改为方括号纯文本形式（如 `[47]`），不依赖圆角/背景渲染，任何 crengine 版本都可靠显示。
- **章节标题排版**：修复原版 `<h1>` 整行标题的显示方式，改为「第X章」前缀与标题名**分两行**；序章/后记等无「第X章」格式的标题原样显示。
- **正文清洗增强**：修复 Lua `%s` 不识别全角空格（U+3000）等问题导致的中文段首缩进残留（知秋源 4 字符缩进问题）；清理聚合源正文中掺杂的零宽空格/BOM 等不可见字符与末尾广告；UTF-8 安全截断，日志与缓存不会出现半个汉字。
- **子进程 fd 泄漏修复**：fork 出的子进程会继承并占住 HTTP Inspector 监听端口，导致待机恢复/切章时报 `address already in use`，已修复。
- **阅读统计按书合并**：插件一章一个文件，KOReader 阅读统计默认会把每章当成一本，导致书列表里塞满「第 N 章」。现在同一本书的所有章节合并为统计里的**一条记录**（书名 + 作者 + 按书籍 ID 生成的固定标识），界面标题仍显示章节名。
  同时**保留真实页数**：各章页码都从 1 开始，直接合并会让不同章的「第 3 页」互相覆盖。这里改用**跨章连续虚拟页号**（第 N 章第 P 页 = (N-1)×100 + P），每章独占一段互不重叠的页号 —— 已读页数 = 真实翻过的页数，可跨章累加，不再退化成「章数」；逐页阅读时长原样保留；总页数按「平均每章页数 × 目录章数」估算，进度与真实阅读比例一致。阅读时长、日历热力图不受影响。
- **稳定性修复**：书架/目录「内存主源 + 文件后备」两层缓存、刷新成功才覆盖、Kindle 弱设备（FAT 卷、低内存）实测优化等。

## 安装

1. 从 Release 下载 `fanqie.koplugin` 安装包（zip）并解压。
2. 将 `fanqie.koplugin` 文件夹复制到 KOReader 的 `plugins` 目录：
   - Kindle：`/koreader/plugins/`
   - Kobo：`/.adds/koreader/plugins/`
3. 完全退出并重新启动 KOReader。

注意目录不要多套一层：

```
koreader/plugins/fanqie.koplugin/main.lua   ← 正确
koreader/plugins/fanqie.koplugin/fanqie.koplugin/main.lua   ← 错误
```

## 书源配置

路径：菜单 → 番茄小说 → 设置 → **书源管理**。插件按列表顺序依次尝试，某源失败自动切换下一个。

| 书源 | 说明 | 配置 |
|------|------|------|
| **官方源（App 协议）** | 番茄官方 App 阅读协议，正文与段评均可用 | 正文无需配置；书架 / 目录需扫码登录 |
| **书山聚合** | 聚合非番茄源，支持段评，正文无广告 | 邮箱 + 密码 + 真实 16 位十六进制 Android ID（具体怎么查百度或 AI） |
| **知秋四合一** | 番茄四合一，支持正文与段评，正文无广告 | 三件套 或 共享 Token |

- **书山**：进入书源 → 填写邮箱/密码/Android ID → 「登录测试」获取密钥 → 「服务器测速」选最快线路。
- **知秋**：进入书源 → 填写三件套或点「获取共享 Token」→ 自动续期。
- 每个源可单独设置限流，并用「上移 / 下移」调整优先级。

> 凭据只保存在你自己设备的 `settings/fanqie.lua` 中；书源文件与仓库代码不含任何账号信息。

## 段评使用说明

开启方法：菜单 → 番茄小说 → 设置 → **段评显示**（持久开关）。

- 本章有评论的段落，末尾会出现数字气泡（如 `47`），点击即读该段评论；
- 弹窗为微信「想法」式富排版：段落原文置顶，评论流可滚动，支持上一段 / 下一段切换；
- 取评论在后台子进程进行，等待超时会浮出提示，可随时取消；
- 段评由书山 / 知秋 / 官方三条通道分别提供，互不影响；官方源段评支持展开二级评论（回复列表可继续加载）。对旧缓存章节用「重新获取本章节」带段评重新下载。

## 常见问题

- **书架为空 / 章节获取失败**：检查扫码登录状态与网络；进入「书源管理」确认书山 / 知秋已登录、限流未设得过低；也可执行「服务器测速」切换线路后重试。
- **段评不显示**：确认 1) 书山 / 知秋已启用并登录成功，或已切换到官方源（官方源无需登录即可取正文与段评）；2) 「段评显示」开关已开；3) 点「重新获取本章节」。
- **书架 / 目录刷新后数据没变**：网络失败或登录过期时会保留旧缓存并提示，恢复网络后点左上角菜单 → 刷新。

## 上游关系

- 上游项目：https://github.com/hesan1232/fanqie.koplugin
- 本增强分支：https://github.com/seaneasysaid/fanqie.koplugin-fixed

借鉴或合并上游后续修复时，会保留可追踪的提交说明，不通过改名或打乱代码结构隐藏来源。

上游自 v2.16.22 起以 **GPL-3.0-only** 分发，本分支同步采用同一许可（原因见[许可证](#许可证)）。

## 使用声明

本项目仅用于个人学习和技术研究，不代表上游项目及相关内容平台的官方立场。本项目不存储、不分发任何书籍内容，所有正文均通过用户自行配置的书源获取。使用者应自行确认适用的授权条件并自行承担风险，请尊重版权、支持正版阅读。如涉及侵权请联系删除。

## 许可证

本项目以 **GNU General Public License version 3 only（GPL-3.0-only）** 分发，
全文见仓库根目录 [LICENSE](LICENSE)，逐文件的第三方来源与归属见
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。

    fanqie.koplugin-fixed — 非官方增强版 Fork
    Copyright (C) 2026 seaneasysaid (enhanced fork modifications)

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, version 3 of the License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

### 为什么不是 MIT

2026-10-20 之前本项目沿用上游的 MIT 声明，该声明**自始不成立**：

- `fanqie/reading/` 与 `fanqie/reading.lua` 移植自**月读**
  （[AnkioTomas/moon](https://github.com/AnkioTomas/moon)）的 KOReader 插件
  `book.koplugin`，原作以 **GPLv3** 发布。GPLv3 是 copyleft 许可，
  包含其代码的整体必须以同一许可分发，MIT 与之冲突；
- 本插件运行在以 **AGPLv3** 发布的 KOReader 之内，并经 `patches/core.lua`
  对 `ReaderLink` / `ReaderToc` / `ReaderPaging` / `ReaderRolling` 打补丁，
  单方面声明 MIT 本身也不成立；
- GPLv3 与 AGPLv3 相互兼容（AGPLv3 §13），故取 **GPL-3.0-only**。

### 这对使用者意味着什么

- **可以**自由使用、修改、再分发，包括商业使用；
- 再分发时须**保留版权与许可声明**，并**提供对应源码**
  （本仓库与每个发布包内均为完整 Lua 源码）；
- 不能将本项目改为闭源，或改用与 GPLv3 不兼容的许可。

## 项目推荐

同一个设备生态里的其他 KOReader 插件与工具，都出自本人维护：

| 项目 | 简介 |
|------|------|
| [legadocomic.koplugin](https://github.com/seaneasysaid/legadocomic.koplugin) | KOReader 漫画流式阅读插件：对接安卓「开源阅读」(Legado) WebService 的漫画书源，支持目录浏览、图片流式加载与阅读进度同步。 |
| [readingstats.koplugin](https://github.com/seaneasysaid/readingstats.koplugin) | 轻量阅读统计：日历式阅读足迹 + GitHub 风格热力图 + 阅读分析（含年度 / 月度书籍排行）。 |
| [leko-reader-fixed](https://github.com/seaneasysaid/leko-reader-fixed) | 全程本地运行的 KOReader 网络小说插件，兼容 Legado 书源，主打轻快流畅的阅读体验。 |
| [koreader-remote](https://github.com/seaneasysaid/koreader-remote) | 手机浏览器通过 Wi-Fi 无线遥控 KOReader 的网页工具。 |
