#Requires AutoHotkey v2.0
;@Ahk2Exe-SetName Ctrl2Enter
;@Ahk2Exe-SetOrigFilename Ctrl2Enter.ahk
;@Ahk2Exe-SetMainIcon logo.ico
;@Ahk2Exe-SetCopyright Copyright (c) 2026 SantaChains
;@Ahk2Exe-SetDescription Ctrl2Enter — 双击触发键发送 Enter
;@Ahk2Exe-UpdateManifest 1
#SingleInstance Force
#Warn All, Off

; ============================================================================
; Ctrl2Enter — 双击触发键发送 Enter（默认 Ctrl）
; 单击 / 长按保持原始按键功能不变；可编译为 exe，托盘控制开关与自启。
;
; 致谢
;   abgox/SpaceKey (https://github.com/abgox/SpaceKey)
;     · 托盘左键单击切换（OnMessage 0x404）、异常自愈（OnError 重启）
;     · 自定义屏幕提示 show_tip（多屏、透明、可定制，替代 TrayTip）
;     · Startup 快捷方式自启动（FileCreateShortcut）
;     · AutoHotkey64.exe 内嵌打包、#Warn 禁用 + ListLines(0) 等生产环境设置
;     · 编译清单指令内联（;@Ahk2Exe-*）
; ============================================================================

APP_NAME    := "Ctrl2Enter"
APP_VERSION := "0.0.1"
APP_AUTHOR  := "SantaChains"
CONFIG_DIR  := A_AppData "\Ctrl2Enter"
CONFIG_PATH := CONFIG_DIR "\config.json"

; ---------- 运行时性能 ----------
ListLines(0)
KeyHistory(5)

; ---------- 托盘左键单击切换启用/暂停 ----------
OnMessage(0x404, (wParam, lParam, *) => lParam == 0x202 ? ToggleEnabled() : "")

; ---------- 异常自愈 ----------
OnError(LogError)
LogError(exception, mode) {
    StartupLog("RUNTIME_ERROR  " exception.Message "`n" exception.Stack)
    try Run('"' A_AhkPath '" "' A_ScriptFullPath '"')
    return true
}

; ---------- 默认设置（首次运行使用，之后以 config.json 为准） ----------
gSettings := Map()
gSettings["trigger"]        := "LCtrl"        ; 双击该键触发 Enter（可用设置界面重新捕获）
gSettings["tapWindowMs"]    := 300            ; 连按窗口：两次按下的最大间隔（ms）
gSettings["tapMaxMs"]       := 500            ; 单次轻点允许按住的最长时间（ms），超过视为长按修饰键（仅配置项，无 GUI 控件）
gSettings["enabled"]        := true           ; 功能开关
gSettings["autostart"]      := false          ; 开机自动启动
gSettings["trayHidden"]     := false          ; 默认显示系统托盘（提供可见的运行指示；可在设置中隐藏）
gSettings["settingsHotkey"] := "^!s"          ; 打开设置热键

gEnabled          := true
gHotkeyRef        := ""
gSettingsHotkeyRef := ""
gMainGui          := ""

; ============================================================================
; JSON（自研字符级递归下降，无外部库；配置为扁平 Map，值为 字符串/数字/布尔）
; ============================================================================
JsonParse(src) {
    state := { src: src, p: 1 }
    JsonSkipWs(state)
    return JsonReadValue(state)
}
JsonSkipWs(state) {
    n := StrLen(state.src)
    while (state.p <= n) {
        c := SubStr(state.src, state.p, 1)
        if (c = " " || c = "`t" || c = "`n" || c = "`r")
            state.p := state.p + 1
        else
            break
    }
}
JsonReadValue(state) {
    c := SubStr(state.src, state.p, 1)
    if (c = "{") {
        return JsonReadObject(state)
    }
    if (c = "[") {
        return JsonReadArray(state)
    }
    if (c = '"') {
        return JsonReadString(state)
    }
    if (c = "t" || c = "f") {
        return JsonReadBool(state)
    }
    if (c = "n") {
        return JsonReadNull(state)
    }
    return JsonReadNumber(state)
}
JsonReadObject(state) {
    obj := Map()
    state.p := state.p + 1
    JsonSkipWs(state)
    if (SubStr(state.src, state.p, 1) = "}") {
        state.p := state.p + 1
        return obj
    }
    loop {
        JsonSkipWs(state)
        key := JsonReadString(state)
        JsonSkipWs(state)
        state.p := state.p + 1
        JsonSkipWs(state)
        val := JsonReadValue(state)
        obj[key] := val
        JsonSkipWs(state)
        c := SubStr(state.src, state.p, 1)
        if (c = ",") {
            state.p := state.p + 1
            continue
        }
        if (c = "}") {
            state.p := state.p + 1
            break
        }
        throw Error("JSON 解析失败：期望 , 或 }（位置 " state.p "）")
    }
    return obj
}
JsonReadArray(state) {
    arr := []
    state.p := state.p + 1
    JsonSkipWs(state)
    if (SubStr(state.src, state.p, 1) = "]") {
        state.p := state.p + 1
        return arr
    }
    loop {
        JsonSkipWs(state)
        arr.Push(JsonReadValue(state))
        JsonSkipWs(state)
        c := SubStr(state.src, state.p, 1)
        if (c = ",") {
            state.p := state.p + 1
            continue
        }
        if (c = "]") {
            state.p := state.p + 1
            break
        }
        throw Error("JSON 解析失败：期望 , 或 ]（位置 " state.p "）")
    }
    return arr
}
JsonReadString(state) {
    state.p := state.p + 1
    out := ""
    n := StrLen(state.src)
    while (state.p <= n) {
        c := SubStr(state.src, state.p, 1)
        if (c = '"') {
            state.p := state.p + 1
            return out
        }
        if (c = "\\") {
            state.p := state.p + 1
            e := SubStr(state.src, state.p, 1)
            switch e {
                case "n": out .= "`n"
                case "t": out .= "`t"
                case "r": out .= "`r"
                case '"': out .= '"'
                case "\\": out .= "\\"
                case "/": out .= "/"
                default: out .= e
            }
            state.p := state.p + 1
        } else {
            out .= c
            state.p := state.p + 1
        }
    }
    throw Error("JSON 解析失败：字符串未闭合")
}
JsonReadNumber(state) {
    start := state.p
    n := StrLen(state.src)
    while (state.p <= n) {
        c := SubStr(state.src, state.p, 1)
        ; v2 关系比较遇非数字字符串会抛错（"a" >= "0" → Expected a Number），
        ; 必须用 IsDigit 判数字字符，不可写 c >= "0"
        if (IsDigit(c) || c = "." || c = "-" || c = "+" || c = "e" || c = "E")
            state.p := state.p + 1
        else
            break
    }
    return Number(SubStr(state.src, start, state.p - start))
}
JsonReadBool(state) {
    c := SubStr(state.src, state.p, 1)
    if (c = "t") {
        state.p := state.p + 4
        return true
    }
    else {
        state.p := state.p + 5
        return false
    }
}
JsonReadNull(state) {
    state.p := state.p + 4
    return ""
}
JsonEncode(v) {
    if (v is Map) {
        parts := []
        for k, val in v
            parts.Push('"' JsonEscape(k) '":' JsonEncode(val))
        s := ""
        for i, p in parts
            s .= (i > 1 ? "," : "") p
        return "{" s "}"
    }
    if (v is Array) {
        parts := []
        for val in v
            parts.Push(JsonEncode(val))
        s := ""
        for i, p in parts
            s .= (i > 1 ? "," : "") p
        return "[" s "]"
    }
    if (v is String)
        return '"' JsonEscape(v) '"'
    return String(v)
}
JsonEscape(s) {
    out := ""
    for _, c in StrSplit(s) {
        switch c {
            case '"': out .= '\"'
            case '\': out .= '\\'
            case "`n": out .= '\n'
            case "`t": out .= '\t'
            case "`r": out .= '\r'
            default: out .= c
        }
    }
    return out
}

; ============================================================================
; 配置读写
; ============================================================================
SaveConfig() {
    if !DirExist(CONFIG_DIR)
        DirCreate(CONFIG_DIR)
    try FileDelete(CONFIG_PATH)
    FileAppend(JsonEncode(gSettings), CONFIG_PATH)
}
LoadConfig() {
    if !FileExist(CONFIG_PATH)
        return
    try {
        data := JsonParse(FileRead(CONFIG_PATH))
        if (data is Map) {
            for k, v in data
                if gSettings.Has(k)
                    gSettings[k] := v
        }
    } catch {
        ; 配置损坏则忽略，保留默认值
    }
    ; 历史脏数据修复：坏版本时期可能把空热键存入 config
    if (gSettings["settingsHotkey"] = "")
        gSettings["settingsHotkey"] := "^!s"
}

; ============================================================================
; 自定义屏幕提示（多屏、可定制，替代 TrayTip）
; ============================================================================
show_tip(Text, Delay := 1800, TextSize := 14, Ypos := 0, TextWeight := 700, TextColor := "F2F4F8", BgColor := "2A2D35", Xpos := 0) {
    gui_list := []
    screen_num := SysGet(80)
    while (screen_num > 0) {
        MonitorGet(screen_num, &Left, &Top, &Right, &Bottom)
        x := Right - ((Right - Left) / 2) + Xpos
        y := Bottom - 160 + Ypos
        gui_list.Push(_tip())
        screen_num--
    }
    _tip() {
        tip_gui := Gui("-Caption AlwaysOnTop ToolWindow +LastFound")
        tip_gui.SetFont("s" TextSize " c" TextColor " w" TextWeight " q5", "Segoe UI")
        tip_gui.BackColor := BgColor
        tip_gui.MarginX := 16
        tip_gui.MarginY := 8
        tip_gui.AddText("c" TextColor, Text)
        tip_gui.Show("hide")
        tip_gui.GetPos(, , &tip_gui_w, &tip_gui_h)
        x := x - (tip_gui_w / 2 * A_ScreenDPI / 100)
        y := y - tip_gui_h
        WinSetTransparent(225)
        tip_gui.Show("AutoSize X" x " Y" y " NA")
        if (Delay) {
            SetTimer(RemoveTip, Delay)
            RemoveTip() {
                SetTimer(RemoveTip, 0)
                tip_gui.Destroy()
            }
        }
        return tip_gui
    }
    return gui_list
}

; ============================================================================
; 开机自动启动（HKCU Run 注册表项，借鉴 flash-search；比 Startup 快捷方式抗破坏）
; 同步原则：config 记录用户意图；注册项为执行结果。启动时意图为开而注册项
; 缺失或指向旧路径 → 自动重建（自愈），而非静默关闭。
; ============================================================================
RUN_REG  := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
RUN_NAME := APP_NAME
AutostartCmd() {
    return A_IsCompiled ? '"' A_ScriptFullPath '"'
                        : '"' A_AhkPath '" "' A_ScriptFullPath '"'
}
AutostartExists() {
    try return RegRead(RUN_REG, RUN_NAME) != ""
    catch
        return false
}
CheckAutostart() {
    try return RegRead(RUN_REG, RUN_NAME) == AutostartCmd()
    catch
        return false
}
SetAutostart(on) {
    try {
        if on
            RegWrite(AutostartCmd(), "REG_SZ", RUN_REG, RUN_NAME)
        else
            RegDelete(RUN_REG, RUN_NAME)
        return true
    } catch {
        StartupLog("AUTOSTART_FAIL  on=" on "  err=" A_Error.Message)
        return false
    }
}

; ============================================================================
; 核心：双击触发键 → 发送 Enter
; 使用 ~ 透传：原生按键始终放行，故单击 / 长按原键位功能完全不受影响；
; 仅在窗口期内第二次按下时补发 Enter。
; ============================================================================
TriggerDown(ThisHotkey) {
    global gEnabled, gSettings
    if !gEnabled
        return
    static lastTap := 0
    key := gSettings["trigger"]

    ; 移植自 DoubleTapCtrlToEnter.ahk 的健壮判定：
    ; 只在“单独轻点”触发键时计数——快速松开 且 按住期间没有按下其它键。
    ; 由此可避免 Ctrl+C / Ctrl+V 等组合键、以及长按修饰键误触 Enter。
    ih := InputHook("V")            ; V = 不拦截按键，正常输入不受影响
    ih.KeyOpt("{All}", "E")         ; 任意键按下即结束监听，并记录到 EndKey
    ih.KeyOpt("{" key "}", "I")     ; 触发键自身被忽略（松开它不算“其它键”）
    ih.Start()

    ; 等待触发键松开；超过 tapMaxMs 则视为长按（当修饰键用）
    quickRelease := KeyWait(key, "T" (gSettings["tapMaxMs"] / 1000))
    ih.Stop()

    if (quickRelease && ih.EndKey = "") {
        now := A_TickCount
        if (lastTap > 0 && now - lastTap <= gSettings["tapWindowMs"]) {
            delta := now - lastTap
            Send "{Enter}"
            lastTap := 0
            show_tip("Enter", 600, 16)
            StartupLog("ENTER_SENT  delta=" delta "ms  window=" gSettings["tapWindowMs"])
        } else {
            lastTap := now          ; 第一次轻点，记下时间
        }
    } else {
        lastTap := 0                ; 长按 或 组合键 → 重置计数
    }
}
SetupTrigger() {
    global gHotkeyRef, gSettings
    if (gHotkeyRef != "") {
        try Hotkey(gHotkeyRef, "Off")
    }
    key := gSettings["trigger"]
    ; ~ 前缀必须拼进 KeyName（Hotkey() 只接受 3 个参数，传第 4 个 "~" 是加载期致命错误）
    gHotkeyRef := "~" key
    try {
        Hotkey(gHotkeyRef, TriggerDown, "On")
        StartupLog("SETUP_OK  trigger=" key)
    } catch {
        gHotkeyRef := ""
        StartupLog("SETUP_FAIL  trigger=" key "  err=" A_Error.Message)
        show_tip("触发键无效：" key, 3000, 14, 0, 700, "E87461")
    }
}
SetupSettingsHotkey(hk) {
    global gSettingsHotkeyRef
    if (gSettingsHotkeyRef != "") {
        try Hotkey(gSettingsHotkeyRef, "Off")
    }
    gSettingsHotkeyRef := hk
    try {
        Hotkey(hk, ShowSettings, "On")
        StartupLog("SETUP_OK  settingsHotkey=" hk)
    } catch {
        gSettingsHotkeyRef := ""
        StartupLog("SETUP_FAIL  settingsHotkey=" hk "  err=" A_Error.Message)
        show_tip("设置热键无效：" hk, 3000, 14, 0, 700, "E87461")
    }
}

; ============================================================================
; 托盘菜单
; ============================================================================
ToggleEnabled(ItemName := "", ItemPos := "", MyMenu := "") {
    global gEnabled, gSettings
    gEnabled := !gEnabled
    gSettings["enabled"] := gEnabled
    if gEnabled {
        try A_TrayMenu.Rename("映射已启用", "✓ 映射已启用")
        show_tip("映射已启用", 900)
    } else {
        try A_TrayMenu.Rename("✓ 映射已启用", "映射已启用")
        show_tip("映射已暂停", 900, 14, 0, 700, "E87461")
    }
    SaveConfig()
}
ToggleAutostart(ItemName := "", ItemPos := "", MyMenu := "") {
    global gSettings
    gSettings["autostart"] := !gSettings["autostart"]
    if gSettings["autostart"] {
        try A_TrayMenu.Rename("开机自动启动", "✓ 开机自动启动")
    } else {
        try A_TrayMenu.Rename("✓ 开机自动启动", "开机自动启动")
    }
    SetAutostart(gSettings["autostart"])
    SaveConfig()
}
NormalizeKey(k) {
    m := Map("LControl", "LCtrl", "RControl", "RCtrl", "Control", "Ctrl",
             "LAlt", "LAlt", "RAlt", "RAlt", "Escape", "Esc", "Return", "Enter")
    if m.Has(k)
        return m[k]
    return k
}
ExitHandler(ItemName := "", ItemPos := "", MyMenu := "") {
    ExitApp()
}

; ============================================================================
; 设置界面
; ============================================================================
ShowSettings(ItemName := "", ItemPos := "", MyMenu := "") {
    global gMainGui, gSettings
    if (gMainGui != "") {
        gMainGui.Show()
        return
    }
    g := Gui(, APP_NAME " v" APP_VERSION " — 设置")
    g.OnEvent("Close", (o) => o.Hide())
    g.SetFont("s10", "Segoe UI")

    ; ---------- 映射设置 ----------
    g.Add("GroupBox", "x16 y16 w540 h250", "映射设置")
    g.Add("Text", "x32 y40", "触发键")
    g.Add("Button", "x150 y36 w120 vBtnTrigger", gSettings["trigger"]).OnEvent("Click", RecordTriggerKey)
    g.Add("Text", "x32 y66 w500", "点击后按一下要作为触发键的按键；在间隔内双击它将发送 Enter。")
    g.Add("Text", "x32 y92", "双击间隔（连按窗口）")
    g.Add("Text", "x160 y94 w70 vLblTap", gSettings["tapWindowMs"] " ms")
    g.Add("Slider", "x240 y88 w300 Range50-1000 vSlTap", gSettings["tapWindowMs"]).OnEvent("Change", SlTapChanged)
    g.Add("Text", "x32 y118", "长按上限（单次按住）")
    g.Add("Text", "x160 y120 w70 vLblTapMax", gSettings["tapMaxMs"] " ms")
    g.Add("Slider", "x240 y114 w300 Range100-1500 vSlTapMax", gSettings["tapMaxMs"]).OnEvent("Change", SlTapMaxChanged)
    g.Add("CheckBox", "x32 y150 vChkEnabled", "启用映射（功能开关）").Value := gSettings["enabled"]
    g.Add("CheckBox", "x32 y176 vChkAuto", "开机自动启动").Value := gSettings["autostart"]
    g.Add("CheckBox", "x32 y202 vChkTray", "显示系统托盘图标").Value := !gSettings["trayHidden"]

    ; ---------- 打开设置 ----------
    g.Add("GroupBox", "x16 y282 w540 h72", "打开设置")
    g.Add("Text", "x32 y306", "打开设置热键")
    g.Add("Edit", "x150 y302 w120 vEdHotkey", gSettings["settingsHotkey"])
    g.Add("Button", "x290 y302 w120 vBtnApply", "应用并保存").OnEvent("Click", ApplySettings)
    g.Add("Button", "x420 y302 w90 vBtnExit", "退出").OnEvent("Click", ExitHandler)

    ; ---------- 关于 ----------
    g.Add("GroupBox", "x16 y370 w540 h146", "关于")
    g.Add("Text", "x32 y394", APP_NAME " v" APP_VERSION)
    g.Add("Link", "x32 y420 w500", 'GitHub：<a href="https://github.com/SantaChains/keyshadow">SantaChains/keyshadow</a>')
    g.Add("Text", "x32 y446", "作者：" APP_AUTHOR)
    g.Add("Text", "x32 y470 w500", "功能：在间隔内双击触发键 → 发送 Enter；单独按 / 长按保持原始按键功能不变。")
    g.Add("Text", "x32 y494 w500", "打开设置：托盘菜单（默认隐藏），或热键 " gSettings["settingsHotkey"] "。")

    g.Show("w572 h532")
    gMainGui := g
}
SlTapChanged(sl, *) {
    global gMainGui
    gMainGui["LblTap"].Text := sl.Value " ms"
}
SlTapMaxChanged(sl, *) {
    global gMainGui
    gMainGui["LblTapMax"].Text := sl.Value " ms"
}
RecordTriggerKey(btn, *) {
    global gMainGui, gSettings
    ih := InputHook("L1")
    ih.Start()
    if (ih.Wait() = "EndKey") {
        key := NormalizeKey(ih.EndKey)
        if (key != "") {
            gMainGui["BtnTrigger"].Text := key
            gSettings["trigger"] := key
        }
    }
}
ApplySettings(btn, *) {
    global gMainGui, gSettings
    g := gMainGui
    gSettings["trigger"]     := NormalizeKey(g["BtnTrigger"].Text)
    gSettings["tapWindowMs"] := g["SlTap"].Value
    gSettings["tapMaxMs"]    := g["SlTapMax"].Value
    gSettings["enabled"]     := g["ChkEnabled"].Value
    gSettings["autostart"]   := g["ChkAuto"].Value
    gSettings["trayHidden"]  := !g["ChkTray"].Value
    newHot := g["EdHotkey"].Text
    gSettings["settingsHotkey"] := newHot

    A_IconHidden := gSettings["trayHidden"]
    if gSettings["enabled"] {
        try A_TrayMenu.Rename("映射已启用", "✓ 映射已启用")
    } else {
        try A_TrayMenu.Rename("✓ 映射已启用", "映射已启用")
    }
    if gSettings["autostart"] {
        try A_TrayMenu.Rename("开机自动启动", "✓ 开机自动启动")
    } else {
        try A_TrayMenu.Rename("✓ 开机自动启动", "开机自动启动")
    }
    SetAutostart(gSettings["autostart"])
    SetupTrigger()
    SetupSettingsHotkey(newHot)
    SaveConfig()
    g["BtnTrigger"].Text := gSettings["trigger"]
    show_tip("设置已保存", 900)
}

; ============================================================================
; 启动诊断日志（用于区分「exe 未启动」与「启动中途崩溃」）
; ============================================================================
StartupLog(msg) {
    try {
        f := A_Temp "\Ctrl2Enter_startup.log"
        ts := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        FileAppend("[" ts "] " msg "`n", f)
    }
}

; ============================================================================
; 自动执行段
; ============================================================================
try {
    StartupLog("LAUNCH  " A_ScriptFullPath)
    LoadConfig()
    ; 迁移：清理旧版 Startup 快捷方式，避免双重启动
    oldLnk := A_Startup "\" APP_NAME ".lnk"
    if FileExist(oldLnk) {
        try FileDelete(oldLnk)
        StartupLog("legacy startup lnk removed")
    }
    ; 自愈式同步：意图（config autostart）为权威，注册项为结果
    if gSettings["autostart"] {
        if !CheckAutostart() {
            SetAutostart(true)
            StartupLog("autostart self-heal: reg recreated  path=" A_ScriptFullPath)
        }
    } else if AutostartExists() {
        SetAutostart(false)
        StartupLog("autostart sync: intent=off → reg deleted")
    }
    StartupLog("config loaded (trayHidden=" gSettings["trayHidden"] ", enabled=" gSettings["enabled"] ")")
    gEnabled := gSettings["enabled"]

    ; 清空默认托盘菜单项，重建为自定义菜单：按名称逐个删除，
    ; 不可对标准托盘菜单整体调用 Delete()（会触发不可捕获的致命错误）。
    for name in ["Open", "Help", "Window Spy", "Reload Script", "Edit Script", "Suspend Hotkeys", "Pause Script", "Exit"] {
        try A_TrayMenu.Delete(name)
    }
    A_TrayMenu.Add("打开设置...", ShowSettings)
    A_TrayMenu.Add()
    A_TrayMenu.Add("映射已启用", ToggleEnabled)
    if gEnabled
        try A_TrayMenu.Rename("映射已启用", "✓ 映射已启用")
    A_TrayMenu.Add("开机自动启动", ToggleAutostart)
    if gSettings["autostart"]
        try A_TrayMenu.Rename("开机自动启动", "✓ 开机自动启动")
    A_TrayMenu.Add()
    A_TrayMenu.Add("退出", ExitHandler)
    StartupLog("tray menu built")

    A_IconHidden := gSettings["trayHidden"]
    A_IconTip := APP_NAME

    SetupTrigger()
    SetupSettingsHotkey(gSettings["settingsHotkey"])
    StartupLog("hotkeys set (trigger=" gSettings["trigger"] ", settingsHotkey=" gSettings["settingsHotkey"] ")")

    ; 保活心跳：确保无 GUI 时（配置已存在、托盘隐藏）脚本持续运行不退出的保险措施
    SetTimer(KeepAlive, 1000)
    StartupLog("keepalive timer set")

    if !FileExist(CONFIG_PATH) {
        SaveConfig()
        ShowSettings()
    } else {
        ; 启动确认提示：无论托盘是否隐藏都弹出，避免「双击后无任何反馈」误以为未启动
        startup_msg := APP_NAME " 已启动 · " gSettings["trigger"] "×2 → Enter · " gSettings["settingsHotkey"] " 打开设置"
        show_tip(startup_msg, 2200, 13)
    }
    StartupLog("STARTUP DONE  (进程将保持运行，托盘图标=" (gSettings["trayHidden"] ? "隐藏" : "显示") ")")
} catch {
    StartupLog("FATAL  " A_Error.Message "`n" A_Error.Stack)
    MsgBox("Ctrl2Enter 启动失败：`n`n" A_Error.Message "`n`n详细日志：" A_Temp "\Ctrl2Enter_startup.log", APP_NAME, 0x10)
}

KeepAlive() {
}
