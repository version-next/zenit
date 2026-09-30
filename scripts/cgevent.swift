// CGEvent 合成输入：拖拽 / 滚动 / 点击。
//
// 主要用途：**拖放的真机验证** —— 从 Finder 拖真文件进 zenit 窗口。
// 已实测：CGEvent 合成的 mousedown→dragged→mouseup 能驱动 macOS 真正的
// NSDragging 会话，目标窗口的 performDragOperation: 会带着真实 pasteboard
// 触发（判据：ZENIT_DEBUG_DRAG=1 下 stderr 出现 `[DRAG] kind=3 ... paths=/...`）。
// System Events 的 `click at` 是原子动作，无法表达按住不放，故不能用于拖拽。
//
// 用法（坐标为全局屏幕坐标，左上原点）：
//   swift scripts/cgevent.swift drag   <sx> <sy> <ex> <ey>
//   swift scripts/cgevent.swift scroll <x> <y> <ticks>     # ticks<0 向下滚
//   swift scripts/cgevent.swift click  <x> <y>
//
// 需要运行它的进程持有「辅助功能」权限。

import CoreGraphics
import Foundation

let src = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                          mouseCursorPosition: p, mouseButton: .left) else { return }
    e.post(tap: .cghidEventTap)
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage:
      cgevent.swift drag      <sx> <sy> <ex> <ey>
      cgevent.swift dragmulti <x> <y1> <y2> <ex> <ey>
      cgevent.swift draghold  <sx> <sy> <ex> <ey> <holdSeconds>
      cgevent.swift scroll    <x> <y> <ticks>
      cgevent.swift click     <x> <y>

    """.data(using: .utf8)!)
    exit(2)
}

let a = CommandLine.arguments
guard a.count >= 2 else { usage() }

switch a[1] {
case "drag":
    guard a.count >= 6,
          let sx = Double(a[2]), let sy = Double(a[3]),
          let ex = Double(a[4]), let ey = Double(a[5]) else { usage() }

    // 先把光标移到起点并稳定一帧，否则按下会被当成上一位置的点击。
    post(.mouseMoved, CGPoint(x: sx, y: sy))
    usleep(200_000)
    post(.leftMouseDown, CGPoint(x: sx, y: sy))
    // 按下后立刻起拖：在 Finder 里按住多选行不动太久，选区会塌缩成单个文件，
    // 多文件拖放就变成单文件（实测踩过）。
    usleep(30_000)

    // 分步拖动：一次跳到终点会被系统判为「非拖拽」，必须有连续中间事件，
    // 系统才会起 NSDragging 会话并把 pasteboard 挂上去。
    let steps = 40
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: sx + (ex - sx) * t, y: sy + (ey - sy) * t))
        usleep(25_000)
    }
    // 终点多停几帧，给 draggingUpdated 派发机会。
    for _ in 0..<10 {
        post(.leftMouseDragged, CGPoint(x: ex, y: ey))
        usleep(50_000)
    }
    post(.leftMouseUp, CGPoint(x: ex, y: ey))
    usleep(300_000)
    print("drag posted: (\(sx),\(sy)) -> (\(ex),\(ey))")

case "draghold":
    // 拖到目标上方悬停 N 秒再放开 —— 用来截图验证 on_drag_enter 的悬停高亮。
    guard a.count >= 7,
          let sx = Double(a[2]), let sy = Double(a[3]),
          let ex = Double(a[4]), let ey = Double(a[5]),
          let holdSec = Double(a[6]) else { usage() }
    post(.mouseMoved, CGPoint(x: sx, y: sy))
    usleep(200_000)
    post(.leftMouseDown, CGPoint(x: sx, y: sy))
    usleep(30_000)
    let hsteps = 40
    for i in 1...hsteps {
        let t = Double(i) / Double(hsteps)
        post(.leftMouseDragged, CGPoint(x: sx + (ex - sx) * t, y: sy + (ey - sy) * t))
        usleep(25_000)
    }
    // 悬停期间持续补 dragged 事件，否则系统会认为拖拽停滞。
    let ticks = Int(holdSec * 10)
    for _ in 0..<max(1, ticks) {
        post(.leftMouseDragged, CGPoint(x: ex, y: ey))
        usleep(100_000)
    }
    post(.leftMouseUp, CGPoint(x: ex, y: ey))
    usleep(300_000)
    print("draghold posted: (\(sx),\(sy)) -> (\(ex),\(ey)) hold=\(holdSec)s")

case "dragmulti":
    // 多选拖拽：先 click(x,y1) 再 shift-click(x,y2) 建立连续选区，
    // 然后立刻从 y2 起拖 —— 中间不松手、不停顿，否则 Finder 会把选区塌缩成单个。
    guard a.count >= 7,
          let x = Double(a[2]), let y1 = Double(a[3]), let y2 = Double(a[4]),
          let ex = Double(a[5]), let ey = Double(a[6]) else { usage() }

    func shiftClick(_ p: CGPoint) {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            if let e = CGEvent(mouseEventSource: src, mouseType: t,
                               mouseCursorPosition: p, mouseButton: .left) {
                e.flags = .maskShift
                e.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
    }

    post(.mouseMoved, CGPoint(x: x, y: y1))
    usleep(150_000)
    post(.leftMouseDown, CGPoint(x: x, y: y1))
    usleep(60_000)
    post(.leftMouseUp, CGPoint(x: x, y: y1))
    usleep(250_000)
    shiftClick(CGPoint(x: x, y: y2))
    usleep(250_000)

    post(.leftMouseDown, CGPoint(x: x, y: y2))
    usleep(30_000)
    let msteps = 40
    for i in 1...msteps {
        let t = Double(i) / Double(msteps)
        post(.leftMouseDragged, CGPoint(x: x + (ex - x) * t, y: y2 + (ey - y2) * t))
        usleep(25_000)
    }
    for _ in 0..<10 {
        post(.leftMouseDragged, CGPoint(x: ex, y: ey))
        usleep(50_000)
    }
    post(.leftMouseUp, CGPoint(x: ex, y: ey))
    usleep(300_000)
    print("dragmulti posted: rows y=\(y1),\(y2) at x=\(x) -> (\(ex),\(ey))")

case "scroll":
    guard a.count >= 5,
          let x = Double(a[2]), let y = Double(a[3]), let ticks = Int32(a[4]) else { usage() }
    post(.mouseMoved, CGPoint(x: x, y: y))
    usleep(100_000)
    let step: Int32 = ticks < 0 ? -3 : 3
    for _ in 0..<abs(ticks) {
        if let e = CGEvent(scrollWheelEvent2Source: src, units: .line,
                           wheelCount: 1, wheel1: step, wheel2: 0, wheel3: 0) {
            e.location = CGPoint(x: x, y: y)
            e.post(tap: .cghidEventTap)
        }
        usleep(30_000)
    }
    print("scrolled \(ticks) at (\(x),\(y))")

case "click":
    guard a.count >= 4, let x = Double(a[2]), let y = Double(a[3]) else { usage() }
    let p = CGPoint(x: x, y: y)
    post(.mouseMoved, p)
    usleep(100_000)
    post(.leftMouseDown, p)
    usleep(80_000)
    post(.leftMouseUp, p)
    usleep(150_000)
    print("clicked (\(x),\(y))")

default:
    usage()
}
