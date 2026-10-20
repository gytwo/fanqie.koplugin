# fanqie.koplugin — 非官方增强版 Fork

[![release](https://img.shields.io/github/v/release/seaneasysaid/fanqie.koplugin-fixed?label=release&labelColor=555555&color=007ec6)](https://github.com/seaneasysaid/fanqie.koplugin-fixed/releases/latest)
[![downloads](https://img.shields.io/github/downloads/seaneasysaid/fanqie.koplugin-fixed/total?label=downloads&labelColor=555555&color=dfb317)](https://github.com/seaneasysaid/fanqie.koplugin-fixed/releases)
[![changelog](https://img.shields.io/badge/%E6%9B%B4%E6%96%B0%E6%97%A5%E5%BF%97-CHANGELOG-2ea44f?labelColor=555555)](CHANGELOG.md)

本项目是 [`hesan1232/fanqie.koplugin`](https://github.com/hesan1232/fanqie.koplugin) 的非官方增强版 Fork。

> 本项目不是上游项目的官方版本。上游来源与代码差异在 Fork 关系与提交历史中公开保留。


## 与原版的主要区别

- **书源**：移除上游内置的「晴天聚合」「大灰狼」，改为接入**书山聚合**与**知秋四合一**。两个源都内置线路测速，可一键切到最快的线路，选择会记住，重启不用重选。
- **段评弹窗重做**：微信「想法」式排版——段落原文置顶、评论可上下滚动、左右半屏翻页、支持继续加载更多。取评论在后台进行，阅读和翻页不受影响，等不及可以取消。
- **段评气泡**：评论数改成 `[47]` 这种方括号纯文本，不依赖特殊图形渲染，各种设备都显示得出来。
- **章节标题**：「第X章」与章节名**分两行**显示；序章、后记这类特殊标题原样保留。
- **正文清理**：去掉段首多余的缩进、混进正文的不可见字符和文末广告，中文排版更整齐。
- **阅读统计合并**：同一本书的各章在统计里合并成**一条记录**（否则书单里会塞满「第X章」）。已读页数与阅读时长仍是真实值，进度按实际阅读位置计算。
- **缓存更稳**：书架与目录各留一份缓存，只有刷新成功才覆盖旧数据，网络不好时不会把已有内容清空；对低配置设备做过实测优化。

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
