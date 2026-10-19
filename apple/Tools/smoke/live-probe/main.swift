import Foundation

// The build of the Mac's live tools (run.sh): LiveProbe.swift, LivePick.swift
// and the app's Xtream and Live TV code only.
let env = ProcessInfo.processInfo.environment
exit(await env["OPENIPTV_SMOKE_MODE"] == "live-pick" ? LivePick.run(env) : LiveProbe.run(env))
