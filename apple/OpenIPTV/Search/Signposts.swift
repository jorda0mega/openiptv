#if DEBUG
import os

/// Debug builds: Instruments' Points of Interest marks for search, so a
/// trace shows each search run, each change to the results, and why it
/// ran, and when the top result's player is warmed up.
let searchSignposter = OSSignposter(subsystem: "com.jorda0mega.openiptv", category: .pointsOfInterest)
#endif
