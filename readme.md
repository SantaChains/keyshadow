# keyshadow

AutoHotkey v2 桌面小工具集合。
仓库地址：<https://github.com/SantaChains/keyshadow>

## Flash Search

选中文本 → 按触发快捷键（默认 `Alt+Y`，可在设置面板重绑）→ 自动识别并跳转：

| 选中内容 | 行为 |
| --- | --- |
| 单个 URL / 协议链接（http、magnet、vscode、obsidian、ed2k 等） | 直接用浏览器或关联程序打开 |
| 多个链接 | 弹出选择面板：数字键 `1-9`、`0` 选第 10 条，右键可复制链接 |
| 本地文件路径 | 用配置的编辑器打开（默认 EmEditor） |
| 本地文件夹路径 | 用 VSCode / 资源管理器 / Cursor / Windsurf / 自定义命令打开 |
| 其他文本 | 送搜索引擎（bing / google / baidu / duckduckgo / github / mdn 可切换） |

- 托盘菜单 → 设置：搜索引擎、触发快捷键、编辑器、文件夹打开方式、面板链接数上限；配置存于 `flash-search/flash-search.ini`（个人配置，不入仓库）
- 运行：双击 `flash-search/flash-search.ahk`（需安装 AutoHotkey v2）

## Ctrl2Enter (c2e)

- 连按两下 `Ctrl` 触发 `Enter`，减少左手移动距离；触发键等行为可个性化
- 运行：`Ctrl2Enter/Ctrl2Enter.ahk`，或直接使用随附的 `Ctrl2Enter.exe`
- 细节见 `Ctrl2Enter/README.md`

## License

MIT © SantaChains，详见 [LICENSE](LICENSE)。

## 致谢

- [AutoHotkey v2](https://www.autohotkey.com/)
- [abgox/SpaceKey](https://github.com/abgox/SpaceKey) (MIT) —— 对本仓库应用的启发与帮助
