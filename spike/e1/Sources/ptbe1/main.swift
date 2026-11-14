// Throwaway (Track B experiment E1). Synchronous main: no top-level await (G-b).
import CE1Shim
import Foundation

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "symbols": runSymbols()
case "p2": runP2(a[2])
case "p3": runP3(a[2])
case "idle": runIdle(a[2], Double(a[3]) ?? 30)
case "modal": runModal(a[2])
case "tray": runTray()
case "facts": runFacts()
case "pchild": runPChild(a[2], a[3])
case "pread": runPRead(Array(a.dropFirst(2)))
case "argv": for x in a.dropFirst(2) { say("ARGV " + x) }
case "process": runProcess()
case "net": runNet()
default:
    say("usage: ptbe1 symbols | p2 <cf|cfh|cf0|dh|poll> | p3 <variant> | idle <strategy> <secs> | modal <plain|rl|dq> | tray | "
        + "facts | pchild <key> <mode> | pread <key=present|absent|info>... | argv ... | process | net")
}
