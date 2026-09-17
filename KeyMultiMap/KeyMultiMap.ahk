#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; KeyMultiMap — 键盘按键多重映射工具 (AutoHotkey v2)
;
;   任意触发键支持多重变式：
;     · 单击 / 双击 / 3 连按 / 4 连按 / 5 连按 —— 每级可映射：按键 / 文本 / 启动程序
;     · 长按（阈值可调，默认 500ms，即 Android/Material Design 标准）
;     · 未配置的层级自动透传原始按键，绝不吞键
;
;   配置为 JSON（%APPDATA%\KeyMultiMap\config.json），带版本号。
;   导入默认"按 id 合并"：同名替换、新增追加、本机独有保留——绝不损失数据。
;   每次保存前自动生成 config.json.bak。
;
;   定时参考业界标准：连按窗口 300ms（Android DOUBLE_TAP_TIMEOUT≈300ms，
;   Windows 双击 500ms / macOS 350ms），长按 500ms（Material/iOS 标准）。
;   连按窗口可调 50–1000ms；长按 100–2000ms。
;
;   命令行参数：/settings  启动时直接打开设置窗口
;   打包 exe：运行同目录 build.cmd（Ahk2Exe）。
;
;   语法规范（避开 AHK v2 解析边角）：
;     - 顶层变量使用 global 关键字逐行声明，再下一行赋值
;     - 反斜杠通过变量传递，避免在字面量字符串内
;     - JSON 字符串拼接基于字符级递归下降，无正则
; ============================================================================

APP_NAME    := "KeyMultiMap"
APP_VERSION := "0.0.1"
CONFIG_DIR  := A_AppData "\KeyMultiMap"
CONFIG_FILE := CONFIG_DIR "\config.json"

TAP_WINDOW_DEFAULT := 300
LONG_PRESS_DEFAULT := 500
TAP_WINDOW_MIN := 50
TAP_WINDOW_MAX := 1000
LONG_PRESS_MIN := 100
LONG_PRESS_MAX := 2000
MAX_TAPS := 5
ACTION_TYPES := ["无", "透传", "发送按键", "发送文本", "启动程序"]
TYPE_MAP := Map()
TYPE_MAP["无"] := "none"
TYPE_MAP["透传"] := "block"
TYPE_MAP["发送按键"] := "key"
TYPE_MAP["发送文本"] := "text"
TYPE_MAP["启动程序"] := "run"

; JSON 转义用的反斜杠常量（避免在字面量字符串内出现裸 \）
BS := Chr(92)

; 全局变量
global gSettings
global gMappings
global gEnabled
global gTapState
global gRegHotkeys
global gMainGui

gSettings := Map()
gSettings["trayHidden"]          := true
gSettings["autostart"]           := false
gSettings["startEnabled"]        := true
gSettings["showSettingsOnStart"] := false
gSettings["tapWindowMs"]         := TAP_WINDOW_DEFAULT
gSettings["longPressMs"]         := LONG_PRESS_DEFAULT
gSettings["pauseHotkey"]         := "^!k"
gSettings["feedbackBeep"]        := false

gMappings := []
gEnabled  := true
gTapState := Map()
gRegHotkeys := []
gMainGui := 0

; ============================================================================
; 启动
; ============================================================================
DirCreate(CONFIG_DIR)
LoadConfig()
gEnabled := gSettings["startEnabled"]
ApplyAutostart()
RebuildHotkeys()
BuildTray()

try {
    Hotkey(gSettings["pauseHotkey"], Func("ToggleEnabled"), "On")
} catch {
    gSettings["pauseHotkey"] := "^!k"
    try Hotkey("^!k", Func("ToggleEnabled"), "On")
}

; 自检测试：解析→序列化→再解析 深比较，结果写 _selftest.log 后退出
for a in A_Args {
    if InStr(a, "/selftest", false) > 0 {
        SelfTest()
        ExitApp()
    }
}

showStart := gSettings["showSettingsOnStart"]
for a in A_Args {
    if InStr(a, "/settings", false) > 0 {
        showStart := true
    }
}
; 无「有效」映射（启用且有触发键）时自动打开设置窗口，
; 避免「隐藏托盘 + 全是禁用/空映射」下程序看似无反应
hasActive := false
for m in gMappings {
    if m["enabled"] && m["trigger"] != "" {
        hasActive := true
        break
    }
}
if !hasActive {
    showStart := true
}
if showStart {
    ShowSettingsGui()
}
return

; ============================================================================
; 配置：读取 / 保存 / 迁移
; ============================================================================
LoadConfig() {
    global gSettings, gMappings
    if !FileExist(CONFIG_FILE) {
        SaveConfig()
        return
    }
    raw := ""
    try {
        raw := FileRead(CONFIG_FILE, "UTF-8")
    } catch {
        MsgBox("配置文件读取失败，已使用默认配置。`n原文件保留于：`n" CONFIG_FILE, APP_NAME, 48)
        return
    }
    data := 0
    try {
        data := Jxon_Load(raw)
    } catch {
        MsgBox("配置文件解析失败，已使用默认配置。`n原文件保留于：`n" CONFIG_FILE, APP_NAME, 48)
        return
    }
    if !(data is Map) {
        return
    }
    MigrateConfig(data)
    if (data.Get("settings", 0) is Map) {
        for k in gSettings.Clone() {
            if data["settings"].Has(k) {
                gSettings[k] := data["settings"][k]
            }
        }
    }
    gMappings := []
    if (data.Get("mappings", 0) is Array) {
        for m in data["mappings"] {
            gMappings.Push(NormalizeMapping(m))
        }
    }
}

; 版本迁移钩子：未来版本在此按 data["version"] 逐级升级，旧数据一律不删除
MigrateConfig(data) {
    if !data.Has("version") || !IsNumber(data["version"]) {
        data["version"] := 1
    }
}

NormalizeMapping(m) {
    n := Map()
    n["id"] := Guid()
    n["enabled"] := true
    n["trigger"] := ""
    n["actions"] := Map()
    if m is Map {
        if m.Has("id") && m["id"] != "" {
            n["id"] := String(m["id"])
        }
        if m.Has("enabled") {
            n["enabled"] := !!m["enabled"]
        }
        if m.Has("trigger") {
            n["trigger"] := String(m["trigger"])
        }
        if IsObject(m.Get("actions", 0)) {
            for k, v in m["actions"] {
                n["actions"][String(k)] := NormalizeAction(v)
            }
        }
    }
    return n
}

; 兼容 v0：纯字符串动作视为按键
NormalizeAction(a) {
    n := Map()
    n["type"] := "none"
    n["value"] := ""
    if IsObject(a) {
        if a.Has("type") {
            n["type"] := String(a["type"])
        }
        if a.Has("value") {
            n["value"] := String(a["value"])
        }
    } else if a != "" {
        n["type"] := "key"
        n["value"] := String(a)
    }
    return n
}

SaveConfig() {
    DirCreate(CONFIG_DIR)
    out := Map()
    out["version"] := 1
    out["app"] := APP_NAME
    out["settings"] := gSettings
    out["mappings"] := gMappings
    json := Jxon_Dump(out, "    ")
    tmp := CONFIG_FILE ".tmp"
    f := FileOpen(tmp, "w", "UTF-8")
    f.Write(json)
    f.Close()
    if FileExist(CONFIG_FILE) {
        FileCopy(CONFIG_FILE, CONFIG_FILE ".bak", 1)
    }
    FileMove(tmp, CONFIG_FILE, 1)
}

Guid() {
    return Format("{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}"
        , Random(0, 0x7fffffff), Random(0, 0xffff), Random(0, 0xfff)
        , 0x8000 | Random(0, 0x3fff), Random(0, 0x7fffffff))
}

; ============================================================================
; 引擎：热键注册与 触发 → 分派
; ============================================================================
RebuildHotkeys() {
    global gRegHotkeys, gMappings, gTapState
    for hk in gRegHotkeys {
        try Hotkey(hk, "Off")
    }
    gRegHotkeys := []
    if !gEnabled {
        return
    }
    for m in gMappings {
        if !m["enabled"] || m["trigger"] = "" {
            continue
        }
        key := m["trigger"]
        if !gTapState.Has(key) {
            gTapState[key] := MakeKeyState(key)
        }
        ups := "*" key " up"
        downs := "*" key
        try {
            ; 注意：被 Off 过的热键重新指定回调后仍保持禁用，必须带 "On" 选项
            Hotkey(downs, TriggerEvent, "On")
            gRegHotkeys.Push(downs)
        } catch {
        }
        try {
            Hotkey(ups, TriggerEvent, "On")
            gRegHotkeys.Push(ups)
        } catch {
        }
    }
}

; 每个触发键一份稳定状态；计时器绑定对象只创建一次
MakeKeyState(key) {
    st := Map()
    st["count"] := 0
    st["lpFired"] := false
    st["passDown"] := false
    st["disp"] := DispatchTap.Bind(key)
    st["lp"] := LongPressFire.Bind(key)
    return st
}

TriggerEvent(hotName, *) {
    isUp := RegExMatch(hotName, " up$") > 0
    rawKey := SubStr(hotName, 2)
    key := RegExReplace(rawKey, " up$")
    m := FindMapping(key)
    if !m {
        return
    }
    if !gTapState.Has(key) {
        return
    }
    st := gTapState[key]

    if !isUp {
        st["lpFired"] := false
        st["passDown"] := false
        SetTimer(st["disp"], 0)
        SetTimer(st["lp"], 0)
        SetTimer(st["lp"], -Integer(gSettings["longPressMs"]))
        return
    }
    SetTimer(st["lp"], 0)
    if st["lpFired"] {
        if st["passDown"] {
            Send("{Blind}{" key " up}")
        }
        st["count"] := 0
        return
    }
    count := st["count"] + 1
    st["count"] := count
    if HasHigherTap(m, count) {
        SetTimer(st["disp"], -Integer(gSettings["tapWindowMs"]))
    } else {
        fn := st["disp"]
        fn()
    }
}

DispatchTap(key) {
    if !gTapState.Has(key) {
        return
    }
    st := gTapState[key]
    SetTimer(st["disp"], 0)
    count := st["count"]
    st["count"] := 0
    m := FindMapping(key)
    if !m {
        return
    }
    act := 0
    sk := String(count)
    if m["actions"].Has(sk) {
        act := m["actions"][sk]
    }
    if ActionActive(act) {
        ExecuteAction(act)
    } else {
        Send("{Blind}{" key "}")
    }
}

LongPressFire(key) {
    if !gTapState.Has(key) {
        return
    }
    st := gTapState[key]
    m := FindMapping(key)
    if !m {
        return
    }
    st["lpFired"] := true
    st["count"] := 0
    SetTimer(st["disp"], 0)
    act := 0
    if m["actions"].Has("long") {
        act := m["actions"]["long"]
    }
    if ActionActive(act) {
        if act["type"] != "block" && gSettings["feedbackBeep"] {
            SoundBeep(1200, 40)
        }
        ExecuteAction(act)
    } else {
        st["passDown"] := true
        Send("{Blind}{" key " down}")
    }
}

FindMapping(key) {
    for m in gMappings {
        if m["enabled"] && m["trigger"] = key {
            return m
        }
    }
    return 0
}

; 是否存在比 count 更高的已配置连按级（用于决定是否等待下一次连按）
; 旧实现只检查 count+1，导致「配置了单击+3连但未配置双击」时 3 连永远无法触发
HasHigherTap(m, count) {
    lvl := count + 1
    while lvl <= MAX_TAPS {
        sk := String(lvl)
        if m["actions"].Has(sk) && ActionActive(m["actions"][sk]) {
            return true
        }
        lvl := lvl + 1
    }
    return false
}

ActionActive(a) {
    if !IsObject(a) {
        return false
    }
    t := a["type"]
    if t = "none" {
        return false
    }
    if t = "block" {
        return true
    }
    return a["value"] != ""
}

ExecuteAction(act) {
    switch act["type"] {
        case "key":  Send("{Blind}" act["value"])
        case "text": SendText(act["value"])
        case "run":  try Run(act["value"])
        case "block": ; 屏蔽按键：吞掉，无反应
    }
}

ToggleEnabled(ThisHotkey := "") {
    global gEnabled
    gEnabled := !gEnabled
    RebuildHotkeys()
    UpdateTrayChecks()
    RefreshList()
    msg := gEnabled ? "映射已恢复" : "映射已暂停（暂停热键：" gSettings["pauseHotkey"] "）"
    TrayTip(msg, APP_NAME)
}

; ============================================================================
; 托盘菜单（开关项带勾选状态）
; ============================================================================
BuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add(APP_NAME " v" APP_VERSION, (*) => 0)
    A_TrayMenu.Disable(APP_NAME " v" APP_VERSION)
    A_TrayMenu.Add()
    A_TrayMenu.Add("设置…", (*) => ShowSettingsGui())
    A_TrayMenu.Add("映射已启用", (*) => ToggleEnabled())
    A_TrayMenu.Add()
    A_TrayMenu.Add("显示托盘图标", (*) => TrayToggleTrayIcon())
    A_TrayMenu.Add("开机自动启动", (*) => TrayToggleAutostart())
    A_TrayMenu.Add()
    A_TrayMenu.Add("重载配置", (*) => (
        LoadConfig(), RebuildHotkeys(), RefreshList(), UpdateTrayChecks(),
        TrayTip("配置已重载", APP_NAME)))
    A_TrayMenu.Add("打开配置文件夹", (*) => Run('explorer.exe "' CONFIG_DIR '"'))
    A_TrayMenu.Add("导出配置…", ExportConfig)
    A_TrayMenu.Add("导入配置…", (*) => ImportConfig(false))
    A_TrayMenu.Add()
    A_TrayMenu.Add("重启脚本", (*) => Reload())
    A_TrayMenu.Add("退出", (*) => ExitApp())
    A_TrayMenu.Default := "设置…"
    try TraySetIcon("shell32.dll", 44)
    A_IconHidden := gSettings["trayHidden"]
    UpdateTrayChecks()
}

UpdateTrayChecks() {
    if gEnabled {
        A_TrayMenu.Check("映射已启用")
    } else {
        A_TrayMenu.Uncheck("映射已启用")
    }
    if !gSettings["trayHidden"] {
        A_TrayMenu.Check("显示托盘图标")
    } else {
        A_TrayMenu.Uncheck("显示托盘图标")
    }
    if gSettings["autostart"] {
        A_TrayMenu.Check("开机自动启动")
    } else {
        A_TrayMenu.Uncheck("开机自动启动")
    }
}

TrayToggleTrayIcon(*) {
    global
    gSettings["trayHidden"] := !gSettings["trayHidden"]
    A_IconHidden := gSettings["trayHidden"]
    SaveConfig()
    UpdateTrayChecks()
    if IsObject(gMainGui) {
        gMainGui["ChkTray"].Value := !gSettings["trayHidden"]
    }
}

TrayToggleAutostart(*) {
    global
    gSettings["autostart"] := !gSettings["autostart"]
    ApplyAutostart()
    SaveConfig()
    UpdateTrayChecks()
    if IsObject(gMainGui) {
        gMainGui["ChkAuto"].Value := gSettings["autostart"]
    }
}

; ============================================================================
; 设置界面（标签页）
; ============================================================================
ShowSettingsGui() {
    global gMainGui
    if IsObject(gMainGui) {
        gMainGui.Show()
        return
    }
    g := Gui("+Resize", APP_NAME " 设置")
    gMainGui := g
    g.MarginX := 14
    g.MarginY := 14
    g.OnEvent("Close", GuiMainClose)
    g.OnEvent("Size", GuiOnResize)

    tab := g.Add("Tab3", "w560 h500", ["按键映射", "定时参数", "常规", "备份与导入导出", "关于"])

    ; ---------- Tab 1 按键映射 ----------
    tab.UseTab(1)
    lv := g.Add("ListView", "w540 h310 vLV Grid"
        , ["启用", "触发键", "单击", "双击", "3连", "4连", "5连", "长按"])
    lv.OnEvent("DoubleClick", (*) => EditSelectedMapping())
    g.Add("Text", "y+6 cGray", "未配置的层级 = 透传原始按键；双击列表行可编辑。")
    g.Add("Button", "y+10 w78 Section", "新建").OnEvent("Click", NewMapping)
    g.Add("Button", "x+8 wp", "编辑").OnEvent("Click", (*) => EditSelectedMapping())
    g.Add("Button", "x+8 wp", "删除").OnEvent("Click", DeleteMapping)
    g.Add("Button", "x+8 wp", "启用/停用").OnEvent("Click", ToggleMappingEnabled)
    g.Add("Button", "xs y+8 w78", "上移").OnEvent("Click", (*) => MoveMapping(-1))
    g.Add("Button", "x+8 wp", "下移").OnEvent("Click", (*) => MoveMapping(1))
    g.Add("Button", "x+8 w110", "应用更改").OnEvent("Click", (*) => CommitChanges())
    g.Add("CheckBox", "x+16 yp+3 vChkGlobal", "映射总开关").OnEvent("Click", ChkGlobalToggle)

    ; ---------- Tab 2 定时参数 ----------
    tab.UseTab(2)
    g.Add("GroupBox", "w540 h230 Section", "计时参数")
    g.Add("Text", "xs+16 yp+32", "连按判定窗口（两次按键之间的最大间隔）")
    g.Add("Text", "xs+16 y+8 w70 vLblTap", gSettings["tapWindowMs"] " ms")
    g.Add("Slider", "x+8 yp-6 w400 Range50-1000 ToolTip vSlTap", gSettings["tapWindowMs"]).OnEvent("Change", SlTapChanged)
    g.Add("Text", "xs+16 y+20", "长按阈值（按住多久判定为长按）")
    g.Add("Text", "xs+16 y+8 w70 vLblLp", gSettings["longPressMs"] " ms")
    g.Add("Slider", "x+8 yp-6 w400 Range100-2000 ToolTip vSlLp", gSettings["longPressMs"]).OnEvent("Change", SlLpChanged)
    g.Add("Text", "xs+16 y+20 cGray", "业界参考：Android/iOS 双击窗口 ≈300ms；长按 500ms（Material Design）。")
    g.Add("Text", "xs+16 y+4 cGray", "窗口越短连按响应越快但更易误判；配置了双击的键，单击会延迟一个窗口期。")
    g.Add("Button", "xs+16 y+14 w150", "恢复默认 (300/500)").OnEvent("Click", (*) => (
        gMainGui["SlTap"].Value := TAP_WINDOW_DEFAULT,
        gMainGui["SlLp"].Value := LONG_PRESS_DEFAULT,
        SlTapChanged(0, 0),
        SlLpChanged(0, 0)))

    ; ---------- Tab 3 常规 ----------
    tab.UseTab(3)
    g.Add("GroupBox", "w540 h280 Section", "常规")
    g.Add("CheckBox", "xs+16 yp+34 vChkTray", "显示系统托盘图标").OnEvent("Click", ChkTrayClicked)
    g["ChkTray"].Value := !gSettings["trayHidden"]
    g.Add("CheckBox", "xs+16 y+16 vChkAuto", "开机自动启动").OnEvent("Click", ChkAutoClicked)
    g["ChkAuto"].Value := gSettings["autostart"]
    g.Add("CheckBox", "xs+16 y+16 vChkStart", "启动时映射立即生效").OnEvent("Click", ChkStartClicked)
    g["ChkStart"].Value := gSettings["startEnabled"]
    g.Add("CheckBox", "xs+16 y+16 vChkBeep", "识别到长按时播放提示音").OnEvent("Click", ChkBeepClicked)
    g["ChkBeep"].Value := gSettings["feedbackBeep"]
    g.Add("CheckBox", "xs+16 y+16 vChkShow", "下次启动时打开设置窗口").OnEvent("Click", ChkShowClicked)
    g["ChkShow"].Value := gSettings["showSettingsOnStart"]
    g.Add("Text", "xs+16 y+22", "全局暂停/恢复热键：")
    g.Add("Edit", "x+8 yp-3 w130 vEdPause", gSettings["pauseHotkey"])
    g.Add("Button", "x+8 yp w70", "应用").OnEvent("Click", GuiApplyPauseHotkey)

    ; ---------- Tab 4 备份与导入导出 ----------
    tab.UseTab(4)
    g.Add("GroupBox", "w540 h270 Section", "配置文件")
    g.Add("Text", "xs+16 yp+32 w510", "配置位置：" CONFIG_FILE)
    g.Add("Text", "xs+16 y+6 w510 cGray", "导入默认为『合并』：按映射 id 合并 —— 同名替换、新增追加、")
    g.Add("Text", "xs+16 y+4 w510 cGray", "本机已有而文件中没有的映射全部保留，绝不损失用户数据。")
    g.Add("Button", "xs+16 y+18 w165 Section", "导出配置…").OnEvent("Click", ExportConfig)
    g.Add("Button", "x+12 wp", "导入配置（合并）…").OnEvent("Click", (*) => ImportConfig(false))
    g.Add("Button", "x+12 wp", "导入配置（整包替换）…").OnEvent("Click", (*) => ImportConfig(true))
    g.Add("Text", "xs+16 y+22 w510", "每次保存前自动备份到 config.json.bak；导出前会先保存当前配置。")
    g.Add("Button", "xs+16 y+10 w165", "打开配置文件夹").OnEvent("Click", (*) => Run('explorer.exe "' CONFIG_DIR '"'))
    g.Add("Button", "x+12 wp", "从备份恢复").OnEvent("Click", GuiRestoreBackup)
    g.Add("Button", "x+12 wp cRed", "恢复出厂设置").OnEvent("Click", ResetFactory)

    ; ---------- Tab 5 关于 ----------
    tab.UseTab(5)
    g.Add("Text", "Section", APP_NAME " v" APP_VERSION)
    g.Add("Text", "y+8 w510", "键盘按键多重映射工具：单击 / 双击 / 连按 / 长按，逐级自定义动作。")
    g.Add("Text", "y+8 w510 cGray", "基于 AutoHotkey v2；配置为版本化 JSON，支持导入导出与自动备份。")
    g.Add("Link", "y+8 w510", 'GitHub 仓库：<a href="https://github.com/SantaChains/keyshadow">SantaChains/keyshadow</a>')
    g.Add("Text", "y+16 w510", "作者：SantaChains")
    g.Add("Text", "y+4 w510", "版本：v" APP_VERSION)
    g.Add("Text", "y+16 w510 cGray", "提示：触发键建议使用低频键（如 CapsLock、ScrollLock、F13–F24），")
    g.Add("Text", "y+4 w510 cGray", "避免与输入法、游戏或其它增强工具冲突。")

    tab.Value := 1
    RefreshList()
    g.Show()
}

GuiMainClose(*) {
    global gMainGui
    gMainGui := 0
}

GuiOnResize(g, minMax, w, h) {
    if minMax != 0 {
        return
    }
    try g["LV"].Move(, , w - 70, h - 240)
}

RefreshList() {
    global gMainGui
    if !IsObject(gMainGui) {
        return
    }
    lv := gMainGui["LV"]
    lv.Delete()
    for m in gMappings {
        en := m["enabled"] ? "✓" : "—"
        trig := m["trigger"]
        c1 := ActCell(m, "1")
        c2 := ActCell(m, "2")
        c3 := ActCell(m, "3")
        c4 := ActCell(m, "4")
        c5 := ActCell(m, "5")
        cl := ActCell(m, "long")
        lv.Add("", en, trig, c1, c2, c3, c4, c5, cl)
    }
    lv.ModifyCol(1, 40)
    lv.ModifyCol(2, 95)
    gMainGui["ChkGlobal"].Value := gEnabled
}

ActCell(m, k) {
    if !m["actions"].Has(k) {
        return "—"
    }
    a := m["actions"][k]
    if !ActionActive(a) {
        return "—"
    }
    prefix := ""
    if a["type"] = "key" {
        prefix := "⌨ "
    } else if a["type"] = "text" {
        prefix := "T "
    } else if a["type"] = "run" {
        prefix := "▶ "
    }
    return prefix a["value"]
}

SelMapping() {
    row := gMainGui["LV"].GetNext()
    if !row {
        return 0
    }
    return gMappings[row]
}

CommitChanges() {
    SaveConfig()
    RebuildHotkeys()
    RefreshList()
    UpdateTrayChecks()
    TrayTip("配置已应用", APP_NAME)
}

NewMapping(*) {
    m := Map()
    m["id"] := Guid()
    m["enabled"] := true
    m["trigger"] := ""
    m["actions"] := Map()
    EditMappingDialog(m, "新建映射")
}

EditSelectedMapping() {
    m := SelMapping()
    if IsObject(m) {
        EditMappingDialog(m, "编辑映射")
    }
}

DeleteMapping(*) {
    global gMappings
    m := SelMapping()
    if !IsObject(m) {
        return
    }
    if MsgBox("删除触发键 [" m["trigger"] "] 的映射？", APP_NAME, "Icon? YesNo") != "Yes" {
        return
    }
    i := 1
    for x in gMappings {
        if x["id"] = m["id"] {
            break
        }
        i++
    }
    gMappings.RemoveAt(i)
    CommitChanges()
}

MoveMapping(dir) {
    global gMappings
    m := SelMapping()
    if !IsObject(m) {
        return
    }
    i := 1
    for x in gMappings {
        if x["id"] = m["id"] {
            break
        }
        i++
    }
    j := i + dir
    if j < 1 || j > gMappings.Length {
        return
    }
    tmp := gMappings[i]
    gMappings[i] := gMappings[j]
    gMappings[j] := tmp
    SaveConfig()
    RefreshList()
    gMainGui["LV"].Modify(j, "Select Vis")
}

ToggleMappingEnabled(*) {
    m := SelMapping()
    if IsObject(m) {
        m["enabled"] := !m["enabled"]
        CommitChanges()
    }
}

ChkGlobalToggle(*) {
    global gEnabled
    gEnabled := gMainGui["ChkGlobal"].Value
    RebuildHotkeys()
    UpdateTrayChecks()
}

; ---------- 映射编辑对话框 ----------
EditMappingDialog(m, title) {
    owner := IsObject(gMainGui) ? gMainGui.Hwnd : 0
    if owner {
        g := Gui("+Owner" owner, title)
    } else {
        g := Gui(, title)
    }
    g.MarginX := 14
    g.MarginY := 14
    g.Add("Text", "", "触发键（如 CapsLock / ScrollLock / F13 / NumpadIns）")
    g.Add("Edit", "w180 vEdKey", m["trigger"])
    btnKey := g.Add("Button", "x+8 yp-2 w60", "录制")
    btnKey.OnEvent("Click", (*) => RecordTriggerKey(g, btnKey))
    g.Add("Text", "xs y+6 cGray", "点击「录制」后按任意键自动填入（含 Esc/Enter 等特殊键；按键被抑制，不会误触发）")

    g.Add("GroupBox", "w530 h300 y+14 Section", "动作映射（留空或选『无』= 该层级透传原始按键）")
    labels := ["单击", "双击", "3 连按", "4 连按", "5 连按", "长按"]
    keys   := ["1", "2", "3", "4", "5", "long"]
    AddActionRow(g, m, keys[1], labels[1], "yp+30")
    AddActionRow(g, m, keys[2], labels[2], "y+14")
    AddActionRow(g, m, keys[3], labels[3], "y+14")
    AddActionRow(g, m, keys[4], labels[4], "y+14")
    AddActionRow(g, m, keys[5], labels[5], "y+14")
    AddActionRow(g, m, keys[6], labels[6], "y+14")

    g.Add("Button", "xm y+18 w90 Default", "保存").OnEvent("Click", (*) => SaveMappingEdit(g, m))
    g.Add("Button", "x+12 yp wp", "取消").OnEvent("Click", (*) => g.Destroy())
    g.Show()
}

; 按键自动录入：点「录制」后捕获下一个按键（InputHook 抑制，Esc 取消）
RecordTriggerKey(g, btn) {
    orig := btn.Text
    btn.Text := "按键中…"
    btn.Enabled := false
    g["EdKey"].Enabled := false
    ih := InputHook("L1 S")
    ih.Start()
    ih.Wait()
    key := ih.EndKey
    btn.Enabled := true
    btn.Text := orig
    g["EdKey"].Enabled := true
    if key != "" {
        g["EdKey"].Value := key
    }
}

; 独立函数确保每行控件变量名不重复，避免循环变量捕获陷阱
AddActionRow(g, m, k, label, yPos) {
    g.Add("Text", yPos " Section w52", label "：")
    ddl := g.Add("DDL", "x+4 yp-4 w110 Choose1 vDdl" k, ACTION_TYPES)
    val := g.Add("Edit", "x+6 yp w290 Disabled vVal" k)
    ddl.OnEvent("Change", (c, *) => (
        g["Val" k].Enabled := (c.Text != "无（透传）")))
    if m["actions"].Has(k) && ActionActive(m["actions"][k]) {
        a := m["actions"][k]
        i := 0
        for t in ACTION_TYPES {
            i++
            if TYPE_MAP[t] = a["type"] {
                ddl.Value := i
                break
            }
        }
        val.Value := a["value"]
        val.Enabled := true
    }
}

SaveMappingEdit(g, m) {
    global gMappings
    newTrigger := Trim(g["EdKey"].Text)
    m["trigger"] := newTrigger
    keysArr := ["1", "2", "3", "4", "5", "long"]
    for k in keysArr {
        selText := g["Ddl" k].Text
        t := TYPE_MAP[selText]
        v := Trim(g["Val" k].Text)
        if m["actions"].Has(k) {
            m["actions"].Delete(k)
        }
        if t != "none" && v != "" {
            entry := Map()
            entry["type"] := t
            entry["value"] := v
            m["actions"][k] := entry
        }
    }
    ; 新建映射：编辑前尚未加入列表，此处按 id 追加（编辑已有映射则原地保留）
    exists := false
    for x in gMappings {
        if x["id"] = m["id"] {
            exists := true
            break
        }
    }
    if !exists {
        gMappings.Push(m)
    }
    if m["trigger"] = "" {
        MsgBox("触发键为空，此映射不会生效。", APP_NAME, 48)
    }
    g.Destroy()
    CommitChanges()
}

; ---------- 定时参数 ----------
SlTapChanged(*) {
    global gMainGui
    gSettings["tapWindowMs"] := gMainGui["SlTap"].Value
    gMainGui["LblTap"].Text := gSettings["tapWindowMs"] " ms"
    SaveConfig()
}

SlLpChanged(*) {
    global gMainGui
    gSettings["longPressMs"] := gMainGui["SlLp"].Value
    gMainGui["LblLp"].Text := gSettings["longPressMs"] " ms"
    SaveConfig()
}

; ---------- 常规 ----------
ChkTrayClicked(*) {
    global gMainGui
    gSettings["trayHidden"] := !gMainGui["ChkTray"].Value
    A_IconHidden := gSettings["trayHidden"]
    SaveConfig()
    UpdateTrayChecks()
}

ChkAutoClicked(*) {
    global gMainGui
    gSettings["autostart"] := gMainGui["ChkAuto"].Value
    ApplyAutostart()
    SaveConfig()
    UpdateTrayChecks()
}

ChkStartClicked(*) {
    global gMainGui
    gSettings["startEnabled"] := gMainGui["ChkStart"].Value
    SaveConfig()
}

ChkBeepClicked(*) {
    global gMainGui
    gSettings["feedbackBeep"] := gMainGui["ChkBeep"].Value
    SaveConfig()
}

ChkShowClicked(*) {
    global gMainGui
    gSettings["showSettingsOnStart"] := gMainGui["ChkShow"].Value
    SaveConfig()
}

GuiApplyPauseHotkey(*) {
    global gMainGui
    hk := Trim(gMainGui["EdPause"].Text)
    try Hotkey(gSettings["pauseHotkey"], "Off")
    try {
        Hotkey(hk, Func("ToggleEnabled"), "On")
        gSettings["pauseHotkey"] := hk
        SaveConfig()
        TrayTip("暂停热键已设为 " hk, APP_NAME)
    } catch as e {
        MsgBox("热键无效：" e.Message, APP_NAME, 48)
        try Hotkey(gSettings["pauseHotkey"], Func("ToggleEnabled"), "On")
    }
}

; 自启动命令：编译后指向 exe；脚本状态则用解释器 + 脚本路径
AutostartCommand() {
    if A_IsCompiled {
        return '"' A_ScriptFullPath '"'
    }
    return '"' A_AhkPath '" "' A_ScriptFullPath '"'
}

ApplyAutostart() {
    runKey := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
    if gSettings["autostart"] {
        RegWrite(AutostartCommand(), "REG_SZ", runKey, APP_NAME)
    } else {
        try RegDelete(runKey, APP_NAME)
    }
}

; ============================================================================
; 导入 / 导出
; ============================================================================
ExportConfig(*) {
    SaveConfig()
    f := FileSelect("S16", A_Desktop "\keymultimap-config.json", "导出配置", "JSON (*.json)")
    if f {
        FileCopy(CONFIG_FILE, f, 1)
    }
}

ImportConfig(replace) {
    global gSettings, gMappings
    f := FileSelect(1, , "导入配置", "JSON (*.json)")
    if !f {
        return
    }
    raw := ""
    try {
        raw := FileRead(f, "UTF-8")
    } catch {
        MsgBox("文件读取失败。", APP_NAME, 16)
        return
    }
    data := 0
    try {
        data := Jxon_Load(raw)
    } catch {
        MsgBox("不是有效的配置文件。", APP_NAME, 16)
        return
    }
    if !(data is Map) {
        MsgBox("不是有效的配置文件。", APP_NAME, 16)
        return
    }
    MigrateConfig(data)
    SaveConfig()   ; 导入前快照当前配置
    if replace {
        if MsgBox("整包替换将覆盖当前全部映射（已自动备份）。继续？", APP_NAME, "Icon! YesNo") != "Yes" {
            return
        }
        gMappings := []
        if (data.Get("mappings", 0) is Array) {
            for m in data["mappings"] {
                gMappings.Push(NormalizeMapping(m))
            }
        }
        if (data.Get("settings", 0) is Map) {
            for k in gSettings.Clone() {
                if data["settings"].Has(k) {
                    gSettings[k] := data["settings"][k]
                }
            }
        }
    } else {
        ; 合并：按 id 同名替换、新 id 追加，本机独有保留
        if (data.Get("mappings", 0) is Array) {
            for m in data["mappings"] {
                nm := NormalizeMapping(m)
                found := false
                idx := 0
                for i, mine in gMappings {
                    if mine["id"] = nm["id"] {
                        idx := i
                        found := true
                        break
                    }
                }
                if found {
                    gMappings[idx] := nm
                } else {
                    gMappings.Push(nm)
                }
            }
        }
    }
    ApplyAutostart()
    CommitChanges()
    MsgBox("导入完成，共 " gMappings.Length " 条映射。", APP_NAME, 64)
}

GuiRestoreBackup(*) {
    if !FileExist(CONFIG_FILE ".bak") {
        MsgBox("没有找到备份文件。", APP_NAME, 48)
        return
    }
    if MsgBox("用上一次保存的备份覆盖当前配置？", APP_NAME, "Icon? YesNo") != "Yes" {
        return
    }
    FileCopy(CONFIG_FILE ".bak", CONFIG_FILE, 1)
    LoadConfig()
    ApplyAutostart()
    RebuildHotkeys()
    RefreshList()
    UpdateTrayChecks()
    MsgBox("已从备份恢复。", APP_NAME, 64)
}

ResetFactory(*) {
    global gSettings, gMappings, gMainGui
    if MsgBox("将恢复默认设置并清空全部映射（当前配置已自动备份）。继续？", APP_NAME, "Icon! YesNo") != "Yes" {
        return
    }
    SaveConfig()
    gSettings := Map()
    gSettings["trayHidden"]          := true
    gSettings["autostart"]           := false
    gSettings["startEnabled"]        := true
    gSettings["showSettingsOnStart"] := false
    gSettings["tapWindowMs"]         := TAP_WINDOW_DEFAULT
    gSettings["longPressMs"]         := LONG_PRESS_DEFAULT
    gSettings["pauseHotkey"]         := "^!k"
    gSettings["feedbackBeep"]        := false
    gMappings := []
    SaveConfig()
    ApplyAutostart()
    A_IconHidden := true
    if IsObject(gMainGui) {
        gMainGui.Destroy()
    }
    gMainGui := 0
    RebuildHotkeys()
    ShowSettingsGui()
    UpdateTrayChecks()
}

; ============================================================================
; 自检测试：验证 config.json 解析→序列化→再解析 往返一致
; ============================================================================
SelfTest() {
    global
    DirCreate(CONFIG_DIR)
    if !FileExist(CONFIG_FILE) {
        SaveConfig()
    }
    raw := FileRead(CONFIG_FILE, "UTF-8")
    data1 := 0
    try {
        data1 := Jxon_Load(raw)
    } catch {
        result := "SELFTEST FAIL`nparse error: 配置文件不是有效 JSON`n"
        FileAppend(result, CONFIG_DIR "\_selftest.log", "UTF-8")
        return
    }
    json2 := Jxon_Dump(data1, "    ")
    data2 := Jxon_Load(json2)
    ok := DeepEqual(data1, data2)
    mapCount := IsObject(data1) && data1.Has("mappings") ? data1["mappings"].Length : 0
    result := "SELFTEST " (ok ? "PASS" : "FAIL") "`n"
    result .= "file bytes : " StrLen(raw) "`n"
    result .= "reparse    : " (ok ? "equal" : "MISMATCH") "`n"
    result .= "mappings   : " mapCount "`n"
    try {
        FileDelete(CONFIG_DIR "\_selftest.log")
    }
    FileAppend(result, CONFIG_DIR "\_selftest.log", "UTF-8")
}

DeepEqual(a, b) {
    if IsObject(a) && IsObject(b) {
        if (a is Array) && (b is Array) {
            if a.Length != b.Length {
                return false
            }
            i := 1
            for v in a {
                if !DeepEqual(v, b[i]) {
                    return false
                }
                i := i + 1
            }
            return true
        }
        if (a is Map) && (b is Map) {
            if a.Count != b.Count {
                return false
            }
            for k, v in a {
                if !b.Has(k) || !DeepEqual(v, b[k]) {
                    return false
                }
            }
            return true
        }
        return false
    }
    return a = b
}

; ============================================================================
; JSON — 字符级递归下降解析/序列化（不依赖正则，规避 AHK 字符串引号转义问题）
;   解析结果：对象 → Map，数组 → Array，null → ""，数字 → Integer/Float
;   反斜杠通过 BS 常量传递，避免在字面量字符串内连续出现 \
; ============================================================================
JxIsDigit(c) {
    if c = "" {
        return false
    }
    cc := Ord(c)
    return cc >= 48 && cc <= 57
}
JxIsNumChar(c) {
    if c = "" {
        return false
    }
    if JxIsDigit(c) {
        return true
    }
    return c = "-" || c = "+" || c = "." || c = "e" || c = "E"
}

Jxon_Load(s) {
    pos := Map("p", 0)
    return JxValue(s, pos)
}

JxSkipWs(s, pos) {
    n := StrLen(s)
    loop {
        if pos["p"] >= n {
            return
        }
        c := SubStr(s, pos["p"] + 1, 1)
        if c = " " || c = "`t" || c = "`r" || c = "`n" {
            pos["p"] := pos["p"] + 1
        } else {
            return
        }
    }
}

JxValue(s, pos) {
    JxSkipWs(s, pos)
    c := SubStr(s, pos["p"] + 1, 1)
    if c = "{" {
        return JxObject(s, pos)
    }
    if c = "[" {
        return JxArray(s, pos)
    }
    if c = '"' {
        return JxString(s, pos)
    }
    if SubStr(s, pos["p"] + 1, 4) = "true" {
        pos["p"] := pos["p"] + 4
        return true
    }
    if SubStr(s, pos["p"] + 1, 5) = "false" {
        pos["p"] := pos["p"] + 5
        return false
    }
    if SubStr(s, pos["p"] + 1, 4) = "null" {
        pos["p"] := pos["p"] + 4
        return ""
    }
    if c = "-" || JxIsDigit(c) {
        return JxNumber(s, pos)
    }
    throw Error("JSON 解析失败：位置 " pos["p"] + 1 " 字符无效")
}

JxNumber(s, pos) {
    start := pos["p"] + 1
    n := StrLen(s)
    while pos["p"] < n {
        c := SubStr(s, pos["p"] + 1, 1)
        if JxIsNumChar(c) {
            pos["p"] := pos["p"] + 1
        } else {
            break
        }
    }
    t := SubStr(s, start, pos["p"] - start + 1)
    if InStr(t, ".") || InStr(t, "e") || InStr(t, "E") {
        return Float(t)
    }
    return Integer(t)
}

JxString(s, pos) {
    pos["p"] := pos["p"] + 1            ; 跳过开引号
    n := StrLen(s)
    out := ""
    while pos["p"] < n {
        c := SubStr(s, pos["p"] + 1, 1)
        pos["p"] := pos["p"] + 1
        if c = '"' {                    ; 闭引号
            return out
        }
        if c = BS {
            e := SubStr(s, pos["p"] + 1, 1)
            pos["p"] := pos["p"] + 1
            if e = '"' {
                out := out . '"'
            } else if e = BS {
                out := out . BS
            } else if e = "/" {
                out := out . "/"
            } else if e = "b" {
                out := out . Chr(8)
            } else if e = "f" {
                out := out . Chr(12)
            } else if e = "n" {
                out := out . "`n"
            } else if e = "r" {
                out := out . "`r"
            } else if e = "t" {
                out := out . "`t"
            } else if e = "u" {
                cp := Integer("0x" SubStr(s, pos["p"] + 1, 4))
                pos["p"] := pos["p"] + 4
                if cp >= 0xD800 && cp <= 0xDBFF {   ; UTF-16 代理对
                    if SubStr(s, pos["p"] + 1, 2) = BS "u" {
                        lo := Integer("0x" SubStr(s, pos["p"] + 3, 4))
                        pos["p"] := pos["p"] + 6
                        cp := 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    }
                }
                out := out . Chr(cp)
            } else {
                throw Error("JSON 解析失败：无效转义序列")
            }
        } else {
            out := out . c
        }
    }
    throw Error("JSON 解析失败：字符串未闭合")
}

JxObject(s, pos) {
    pos["p"] := pos["p"] + 1            ; 跳过 {
    obj := Map()
    JxSkipWs(s, pos)
    if SubStr(s, pos["p"] + 1, 1) = "}" {
        pos["p"] := pos["p"] + 1
        return obj
    }
    loop {
        JxSkipWs(s, pos)
        k := JxString(s, pos)
        JxSkipWs(s, pos)
        if SubStr(s, pos["p"] + 1, 1) != ":" {
            throw Error("JSON 解析失败：对象缺少冒号")
        }
        pos["p"] := pos["p"] + 1
        val := JxValue(s, pos)
        obj[k] := val
        JxSkipWs(s, pos)
        c := SubStr(s, pos["p"] + 1, 1)
        if c = "," {
            pos["p"] := pos["p"] + 1
            continue
        }
        if c = "}" {
            pos["p"] := pos["p"] + 1
            return obj
        }
        throw Error("JSON 解析失败：对象格式错误")
    }
}

JxArray(s, pos) {
    pos["p"] := pos["p"] + 1            ; 跳过 [
    arr := []
    JxSkipWs(s, pos)
    if SubStr(s, pos["p"] + 1, 1) = "]" {
        pos["p"] := pos["p"] + 1
        return arr
    }
    loop {
        arr.Push(JxValue(s, pos))
        JxSkipWs(s, pos)
        c := SubStr(s, pos["p"] + 1, 1)
        if c = "," {
            pos["p"] := pos["p"] + 1
            continue
        }
        if c = "]" {
            pos["p"] := pos["p"] + 1
            return arr
        }
        throw Error("JSON 解析失败：数组格式错误")
    }
}

Jxon_Dump(obj, indent := "", lvl := 1) {
    if IsObject(obj) {
        if obj is Array {
            buf := ""
            for v in obj {
                sep := buf = "" ? "" : ","
                nl := indent = "" ? "" : "`n" JxInd(indent, lvl + 1)
                buf := buf . sep . nl . Jxon_Dump(v, indent, lvl + 1)
            }
            op := indent = "" ? "" : "`n" JxInd(indent, lvl)
            return "[" buf op "]"
        }
        buf := ""
        for k, v in obj {
            sep := buf = "" ? "" : ","
            nl := indent = "" ? "" : "`n" JxInd(indent, lvl + 1)
            buf := buf . sep . nl . JxDumpStr(k) . (indent = "" ? ":" : ": ") . Jxon_Dump(v, indent, lvl + 1)
        }
        op := indent = "" ? "" : "`n" JxInd(indent, lvl)
        return "{" buf op "}"
    }
    if IsNumber(obj) {
        return String(obj)
    }
    if obj = true {
        return "true"
    }
    if obj = false {
        return "false"
    }
    return JxDumpStr(obj)
}

JxDumpStr(v) {
    s := String(v)
    ; 分四个独立的替换步骤，避免反斜杠字面量连续
    s := StrReplace(s, BS, BS BS)
    dq := '"'
    s := StrReplace(s, dq, BS . dq)
    s := StrReplace(s, "`n", BS . "n")
    s := StrReplace(s, "`r", BS . "r")
    s := StrReplace(s, "`t", BS . "t")
    s := StrReplace(s, Chr(8), BS . "b")
    s := StrReplace(s, Chr(12), BS . "f")
    return '"' s '"'
}

JxInd(indent, lvl) {
    out := ""
    loop lvl {
        out := out . indent
    }
    return out
}
