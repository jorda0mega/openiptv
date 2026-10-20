import Foundation

let env = ProcessInfo.processInfo.environment
exit(await env["OPENIPTV_SMOKE_MODE"] == "live-pick" ? LivePick.run(env) : LiveProbe.run(env))
