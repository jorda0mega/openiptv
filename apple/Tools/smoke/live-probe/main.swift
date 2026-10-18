import Foundation

// The live-probe build (run.sh): LiveProbe.swift and the app's Xtream
// login code only.
exit(await LiveProbe.run(ProcessInfo.processInfo.environment))
