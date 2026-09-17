#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================
; 全局状态
; ============================================
global g_LinkPanel := unset        ; 链接选择面板 Gui 对象
global g_Autostart := false         ; 开机自启动开关状态
global g_SearchEngine := "bing"     ; 默认搜索引擎
global g_MaxLinks := 30             ; 面板最多显示链接数
global g_PanelLinks := []           ; 当前面板展示的链接数组（供数字快捷键使用）
global g_ButtonUrlMap := Map()      ; 按钮 Hwnd -> URL 映射（供右键菜单使用）
global g_PanelRemaining := ""       ; 当前面板对应的剩余文本
global g_PanelAlsoSearchChk := unset ; 面板中“同时搜索剩余文本”复选框控件

; === 本地文件/文件夹打开方式 ===
global g_TextEditor := "D:\Users\JliuPureey\Downloads\APP\EmEditor\EmEditor.exe"  ; 默认 EmEditor
global g_FolderOpener := "vscode"    ; vscode / explorer / cursor / windsurf / custom
global g_FolderCustomCmd := ""       ; 自定义命令模板（{path} 占位）

; === 面板行为 ===
global g_AutoClosePanel := false    ; 失焦自动关闭面板（已禁用，保留字段供 ini 兼容）
global g_PanelFocusTimer := 0        ; 当前监控定时器 ID（已禁用）

; === 快捷键 ===
global g_Hotkey := "!y"              ; 主触发快捷键（AHK 语法：!y = Alt+Y）
global g_HotkeyRegistered := ""     ; 当前已注册的快捷键（供动态重绑时反注册）
global g_CapturedHotkey := ""       ; CaptureHotkey 临时存储捕获结果

; === 设置面板 ===
global g_SettingsGui := unset        ; 设置窗口 Gui 对象

; 支持的搜索引擎列表
global g_SearchEngines := ["bing", "google", "baidu", "duckduckgo", "github", "mdn"]
; 文件夹打开方式：内部值 -> 显示标签
global g_FolderOpenerOptions := [["vscode", "VSCode (vscode://file/)"], ["explorer", "资源管理器"], ["cursor",
    "Cursor (cursor://file/)"], ["windsurf", "Windsurf (windsurf://file/)"], ["custom", "自定义命令"]]

; 加载配置 + 初始化托盘菜单 + 注册主快捷键
LoadConfig()
SetupAutostartTray()
RegisterMainHotkey()

; 主快捷键处理函数（动态注册，快捷键可在设置面板自定义）
; 注：AHK v2.0.28+ 要求热键回调能接收热键名参数，故用 (*) 可变参数签名
MainHotkeyHandler(*) {
    static CLIPBOARD_TIMEOUT := 0.3
    local clipboardBackup := ClipboardAll()
    try A_Clipboard := ""
    catch {
        try A_Clipboard := clipboardBackup
        return
    }
    SendInput "^c"
    local hasSelection := ClipWait(CLIPBOARD_TIMEOUT)
    if (hasSelection) {
        local selectedText := A_Clipboard
        try A_Clipboard := clipboardBackup
        if (selectedText != "") {
            HandleSearch(selectedText)
        }
    }
    else {
        try A_Clipboard := clipboardBackup
        local clipText := A_Clipboard
        if (clipText != "") {
            HandleSearch(clipText)
        }
    }
}

; 注册主快捷键（启动时 + 设置变更后调用）
RegisterMainHotkey() {
    global g_Hotkey, g_HotkeyRegistered
    local target := Trim(g_Hotkey)
    if (target = "")
        target := "!y"
    ; 先反注册旧的（如果存在且与新值不同）
    if (g_HotkeyRegistered != "" && g_HotkeyRegistered != target) {
        try Hotkey(g_HotkeyRegistered, "Off")
        g_HotkeyRegistered := ""
    }
    ; 注册新的
    if (g_HotkeyRegistered != target) {
        try {
            Hotkey(target, MainHotkeyHandler, "On")
            g_HotkeyRegistered := target
        }
        catch Error as e {
            MsgBox("注册快捷键失败：`n" target "`n`n" e.Message "`n`n将回退到默认 Alt+Y。", "Flash Search", "Icon!")
            g_Hotkey := "!y"
            try {
                Hotkey("!y", MainHotkeyHandler, "On")
                g_HotkeyRegistered := "!y"
            }
        }
    }
}

; ============================================
; 面板数字键快捷（1-9 选第1-9条，0 选第10条）
; 仅在链接面板为活动窗口时生效，不影响全局输入
; ============================================
#HotIf IsLinkPanelActive()
1:: PanelSelectLink(1)
2:: PanelSelectLink(2)
3:: PanelSelectLink(3)
4:: PanelSelectLink(4)
5:: PanelSelectLink(5)
6:: PanelSelectLink(6)
7:: PanelSelectLink(7)
8:: PanelSelectLink(8)
9:: PanelSelectLink(9)
0:: PanelSelectLink(10)
Numpad1:: PanelSelectLink(1)
Numpad2:: PanelSelectLink(2)
Numpad3:: PanelSelectLink(3)
Numpad4:: PanelSelectLink(4)
Numpad5:: PanelSelectLink(5)
Numpad6:: PanelSelectLink(6)
Numpad7:: PanelSelectLink(7)
Numpad8:: PanelSelectLink(8)
Numpad9:: PanelSelectLink(9)
Numpad0:: PanelSelectLink(10)
#HotIf

; ============================================
; 开机自启动（托盘菜单开关，写入 HKCU\...\Run）
; ============================================
SetupAutostartTray() {
    global g_Autostart, g_SearchEngine, g_SearchEngines
    g_Autostart := IsAutostartEnabled()
    ; 清空默认托盘菜单，重建为：设置 / 搜索引擎 / 开机自启 / 退出
    A_TrayMenu.Delete()

    ; 默认双击托盘图标也打开设置（必须先 Add 再设 Default，否则报 Nonexistent menu item）
    A_TrayMenu.Add("设置…", (*) => ShowSettings())
    A_TrayMenu.Default := "设置…"
    A_TrayMenu.Add()  ; 分隔线

    ; 搜索引擎子菜单
    local engineMenu := Menu()
    for _, name in g_SearchEngines {
        engineMenu.Add(name, SetSearchEngineHandler.Bind(name))
        if (g_SearchEngine = name)
            engineMenu.Check(name)
    }
    A_TrayMenu.Add("搜索引擎", engineMenu)
    A_TrayMenu.Add()  ; 分隔线

    A_TrayMenu.Add("开机自动启动", ToggleAutostart)
    if (g_Autostart)
        A_TrayMenu.Check("开机自动启动")
    A_TrayMenu.Add()  ; 分隔线
    A_TrayMenu.Add("退出", (*) => ExitApp())
}

; 托盘菜单：切换搜索引擎并持久化
SetSearchEngineHandler(name, *) {
    global g_SearchEngine
    g_SearchEngine := name
    SaveConfig()
    ; 重建托盘菜单以刷新子菜单勾选状态
    SetupAutostartTray()
    try TrayTip("搜索引擎已切换为：" name, "Flash Search", "Iconi T1")
}

; 加载配置（flash-search.ini）
LoadConfig() {
    global g_SearchEngine, g_MaxLinks, g_TextEditor, g_FolderOpener, g_FolderCustomCmd, g_AutoClosePanel
    global g_Hotkey, g_SearchEngines, g_FolderOpenerOptions
    local iniPath := A_ScriptDir "\flash-search.ini"

    ; 每个字段独立 try，避免一个损坏导致全部跳过
    try g_SearchEngine := IniRead(iniPath, "Config", "SearchEngine", "bing")
    try g_MaxLinks := Integer(IniRead(iniPath, "Config", "MaxLinks", "30"))
    try g_TextEditor := IniRead(iniPath, "Open", "TextEditor", g_TextEditor)
    try g_FolderOpener := IniRead(iniPath, "Open", "FolderOpener", "vscode")
    try g_FolderCustomCmd := IniRead(iniPath, "Open", "FolderCustomCmd", "")
    try g_AutoClosePanel := Integer(IniRead(iniPath, "Panel", "AutoClose", "0")) != 0
    try g_Hotkey := IniRead(iniPath, "Config", "Hotkey", "!y")

    ; === 合法性校验 ===
    ; 链接数范围
    if (g_MaxLinks < 1 || g_MaxLinks > 100)
        g_MaxLinks := 30
    ; 快捷键非空
    if (Trim(g_Hotkey) = "")
        g_Hotkey := "!y"
    ; 搜索引擎必须在支持列表中，否则回退 bing
    local engineValid := false
    for _, name in g_SearchEngines {
        if (g_SearchEngine = name) {
            engineValid := true
            break
        }
    }
    if (!engineValid)
        g_SearchEngine := "bing"
    ; 文件夹打开方式必须在支持列表中，否则回退 vscode
    local folderValid := false
    for _, pair in g_FolderOpenerOptions {
        if (g_FolderOpener = pair[1]) {
            folderValid := true
            break
        }
    }
    if (!folderValid)
        g_FolderOpener := "vscode"
}

; 保存配置
SaveConfig() {
    global g_SearchEngine, g_MaxLinks, g_TextEditor, g_FolderOpener, g_FolderCustomCmd, g_AutoClosePanel
    global g_Hotkey
    local iniPath := A_ScriptDir "\flash-search.ini"
    try
    {
        IniWrite(g_SearchEngine, iniPath, "Config", "SearchEngine")
        IniWrite(g_MaxLinks, iniPath, "Config", "MaxLinks")
        IniWrite(g_TextEditor, iniPath, "Open", "TextEditor")
        IniWrite(g_FolderOpener, iniPath, "Open", "FolderOpener")
        IniWrite(g_FolderCustomCmd, iniPath, "Open", "FolderCustomCmd")
        IniWrite(g_AutoClosePanel ? 1 : 0, iniPath, "Panel", "AutoClose")
        IniWrite(g_Hotkey, iniPath, "Config", "Hotkey")
    }
    catch Error as e
        MsgBox("保存配置失败：`n" e.Message, "Flash Search", "Icon!")
}

; 根据当前引擎构造搜索 URL
GetSearchUrl(query) {
    global g_SearchEngine
    local q := UriEncode(query)
    switch g_SearchEngine {
        case "google": return "https://www.google.com/search?q=" q
        case "baidu": return "https://www.baidu.com/s?wd=" q
        case "duckduckgo": return "https://duckduckgo.com/?q=" q
        case "github": return "https://github.com/search?q=" q
        case "mdn": return "https://developer.mozilla.org/search?q=" q
        default: return "https://www.bing.com/search?q=" q
    }
}

; 读取当前是否已开启开机自启动
IsAutostartEnabled() {
    try
        return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "FlashSearch") != ""
    catch
        return false
}

; 写入 / 删除开机自启动注册表项
SetAutostart(on) {
    local key := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
    try
    {
        if (on)
            RegWrite("`"" A_ScriptFullPath "`"", "REG_SZ", key, "FlashSearch")
        else
            RegDelete(key, "FlashSearch")
        return true
    }
    catch
        return false
}

; 托盘菜单切换回调
ToggleAutostart(*) {
    global g_Autostart
    local newState := !g_Autostart
    if (SetAutostart(newState)) {
        g_Autostart := newState
        if (g_Autostart)
            A_TrayMenu.Check("开机自动启动")
        else
            A_TrayMenu.Uncheck("开机自动启动")
    }
    else {
        MsgBox("设置开机自启动失败", "Flash Search", "Icon!")
    }
}

HandleSearch(text) {
    text := Trim(text, " `t`r`n")
    if (text = "")
        return

    ; 优先级 1：检测是否为本地文件/文件夹路径（存在才视为路径）
    local localPath := DetectLocalPath(text)
    if (localPath != "") {
        if (DirExist(localPath))
            OpenFolderPath(localPath)
        else
            OpenFilePath(localPath)
        return
    }

    ; 优先级 2：URL 提取（长文本走 fastMode）
    local isLong := StrLen(text) > 4096
    local result := ExtractLinks(text, isLong)
    local links := result[1]
    local remaining := result[2]

    if (links.Length = 0) {
        ; 长文本兜底：截前 512 字符搜索
        SearchInBrowser(isLong ? SubStr(text, 1, 512) : text)
        return
    }

    if (links.Length = 1) {
        OpenUrl(links[1])
        ; 打开链接后，若剩余文本含中文，同时搜索剩余文本
        ; 【已禁用】用户反馈行为不够直觉，暂不启用
        ; if (!isLong && remaining != "" && IsChineseText(remaining))
        ;     SearchInBrowser(remaining)
        return
    }

    ShowLinkPanel(links, isLong ? "" : remaining)
}

; 判断文本是否含中文字符（使用 PCRE Unicode 属性，覆盖 CJK 基本区 + 扩展区）
IsChineseText(text) {
    return RegExMatch(text, "\p{Han}") > 0
}

; ============================================
; 本地文件/文件夹路径检测与打开
; ============================================

; 检测选中文本是否为一个存在的本地路径（文件或文件夹）
; 返回规范化后的绝对路径，未命中返回 ""
DetectLocalPath(text) {
    ; 去除首尾空白与包裹的引号
    local cleaned := Trim(text, " `t`r`n")
    ; 剖除单层包裹的引号（"..." 或 '...'）
    if (StrLen(cleaned) >= 2) {
        local first := SubStr(cleaned, 1, 1)
        local last := SubStr(cleaned, -1)
        if ((first = '"' && last = '"') || (first = "'" && last = "'"))
            cleaned := SubStr(cleaned, 2, -1)
    }
    cleaned := Trim(cleaned, " `t`r`n")
    if (cleaned = "")
        return ""

    ; 多行文本不视为路径
    if (InStr(cleaned, "`n") || InStr(cleaned, "`r"))
        return ""

    ; 去除尾部干扰标点（保留：\ / : . - _ 中文 字母数字空格）
    while (StrLen(cleaned) > 0) {
        local lastCh := SubStr(cleaned, -1)
        if (lastCh = "," || lastCh = ";" || lastCh = "!" || lastCh = "?"
            || lastCh = '"' || lastCh = "'" || lastCh = ")" || lastCh = "]"
            || lastCh = "}" || lastCh = ">")
            cleaned := SubStr(cleaned, 1, -1)
        else
            break
    }
    if (cleaned = "")
        return ""

    ; 匹配驱动器路径 X:\ 或 X:/  或 UNC \\server\share
    if (!RegExMatch(cleaned, "^([a-zA-Z]:[\\/]|\\\\\\\\)"))
        return ""

    ; 长度基本合理性（至少 "C:\" 或 "\\a"）
    if (StrLen(cleaned) < 3)
        return ""

    ; 必须实际存在（文件或文件夹）
    if (FileExist(cleaned) || DirExist(cleaned))
        return cleaned

    return ""
}

; 用配置的编辑器打开文件；未配置或编辑器不存在时回退到系统默认关联
OpenFilePath(path) {
    global g_TextEditor
    ; 优先用配置的编辑器
    if (g_TextEditor != "" && FileExist(g_TextEditor)) {
        try
        {
            Run('"' g_TextEditor '" "' path '"')
            return
        }
        catch Error as e {
            ; 落到下面系统默认关联
        }
    }
    ; 回退：交给 Windows 默认关联程序
    try
    {
        Run('"' path '"')
    }
    catch Error as e {
        MsgBox("无法打开文件：`n" path "`n`n错误：" e.Message
            . "`n`n提示：可在托盘菜单 → 设置… 中修改文本编辑器路径。", "错误", "Icon!")
    }
}

; 用配置的方式打开文件夹
OpenFolderPath(path) {
    global g_FolderOpener, g_FolderCustomCmd
    ; 统一将反斜杠转为正斜杠，供 vscode:// cursor:// 等 URI 使用
    local uriPath := StrReplace(path, "\", "/")

    switch g_FolderOpener {
        case "vscode":
            if (TryRun('vscode://file/' uriPath))
                return
            ; 回退：命令行 code
            if (TryRun('code "' path '"'))
                return
        case "cursor":
            if (TryRun('cursor://file/' uriPath))
                return
            if (TryRun('cursor "' path '"'))
                return
        case "windsurf":
            if (TryRun('windsurf://file/' uriPath))
                return
            if (TryRun('windsurf "' path '"'))
                return
        case "custom":
            if (g_FolderCustomCmd != "") {
                local cmd := StrReplace(g_FolderCustomCmd, "{path}", path)
                cmd := StrReplace(cmd, "{uri}", uriPath)
                if (TryRun(cmd))
                    return
            }
            ; explorer 或全部回退
    }

    ; 最终回退：资源管理器
    if (TryRun('explorer.exe "' path '"'))
        return

    MsgBox("无法打开文件夹：`n" path, "错误", "Icon!")
}

; 尝试 Run 命令，失败不抛异常仅返回 false
TryRun(cmd) {
    try
    {
        Run(cmd)
        return true
    }
    return false
}

; 从文本中提取链接（带 fastMode 开关，返回 [links, remaining]）
; fastMode=true：仅运行第一阶段（带协议 URL），用于超长文本避免阻塞
; remaining：最后一条命中 URL 之后的文本，供中文二次搜索使用
ExtractLinks(text, fastMode := false) {
    local links := []
    local foundUrls := Map()  ; 用于去重
    local maxEnd := 0         ; 所有匹配中“最后一个字符”的最大位置（1-based）

    ; 合法的TLD后缀列表（用于裸域名验证）
    static VALID_TLDS :=
        "com|net|org|edu|gov|mil|int|info|biz|name|pro|aero|coop|museum|asia|cat|jobs|mobi|tel|travel|xxx|post|fun|app|dev|io|xyz|ai|store|cloud|online|movie|game|games|tech|site|top|club|win|shop|live|news|blog|space|website|press|fit|yoga|art|design|photo|music|video|film|tv|fm|radio|email|click|help|support|wiki|data|software|systems|network|services|solutions|company|group|team|world|city|london|nyc|tokyo|berlin|paris|中国|网络|公司|游戏|娱乐|购物|餐厅|酒店|医疗|健康|教育|机构|政府|org.cn|net.cn|gov.cn|edu.cn|mil.cn|ac.cn|ah.cn|bj.cn|cq.cn|fj.cn|gd.cn|gs.cn|gx.cn|gz.cn|ha.cn|hb.cn|he.cn|hi.cn|hk.cn|hl.cn|hn.cn|jl.cn|js.cn|jx.cn|ln.cn|mo.cn|nm.cn|nx.cn|qh.cn|sc.cn|sd.cn|sh.cn|sn.cn|sx.cn|tj.cn|tw.cn|xj.cn|xz.cn|yn.cn|zj.cn|co.uk|ac.uk|gov.uk|org.uk|net.uk|nhs.uk|police.uk|sch.uk|co.jp|ac.jp|go.jp|or.jp|ne.jp|gr.jp|co.au|com.au|net.au|org.au|edu.au|gov.au|asn.au|id.au|co.kr|or.kr|ne.kr|re.kr|pe.kr|go.kr|mil.kr|ac.kr|hs.kr|ms.kr|es.kr|sc.kr|kg.kr|se.kr|co.nz|net.nz|org.nz|ac.nz|govt.nz|school.nz|maori.nz|iwi.nz|co.ca|gc.ca"

    ; RFC3986 合法URL字符集（额外包含 | 以支持 ed2k://|file|...）
    static UNRESERVED := "a-zA-Z0-9\-._~"
    static SUB_DELIMS := "!$&'()*+,;="
    static PCHAR := UNRESERVED . SUB_DELIMS . ":@"
    static URL_CHARS := PCHAR . "/?#%|"

    ; ============================================
    ; 第一阶段：带明确协议的 URL（优先级最高）
    ; ============================================

    ; 标准协议 + 浏览器内部协议 + 编辑器/笔记/IM/P2P 扩展协议
    static PROTOCOL_PATTERN := "i)(?:https?|ftp|file|chrome|edge|about|brave|opera|vivaldi"
        . "|vscode|vscodium|cursor|windsurf|trae|zed|fleet"
        . "|obsidian|notion|logseq|bear|workflowy"
        . "|jetbrains|subl|atom|weixin|tencent|dingtalk|feishu|slack|zoommtg|teams"
        . "|steam|spotify|thunder|ed2k|qq|aliim|smb)://[" . URL_CHARS . "]+"

    local pos := 1
    while (pos := RegExMatch(text, PROTOCOL_PATTERN, &match, pos)) {
        local endPos := match.Pos + match.Len - 1
        if (endPos > maxEnd)
            maxEnd := endPos
        local url := CleanUrlBoundaries(match[0])
        if (url != "" && IsValidUrl(url, VALID_TLDS)) {
            ; 标准化URL用于去重（去除协议和尾部斜杠）
            local normalizedUrl := RegExReplace(url, "i)^[a-zA-Z][a-zA-Z0-9+\-.]*://", "")
            normalizedUrl := RegExReplace(normalizedUrl, "/$", "")
            if (!foundUrls.Has(normalizedUrl)) {
                foundUrls[normalizedUrl] := true
                links.Push(url)
            }
        }
        pos += match.Len[0]
    }

    ; 快速模式（长文本）：不跑后续阶段，直接返回
    if (fastMode)
        return [links, ""]

    ; magnet: 链接（注意格式为 magnet:?xt=... 无 //）
    static MAGNET_PATTERN := "i)magnet:\?[" . URL_CHARS . "]+"
    pos := 1
    while (pos := RegExMatch(text, MAGNET_PATTERN, &match, pos)) {
        local endPos := match.Pos + match.Len - 1
        if (endPos > maxEnd)
            maxEnd := endPos
        local url := CleanUrlBoundaries(match[0])
        if (url != "" && !foundUrls.Has(url)) {
            foundUrls[url] := true
            links.Push(url)
        }
        pos += match.Len[0]
    }

    ; 特殊协议: mailto:, tel:
    static MAILTO_PATTERN := "i)mailto:[" . UNRESERVED . SUB_DELIMS . ":@%]+"
    pos := 1
    while (pos := RegExMatch(text, MAILTO_PATTERN, &match, pos)) {
        local endPos := match.Pos + match.Len - 1
        if (endPos > maxEnd)
            maxEnd := endPos
        local url := CleanUrlBoundaries(match[0])
        if (url != "" && !foundUrls.Has(url)) {
            foundUrls[url] := true
            links.Push(url)
        }
        pos += match.Len[0]
    }

    static TEL_PATTERN := "i)tel:\+?[0-9\-() ]+"
    pos := 1
    while (pos := RegExMatch(text, TEL_PATTERN, &match, pos)) {
        local endPos := match.Pos + match.Len - 1
        if (endPos > maxEnd)
            maxEnd := endPos
        local url := CleanUrlBoundaries(match[0])
        if (url != "" && !foundUrls.Has(url)) {
            foundUrls[url] := true
            links.Push(url)
        }
        pos += match.Len[0]
    }

    ; ============================================
    ; 第二阶段：匹配裸域名（无协议）
    ; ============================================

    ; 域名标签规则
    static LABEL_PATTERN := "(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-_]{0,61}[a-zA-Z0-9])?)"

    ; 裸域名匹配模式
    static DOMAIN_PATTERN := "(?<![a-zA-Z0-9\-._~])"
        . "((?:" . LABEL_PATTERN . "\.)+"
        . "(" . VALID_TLDS . ")"
        . "(?::\d{1,5})?"
        . "(?:/[" . URL_CHARS . "]*)?)"
        . "(?![a-zA-Z0-9\-._~%])"

    pos := 1
    while (pos := RegExMatch(text, DOMAIN_PATTERN, &match, pos)) {
        local endPos := match.Pos + match.Len - 1
        if (endPos > maxEnd)
            maxEnd := endPos
        local url := CleanUrlBoundaries(match[1])
        local tld := match[2]

        ; 排除误判：确保不是单独的"ne."、"com."等
        if (StrLen(url) <= StrLen(tld) + 1) {
            pos += match.Len[0]
            continue
        }

        ; 排除看起来像版本号的 (如 1.2.3)
        if (RegExMatch(url, "^\d+\.\d+\.\d+")) {
            pos += match.Len[0]
            continue
        }

        if (url != "" && IsValidUrl(url, VALID_TLDS)) {
            ; 自动补全 https:// 协议
            if (!RegExMatch(url, "i)^[a-zA-Z][a-zA-Z0-9+\-.]*:"))
                url := "https://" . url

            ; 标准化URL用于去重
            local normalizedUrl := RegExReplace(url, "i)^[a-zA-Z][a-zA-Z0-9+\-.]*://", "")
            normalizedUrl := RegExReplace(normalizedUrl, "/$", "")
            if (!foundUrls.Has(normalizedUrl)) {
                foundUrls[normalizedUrl] := true
                links.Push(url)
            }
        }
        pos += match.Len[0]
    }

    ; ============================================
    ; 第三阶段：匹配IP地址
    ; ============================================

    static IP_PATTERN := "(?<![0-9.])"
        . "((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}"
        . "(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))"
        . "(?::\d{1,5})?"
        . "(?:/[" . URL_CHARS . "]*)?"
        . "(?![0-9.])"

    pos := 1
    while (pos := RegExMatch(text, IP_PATTERN, &match, pos)) {
        local endPos := match.Pos + match.Len - 1
        if (endPos > maxEnd)
            maxEnd := endPos
        local rawIp := match[1]
        local url := CleanUrlBoundaries(rawIp)

        ; 排除特殊IP（仅当清理后的URL就是纯IP时）
        if (url = "0.0.0.0" || url = "255.255.255.255" || url = "127.0.0.1") {
            pos += match.Len[0]
            continue
        }

        if (url != "") {
            ; IP地址自动补全 http:// 协议（而非 https://）
            if (!RegExMatch(url, "i)^[a-zA-Z][a-zA-Z0-9+\-.]*:"))
                url := "http://" . url

            ; 标准化URL用于去重
            local normalizedUrl := RegExReplace(url, "i)^[a-zA-Z][a-zA-Z0-9+\-.]*://", "")
            normalizedUrl := RegExReplace(normalizedUrl, "/$", "")
            if (!foundUrls.Has(normalizedUrl)) {
                foundUrls[normalizedUrl] := true
                links.Push(url)
            }
        }
        pos += match.Len[0]
    }

    ; 计算剩余文本：最后一条命中 URL 之后的部分
    local remaining := ""
    if (maxEnd > 0 && maxEnd < StrLen(text))
        remaining := Trim(SubStr(text, maxEnd + 1), " `t`r`n")

    return [links, remaining]
}

; 清理URL前后的干扰字符
CleanUrlBoundaries(url) {
    if (url = "")
        return ""

    ; 前向清理：移除开头的标点、引号、括号等
    local leadingChars := "'" . '"' . "()[]{}<>,.;:!?-_=+&| `t`r`n"
    while (StrLen(url) > 0 && InStr(leadingChars, SubStr(url, 1, 1), true))
        url := SubStr(url, 2)

    ; 后向清理：移除结尾的标点、引号、括号等（下划线也清理，避免chrome://extensions/_）
    local trailingChars := "'" . '"' . "()[]{}<>,.;:!?-_=+&| `t`r`n"
    while (StrLen(url) > 0 && InStr(trailingChars, SubStr(url, -1), true)) {
        local lastChar := SubStr(url, -1)
        if (lastChar = ")" || lastChar = "]" || lastChar = "}" || lastChar = ">") {
            local openChar := lastChar = ")" ? "(" : (lastChar = "]" ? "[" : (lastChar = "}" ? "{" : "<"))
            local openCount := 0, closeCount := 0
            loop parse url {
                if (A_LoopField = openChar)
                    openCount++
                else if (A_LoopField = lastChar)
                    closeCount++
            }
            if (openCount < closeCount)
                break
        }
        url := SubStr(url, 1, -1)
    }

    return url
}

; 严格验证URL合法性
IsValidUrl(url, validTlds) {
    if (url = "")
        return false

    ; 扩展协议（编辑器 / 笔记 / IM / P2P / 媒体）：直接放行
    ; vscode:// cursor:// obsidian:// jetbrains:// weixin:// thunder:// ed2k:// magnet: ...
    if (RegExMatch(url,
        "i)^(vscode|vscodium|cursor|windsurf|trae|zed|fleet|obsidian|notion|logseq|bear|workflowy|jetbrains|subl|atom|weixin|tencent|dingtalk|feishu|slack|zoommtg|teams|steam|spotify|thunder|ed2k|qq|aliim|smb|magnet):"
    ))
        return true

    ; 带协议的URL基本验证
    if (RegExMatch(url, "i)^(https?|ftp|file|chrome|edge|about|brave|opera|vivaldi)://")) {
        local domainStart := InStr(url, "://") + 3
        if (domainStart > StrLen(url))
            return false

        local rest := SubStr(url, domainStart)
        if (rest = "")
            return false

        if (SubStr(url, 1, 9) = "chrome://")
            return true

        if (SubStr(url, 1, 7) = "file://")
            return true

        local slashPos := InStr(rest, "/")
        local colonPos := InStr(rest, ":")
        local domainEnd := StrLen(rest) + 1
        if (slashPos > 0)
            domainEnd := slashPos
        if (colonPos > 0 && colonPos < domainEnd)
            domainEnd := colonPos

        local domain := SubStr(rest, 1, domainEnd - 1)
        if (domain = "")
            return false

        return true
    }

    ; mailto:, tel: 特殊处理
    if (SubStr(url, 1, 7) = "mailto:")
        return true
    if (SubStr(url, 1, 4) = "tel:")
        return true

    if (url = "localhost" || RegExMatch(url, "^(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)(:\\d+)?$"))
        return true

    if (!InStr(url, "."))
        return false

    ; 提取TLD
    local domainPart := url
    local slashPos := InStr(url, "/")
    local colonPos := InStr(url, ":", , InStr(url, "."))
    local queryPos := InStr(url, "?")
    local hashPos := InStr(url, "#")

    local domainEnd := StrLen(url) + 1
    if (slashPos > 0 && slashPos < domainEnd)
        domainEnd := slashPos
    if (colonPos > 0 && colonPos < domainEnd)
        domainEnd := colonPos
    if (queryPos > 0 && queryPos < domainEnd)
        domainEnd := queryPos
    if (hashPos > 0 && hashPos < domainEnd)
        domainEnd := hashPos

    domainPart := SubStr(url, 1, domainEnd - 1)

    ; 验证TLD是否在合法列表中
    local tldPattern := "\.(" . validTlds . ")$"
    if (!RegExMatch(domainPart, tldPattern))
        return false

    ; 确保不是只有TLD（如 ".com"）
    local dotPos := InStr(domainPart, ".", , -1)
    if (dotPos <= 1)
        return false

    return true
}

ShowLinkPanel(links, remaining := "") {
    global g_LinkPanel, g_PanelLinks, g_ButtonUrlMap, g_MaxLinks, g_PanelRemaining, g_PanelAlsoSearchChk,
        g_AutoClosePanel
    ; 关闭并销毁已有面板，避免多次触发时面板叠加
    CloseLinkPanel()

    ; 缓存面板状态（供数字快捷键 / 右键菜单 / 同时搜索剩余文本使用）
    g_PanelLinks := links
    g_ButtonUrlMap := Map()
    g_PanelRemaining := remaining
    g_PanelAlsoSearchChk := unset

    local panel := Gui("+AlwaysOnTop +ToolWindow +Resize +MinSize400x100")
    panel.SetFont("s10", "Segoe UI")
    panel.Title := "选择链接"

    ; 标题提示
    local infoText := "发现 " links.Length " 个链接，点击或按数字键 1-9 (0=10) 打开："
    panel.AddText("w400 cBlue", infoText)

    ; P2-5：若剩余文本含中文，提供复选框“关闭面板时同时搜索剩余文本”
    ; 【已禁用】用户反馈行为不够直觉，暂不启用
    ; if (remaining != "" && IsChineseText(remaining)) {
    ;     local chk := panel.AddCheckBox("w400 cBlue", "关闭面板时同时搜索：" SubStr(remaining, 1, 30) (StrLen(remaining) > 30 ?
    ;         "…" : ""))
    ;     chk.Value := 1
    ;     g_PanelAlsoSearchChk := chk
    ; }

    for index, url in links {
        if (index > g_MaxLinks)
            break
        ; 前 10 条加数字前缀，提示快捷键
        local prefix := index <= 10 ? "[" index "] " : ""
        local displayText := prefix . GetDisplayUrl(url, 70 - StrLen(prefix))
        local btn := panel.AddButton("w400 h28", displayText)
        btn.OnEvent("Click", OpenLinkHandler.Bind(url))
        ; 建立按钮 Hwnd -> URL 映射，供右键菜单查表
        g_ButtonUrlMap[btn.Hwnd] := url
    }

    local closeBtn := panel.AddButton("w400 h28", "关闭 (Esc)")
    closeBtn.OnEvent("Click", ClosePanelHandler)
    panel.OnEvent("Close", ClosePanelHandler)
    panel.OnEvent("Escape", ClosePanelHandler)
    panel.OnEvent("ContextMenu", OnPanelContextMenu)

    g_LinkPanel := panel
    panel.Show("Center AutoSize")

    ; P2-7c：启用失焦自动关闭时启动监控定时器
    ; 【已禁用】用户反馈容易误关闭，暂不启用
    ; if (g_AutoClosePanel)
    ;     StartPanelFocusWatch()
}

; 链接面板是否为当前活动窗口（供 #HotIf 使用）
IsLinkPanelActive() {
    global g_LinkPanel
    return IsSet(g_LinkPanel) && WinActive("ahk_id " g_LinkPanel.Hwnd)
}

; 数字键快捷选择链接
PanelSelectLink(index) {
    global g_PanelLinks
    if (index < 1 || index > g_PanelLinks.Length)
        return
    local url := g_PanelLinks[index]
    CloseLinkPanel(true)  ; 同样触发“同时搜索剩余文本”
    OpenUrl(url)
}

; 面板右键菜单：打开 / 复制链接 / 复制域名
OnPanelContextMenu(guiObj, ctrlObj, *) {
    global g_ButtonUrlMap
    if (!IsObject(ctrlObj) || !g_ButtonUrlMap.Has(ctrlObj.Hwnd))
        return
    local url := g_ButtonUrlMap[ctrlObj.Hwnd]
    local m := Menu()
    m.Add("打开", (*) => (CloseLinkPanel(true), OpenUrl(url)))
    m.Add("复制链接", (*) => CopyToClipboard(url))
    m.Add("复制域名", (*) => CopyToClipboard(ExtractHostFromUrl(url)))
    m.Add()  ; 分隔线
    m.Add("关闭面板", (*) => CloseLinkPanel(true))
    m.Show()
}

; 将文本写入剪贴板（不弹面板，仅图标提示）
CopyToClipboard(text) {
    try
    {
        A_Clipboard := text
        TrayTip("已复制：" SubStr(text, 1, 60), "Flash Search", "Iconi T1")
    }
    catch Error as e
        MsgBox("复制失败：`n" e.Message, "Flash Search", "Icon!")
}

; 从 URL 提取主机部分（scheme://host[:port]）
ExtractHostFromUrl(url) {
    if (RegExMatch(url, "i)^[a-z][a-z0-9+\-.]*://([^/?#]+)", &m))
        return m[1]
    ; magnet: / mailto: / tel: 等非层级协议直接返回原文
    return url
}

; P2-11：优先保留 scheme://host 前缀 + path 尾段，非层级 URL 回退头尾截断
GetDisplayUrl(url, maxLen) {
    if (StrLen(url) <= maxLen)
        return url

    ; 拆分层级 URL：scheme://host[:port] / path?query#hash
    if (RegExMatch(url, "i)^([a-z][a-z0-9+\-.]*://[^/?#]+)([/?#].*)?$", &m)) {
        local head := m[1]      ; scheme://host
        local tail := m[2] != "" ? m[2] : ""

        ; 头部已超长 → 直接截头
        if (StrLen(head) >= maxLen - 3)
            return SubStr(head, 1, maxLen - 3) "..."

        ; 剩余空间给 path/query（保留尾段，因为尾部通常包含关键信息）
        local budget := maxLen - StrLen(head) - 3
        if (StrLen(tail) <= budget)
            return head tail
        return head "..." SubStr(tail, -budget)
    }

    ; 非层级协议（magnet: mailto: tel: 等）回退到头尾截断
    local headLen := Integer(maxLen * 0.6)
    local tailLen := maxLen - headLen - 3
    if (tailLen <= 0)
        return SubStr(url, 1, maxLen - 3) "..."
    return SubStr(url, 1, headLen) "..." SubStr(url, -tailLen)
}

OpenLinkHandler(url, *) {
    CloseLinkPanel(true)
    OpenUrl(url)
}

ClosePanelHandler(*) {
    CloseLinkPanel(true)
}

; 关闭并销毁链接选择面板（幂等，可重复调用）
; triggerSearch=true 时：若“同时搜索剩余文本”复选框勾选，销毁后发起搜索
CloseLinkPanel(triggerSearch := false) {
    global g_LinkPanel, g_PanelLinks, g_ButtonUrlMap, g_PanelRemaining, g_PanelAlsoSearchChk

    ; 先抓取待搜索文本（面板销毁后控件就不存在了）
    local pendingSearch := ""
    ; 注：AHK v2 中 unset 不能用于比较表达式，IsSet() 已足够判断
    if (triggerSearch && IsSet(g_PanelAlsoSearchChk)) {
        try {
            if (g_PanelAlsoSearchChk.Value = 1 && g_PanelRemaining != "" && IsChineseText(g_PanelRemaining))
                pendingSearch := g_PanelRemaining
        }
    }

    ; 停止失焦监控（若已启动）
    StopPanelFocusWatch()

    if IsSet(g_LinkPanel) {
        try g_LinkPanel.Destroy()
        g_LinkPanel := unset
    }
    ; 同时清理面板状态缓存，避免数字键/右键菜单误触发旧数据
    g_PanelLinks := []
    g_ButtonUrlMap := Map()
    g_PanelRemaining := ""
    g_PanelAlsoSearchChk := unset

    ; 面板销毁后再发起搜索，避免搜索时面板还占焦点
    if (pendingSearch != "")
        SearchInBrowser(pendingSearch)
}

; ============================================
; P2-7c：面板失焦自动关闭监控
; ============================================

; 启动定时监控（已启动则忽略）
StartPanelFocusWatch() {
    global g_PanelFocusTimer
    if (g_PanelFocusTimer != 0)
        return
    g_PanelFocusTimer := SetTimer(CheckPanelFocus, 300)
}

; 停止定时监控
StopPanelFocusWatch() {
    global g_PanelFocusTimer
    if (g_PanelFocusTimer != 0) {
        try SetTimer(CheckPanelFocus, 0)
        g_PanelFocusTimer := 0
    }
}

; 定时检查面板焦点：失焦超过 1.5s 则自动关闭
CheckPanelFocus() {
    global g_LinkPanel
    static inactiveStart := 0

    ; 面板已不存在 → 自行停止监控
    if (!IsSet(g_LinkPanel)) {
        StopPanelFocusWatch()
        inactiveStart := 0
        return
    }

    if (!WinActive("ahk_id " g_LinkPanel.Hwnd)) {
        if (inactiveStart = 0)
            inactiveStart := A_TickCount
        else if (A_TickCount - inactiveStart > 1500) {
            inactiveStart := 0
            ; 失焦自动关闭不触发“同时搜索”（避免意外弹浏览器）
            CloseLinkPanel(false)
        }
    } else {
        inactiveStart := 0
    }
}

OpenUrl(url) {
    ; 浏览器内部协议（chrome:// edge:// about:// 等）无法外部 Run，转为搜索
    if (RegExMatch(url, "i)^(chrome|edge|about|brave|opera|vivaldi)://")) {
        SearchInBrowser(url)
        return
    }

    try
    {
        ; vscode:// cursor:// obsidian:// magnet: thunder:// 等扩展协议交由系统协议处理器
        Run(url)
    }
    catch Error as e {
        MsgBox("无法打开链接：`n" . url . "`n`n错误：" . e.Message
            . "`n`n提示：若为 vscode:// / cursor:// / obsidian:// 等协议，请确认对应软件已安装并已注册协议处理器。",
            "错误", "Icon!")
    }
}

SearchInBrowser(query) {
    if (query = "")
        return
    ; 引擎可在托盘菜单切换，持久化到 flash-search.ini
    local searchUrl := GetSearchUrl(query)
    try
    {
        Run(searchUrl)
    }
    catch Error as e {
        MsgBox("无法执行搜索：`n" . e.Message, "错误", "Icon!")
    }
}

UriEncode(str) {
    local out := ""
    local hex := "0123456789ABCDEF"
    loop parse str {
        local ch := A_LoopField
        local code := Ord(ch)
        if (IsUnreservedChar(code)) {
            out .= ch
        }
        else {
            out .= EncodeCharToUtf8Hex(ch, hex)
        }
    }
    return out
}

EncodeCharToUtf8Hex(ch, hex) {
    local result := ""
    local size := StrPut(ch, "UTF-8")
    local buf := Buffer(size)
    StrPut(ch, buf.Ptr, "UTF-8")
    loop size - 1 {
        local b := NumGet(buf, A_Index - 1, "UChar")
        result .= "%" . SubStr(hex, (b >> 4) + 1, 1) . SubStr(hex, (b & 15) + 1, 1)
    }
    return result
}

IsUnreservedChar(code) {
    return (code >= 65 && code <= 90)
    || (code >= 97 && code <= 122)
    || (code >= 48 && code <= 57)
    || code = 45
        || code = 95
        || code = 46
        || code = 126
}

; ============================================
; 设置面板（读写 flash-search.ini）
; ============================================

; 控件引用缓存（供保存回调读取）
global g_SetCtrl := Map()

ShowSettings() {
    global g_SettingsGui, g_SetCtrl
    global g_SearchEngine, g_SearchEngines
    global g_TextEditor, g_FolderOpener, g_FolderCustomCmd
    global g_MaxLinks, g_Autostart, g_AutoClosePanel
    global g_FolderOpenerOptions
    global g_Hotkey

    CloseSettings()

    local dlg := Gui("+AlwaysOnTop", "Flash Search 设置")
    dlg.SetFont("s10", "Segoe UI")
    dlg.MarginX := 14
    dlg.MarginY := 12
    g_SetCtrl := Map()

    ; === 搜索引擎 ===
    dlg.AddGroupBox("xm w500 h62", "搜索引擎")
    dlg.AddText("xp+14 yp+30", "默认引擎：")
    local engineDdl := dlg.AddDropDownList("x+6 w200", g_SearchEngines)
    engineDdl.Choose(g_SearchEngine)
    g_SetCtrl["engine"] := engineDdl

    ; === 触发快捷键 ===
    dlg.AddGroupBox("xm y+10 w500 h90", "触发快捷键")
    dlg.AddText("xp+14 yp+30", "当前绑定：")
    local hotkeyEdit := dlg.AddEdit("x+6 w160 ReadOnly", FormatHotkeyDisplay(g_Hotkey))
    g_SetCtrl["hotkey"] := hotkeyEdit
    local rebindBtn := dlg.AddButton("x+8 w100 h26", "重新绑定…")
    rebindBtn.OnEvent("Click", (*) => RebindHotkey())
    local resetBtn := dlg.AddButton("x+6 w80 h26", "恢复 Alt+Y")
    resetBtn.OnEvent("Click", (*) => ResetHotkeyToDefault())
    dlg.AddText("xp+14 y+8 cGray", "AHK 语法：^=Ctrl  !=Alt  +=Shift  #=Win（例：^!y = Ctrl+Alt+Y）")
    g_SetCtrl["hotkeyRaw"] := g_Hotkey  ; 保存原始值，显示用友好格式

    ; === 文件打开方式 ===
    dlg.AddGroupBox("xm y+10 w500 h105", "文件打开（选中本地文件路径时）")
    dlg.AddText("xp+14 yp+30", "编辑器 exe：")
    local editorEdit := dlg.AddEdit("x+6 w310", g_TextEditor)
    g_SetCtrl["editor"] := editorEdit
    local browseBtn := dlg.AddButton("x+6 w70 h26", "浏览…")
    browseBtn.OnEvent("Click", (*) => BrowseForEditor())
    dlg.AddText("xp+14 y+8 cGray", "留空 = 交给 Windows 默认关联程序打开文件")

    ; === 文件夹打开方式 ===
    dlg.AddGroupBox("xm y+10 w500 h105", "文件夹打开（选中本地文件夹路径时）")
    dlg.AddText("xp+14 yp+30", "方式：")
    local folderLabels := []
    local folderValues := []
    for _, pair in g_FolderOpenerOptions {
        folderValues.Push(pair[1])
        folderLabels.Push(pair[2])
    }
    local folderDdl := dlg.AddDropDownList("x+6 w260", folderLabels)
    ; 定位当前选中项
    local folderIdx := 1
    for i, v in folderValues {
        if (v = g_FolderOpener) {
            folderIdx := i
            break
        }
    }
    folderDdl.Choose(folderIdx)
    g_SetCtrl["folder"] := folderDdl
    g_SetCtrl["folderValues"] := folderValues
    dlg.AddText("xp+14 y+8", "自定义命令：")
    local customEdit := dlg.AddEdit("x+6 w310", g_FolderCustomCmd)
    g_SetCtrl["folderCustom"] := customEdit
    dlg.AddText("xp+14 y+6 cGray", "占位符：{path}=本地路径、{uri}=正斜杠路径（仅自定义时生效）")

    ; === 面板 & 其他 ===
    dlg.AddGroupBox("xm y+10 w500 h105", "面板 与 其他")
    dlg.AddText("xp+14 yp+30", "面板最多链接数：")
    local maxLinksEdit := dlg.AddEdit("x+6 w60 Number", String(g_MaxLinks))
    g_SetCtrl["maxLinks"] := maxLinksEdit
    dlg.AddText("x+6 cGray", "（1 – 100）")
    ; 【已禁用】失焦自动关闭选项（行为容易误关闭）
    ; local autoCloseChk := dlg.AddCheckBox("xp+14 y+8", "面板失焦时自动关闭（1.5s）")
    ; autoCloseChk.Value := g_AutoClosePanel ? 1 : 0
    ; g_SetCtrl["autoClose"] := autoCloseChk
    local autostartChk := dlg.AddCheckBox("xp+14 y+8", "开机自动启动")
    autostartChk.Value := g_Autostart ? 1 : 0
    g_SetCtrl["autostart"] := autostartChk

    ; === 底部按钮 ===
    local saveBtn := dlg.AddButton("xm y+14 w130 h32 Default", "应用并保存")
    saveBtn.OnEvent("Click", (*) => SaveSettingsAndClose())
    local cancelBtn := dlg.AddButton("x+8 w90 h32", "取消")
    cancelBtn.OnEvent("Click", (*) => CloseSettings())
    local reloadBtn := dlg.AddButton("x+8 w110 h32", "从 ini 重载")
    reloadBtn.OnEvent("Click", (*) => ReloadSettingsFromIni())
    local exitBtn := dlg.AddButton("x+8 w90 h32", "退出程序")
    exitBtn.OnEvent("Click", (*) => ExitApp())

    dlg.OnEvent("Close", (*) => CloseSettings())
    dlg.OnEvent("Escape", (*) => CloseSettings())

    g_SettingsGui := dlg
    dlg.Show("AutoSize Center")
}

; 关闭设置窗口
CloseSettings() {
    global g_SettingsGui
    if (IsSet(g_SettingsGui)) {
        try g_SettingsGui.Destroy()
        g_SettingsGui := unset
    }
}

; ============================================
; 快捷键自定义相关辅助函数
; ============================================

; 将 AHK 原始快捷键语法转为友好显示（如 "!y" -> "Alt+Y"）
FormatHotkeyDisplay(raw) {
    local display := ""
    local key := raw
    ; 按顺序提取修饰符
    while (StrLen(key) > 0) {
        local c := SubStr(key, 1, 1)
        if (c = "^") {
            display .= "Ctrl+"
            key := SubStr(key, 2)
        }
        else if (c = "!") {
            display .= "Alt+"
            key := SubStr(key, 2)
        }
        else if (c = "+") {
            display .= "Shift+"
            key := SubStr(key, 2)
        }
        else if (c = "#") {
            display .= "Win+"
            key := SubStr(key, 2)
        }
        else
            break
    }
    ; 剩余为主键
    if (key != "")
        display .= StrUpper(SubStr(key, 1, 1)) . SubStr(key, 2)
    ; 去掉末尾 "+"
    if (SubStr(display, -1) = "+")
        display := SubStr(display, 1, StrLen(display) - 1)
    return display = "" ? raw : display
}

; 重新绑定快捷键（弹出捕获对话框，仅验证+存储，保存时才生效）
RebindHotkey() {
    global g_SetCtrl, g_Hotkey, g_HotkeyRegistered
    local captured := CaptureHotkey()
    if (captured = "")
        return  ; 用户按 Esc 取消
    ; 验证合法性：尝试注册后立即反注册（不影响当前活动快捷键）
    if (captured != g_HotkeyRegistered) {
        try {
            Hotkey(captured, MainHotkeyHandler, "On")
            Hotkey(captured, "Off")
        }
        catch Error as e {
            MsgBox("无法绑定到 " FormatHotkeyDisplay(captured) "：`n" e.Message, "Flash Search", "Icon!")
            return
        }
    }
    ; 存储到设置控件，等待用户点“应用并保存”时才真正生效
    g_SetCtrl["hotkeyRaw"] := captured
    g_SetCtrl["hotkey"].Value := FormatHotkeyDisplay(captured)
}

; 恢复默认快捷键 Alt+Y（仅存储，保存时才生效）
ResetHotkeyToDefault() {
    global g_SetCtrl
    local default := "!y"
    g_SetCtrl["hotkeyRaw"] := default
    g_SetCtrl["hotkey"].Value := FormatHotkeyDisplay(default)
}

; 捕获用户按下的快捷键组合（InputHook + OnKeyDown）
; 返回 AHK 原始语法字符串（如 "^!y"），取消返回空字符串
CaptureHotkey() {
    global g_CapturedHotkey
    g_CapturedHotkey := ""

    local dlg := Gui("+AlwaysOnTop +ToolWindow", "按下新快捷键")
    dlg.SetFont("s11", "Segoe UI")
    dlg.AddText("w340 h80 Center", "请按下想要绑定的组合键…`n`n按 Esc 取消")
    dlg.Show("AutoSize Center")

    ; 使用 InputHook 捕获按键事件
    local ih := InputHook("I")   ; I = 忽略文本输入，仅关注按键事件
    ih.KeyOpt("{All}", "N")     ; N = Notify，所有按键都触发 OnKeyDown
    ih.OnKeyDown := CaptureHotkeyKeyDown
    ih.Start()
    ih.Wait()

    dlg.Destroy()
    return g_CapturedHotkey
}

; InputHook 的 OnKeyDown 回调
CaptureHotkeyKeyDown(ih, vk, sc) {
    global g_CapturedHotkey
    local keyName := GetKeyName(Format("vk{:X} sc{:X}", vk, sc))

    ; Esc 取消
    if (keyName = "Esc" || keyName = "Escape") {
        g_CapturedHotkey := ""
        ih.Stop()
        return
    }

    ; 跳过纯修饰符按键（等待主键按下）
    if (keyName ~= "i)^(Ctrl|Alt|Shift|LWin|RWin|LControl|RControl|LAlt|RAlt|LShift|RShift|Control)$")
        return

    ; 组合修饰符
    local mods := ""
    if (GetKeyState("Ctrl", "P"))
        mods .= "^"
    if (GetKeyState("Alt", "P"))
        mods .= "!"
    if (GetKeyState("Shift", "P"))
        mods .= "+"
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        mods .= "#"

    ; 拼接完整快捷键
    g_CapturedHotkey := mods . keyName
    ih.Stop()
}

; 浏览选择编辑器 exe
BrowseForEditor() {
    global g_SetCtrl
    local current := g_SetCtrl.Has("editor") ? g_SetCtrl["editor"].Value : ""
    local startDir := ""
    if (current != "" && FileExist(current)) {
        ; 使用 AHK v2 内置 SplitPath（避免自定义同名函数遮蔽内置）
        local _fileName := "", _dir := ""
        SplitPath(current, &_fileName, &_dir)
        startDir := _dir
    }
    local selected := FileSelect("1", startDir, "选择文本编辑器", "可执行文件 (*.exe; *.com; *.bat)")
    if (selected != "")
        g_SetCtrl["editor"].Value := selected
}

; 仅从 ini 重新载入（丢弃当前面板未保存的修改）
ReloadSettingsFromIni() {
    LoadConfig()
    CloseSettings()
    ShowSettings()
    TrayTip("已从 flash-search.ini 重新载入配置", "Flash Search", "Iconi T1")
}

; 保存设置并关闭
SaveSettingsAndClose() {
    global g_SetCtrl
    global g_SearchEngine, g_MaxLinks, g_TextEditor
    global g_FolderOpener, g_FolderCustomCmd, g_AutoClosePanel, g_Autostart
    global g_FolderOpenerOptions
    global g_Hotkey

    ; 搜索引擎
    g_SearchEngine := g_SetCtrl["engine"].Text

    ; 面板链接数
    local maxLinksRaw := Trim(g_SetCtrl["maxLinks"].Value, " `t")
    local maxLinks := 30
    if (RegExMatch(maxLinksRaw, "^\d+$"))
        maxLinks := Integer(maxLinksRaw)
    if (maxLinks < 1 || maxLinks > 100) {
        MsgBox("面板链接数需在 1-100 之间，已重置为 30。", "Flash Search", "Icon!")
        maxLinks := 30
    }
    g_MaxLinks := maxLinks

    ; 文本编辑器
    g_TextEditor := Trim(g_SetCtrl["editor"].Value, " `t`"")

    ; 文件夹打开方式
    local folderIdx := g_SetCtrl["folder"].Value  ; DDL 的 .Value 返回当前选中索引
    local folderValues := g_SetCtrl["folderValues"]
    if (folderIdx >= 1 && folderIdx <= folderValues.Length)
        g_FolderOpener := folderValues[folderIdx]
    g_FolderCustomCmd := Trim(g_SetCtrl["folderCustom"].Value)

    ; 面板行为（失焦自动关闭已禁用）
    ; g_AutoClosePanel := g_SetCtrl["autoClose"].Value = 1

    ; 快捷键：保存时才真正注册生效
    if (g_SetCtrl.Has("hotkeyRaw")) {
        local newHotkey := g_SetCtrl["hotkeyRaw"]
        if (newHotkey != g_Hotkey) {
            g_Hotkey := newHotkey
            RegisterMainHotkey()
        }
    }

    ; 开机自启
    local newAutostart := g_SetCtrl["autostart"].Value = 1
    if (newAutostart != g_Autostart) {
        if (SetAutostart(newAutostart))
            g_Autostart := newAutostart
        else
            MsgBox("设置开机自启动失败", "Flash Search", "Icon!")
    }

    SaveConfig()
    ; 同步托盘菜单勾选状态
    SetupAutostartTray()
    CloseSettings()
    TrayTip("设置已保存到 flash-search.ini", "Flash Search", "Iconi T1")
}
