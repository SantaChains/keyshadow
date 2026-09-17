#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
;  连按两下【左 Ctrl】 →  发送一次 Enter
;  · 只在“单独轻点”Ctrl 时触发
;  · Ctrl+C / Ctrl+V 等组合键、以及长按 Ctrl 都不会误触
;  · 需要 AutoHotkey v2（autohotkey.com 免费下载）
; ============================================================

; ---------- 可调参数 ----------
DOUBLE_TAP_MS := 400        ; 判定为“双击”的两次轻点最大间隔（毫秒），越小越不易误触
TAP_MAX_MS    := 500        ; 单次轻点允许按住的最长时间（毫秒），超过视为长按修饰键
OUT_KEY       := "{Enter}"  ; 双击后要发送的按键（可改成 "{Esc}"、"{Tab}"、"a" 等）

; 鼠标悬停托盘图标时显示的提示
A_TrayMenu.Tip := "双击左 Ctrl → Enter（右键托盘图标可退出）"

; ---------- 主逻辑 ----------
~LCtrl:: {
    static lastTap := 0

    ; 监听 Ctrl 按住期间是否按下了“其它键”
    ih := InputHook("V")            ; V = 不拦截按键，正常输入不受影响
    ih.KeyOpt("{All}", "E")         ; 任意键按下即结束监听，并记录到 EndKey
    ih.KeyOpt("{LCtrl}", "I")       ; 但 Ctrl 自身被忽略（松开它不算“其它键”）
    ih.Start()

    ; 等待 Ctrl 松开；超过 TAP_MAX_MS 则视为长按（当修饰键用）
    quickRelease := KeyWait("LCtrl", "T" (TAP_MAX_MS / 1000))
    ih.Stop()

    ; “单独轻点” = 快速松开 且 期间没有按其它键
    if (quickRelease && ih.EndKey = "") {
        now := A_TickCount
        if (now - lastTap <= DOUBLE_TAP_MS) {
            Send(OUT_KEY)           ; 双击成立 → 发送目标键
            lastTap := 0
        } else {
            lastTap := now          ; 第一次轻点，记下时间
        }
    } else {
        lastTap := 0                ; 长按 或 组合键 → 重置计数
    }
}

; ---------- 备用：极简版 ----------
; 若上面的加强版在你的环境里不生效，可把上面的 ~LCtrl:: {...} 整段删掉，
; 再取消下面这段的注释。它只按“两次松开的时间间隔”判定，最简单最稳，
; 但快速连按两次 Ctrl+C 之类理论上可能误触。
;
; ~LCtrl up:: {
;     static last := 0
;     now := A_TickCount
;     if (now - last < 400) {
;         Send("{Enter}")
;         last := 0
;     } else {
;         last := now
;     }
; }
