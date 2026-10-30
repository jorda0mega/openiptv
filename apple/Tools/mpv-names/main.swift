import Foundation
import Libmpv

setvbuf(stdout, nil, _IONBF, 0)

enum Kind { case option, property, field }

struct Use: Hashable {
    let name: String
    let kind: Kind
    let values: [String]
}

/// Where a call names an option or property, and where its value is.
struct Target: Equatable {
    let kind: Kind
    let name: Int
    let value: Int?
}

let functions: [String: Target] = [
    "mpv_set_option_string": Target(kind: .option, name: 1, value: 2), "mpv_set_option": Target(kind: .option, name: 1, value: nil),
    "mpv_set_property_string": Target(kind: .property, name: 1, value: 2), "mpv_set_property": Target(kind: .property, name: 1, value: nil),
    "mpv_get_property_string": Target(kind: .property, name: 1, value: nil), "mpv_get_property": Target(kind: .property, name: 1, value: nil),
    "mpv_observe_property": Target(kind: .property, name: 2, value: nil),
]

/// The source with comments blanked and string contents masked (line breaks kept), so that braces, quotes and
/// calls are only ever read in code. The literals stay in `source`, at the same positions.
struct Masked {
    let source: [Character]
    let code: [Character]

    init(_ text: String) {
        source = Array(text)
        var code = source, i = 0
        func blank(_ k: Int) { if code[k] != "\n" { code[k] = " " } }
        while i < source.count {
            let c = source[i], next: Character? = i + 1 < source.count ? source[i + 1] : nil
            if c == "/", next == "/" {
                while i < source.count, source[i] != "\n" { blank(i); i += 1 }
            } else if c == "/", next == "*" {
                while i < source.count, !(source[i] == "*" && i + 1 < source.count && source[i + 1] == "/") { blank(i); i += 1 }
                if i < source.count { blank(i); blank(i + 1); i += 2 }
            } else if c == "\"" {
                i += 1
                while i < source.count, source[i] != "\"" {
                    if source[i] == "\\" { blank(i); i += 1 }
                    if i < source.count { blank(i); i += 1 }
                }
                i += 1
            } else {
                i += 1
            }
        }
        self.code = code
    }

    /// The literal whose opening quote is at `at`, as written.
    func literal(at: Int) -> String? {
        guard source[at] == "\"", let end = code[(at + 1)...].firstIndex(of: "\"") else { return nil }
        let text = String(source[(at + 1)..<end])
        return text.contains("\\(") ? nil : text
    }

    /// The span of the bracket that matches the one at `open` (`(`, `[` or `{`).
    func matching(_ open: Int) -> Int? {
        var depth = 0
        for i in open..<code.count {
            if "([{".contains(code[i]) { depth += 1 } else if ")]}".contains(code[i]) { depth -= 1 }
            if depth == 0 { return i }
        }
        return nil
    }

    /// The ranges of the arguments of the call or tuple whose "(" is at `open`, split at its own commas.
    func arguments(from open: Int) -> [Range<Int>]? {
        guard let close = matching(open) else { return nil }
        var depth = 0, start = open + 1, found: [Range<Int>] = []
        for i in (open + 1)..<close {
            if "([{".contains(code[i]) { depth += 1 } else if ")]}".contains(code[i]) { depth -= 1 }
            if code[i] == ",", depth == 0 {
                found.append(start..<i)
                start = i + 1
            }
        }
        return found + [start..<close]
    }

    func trimmed(_ range: Range<Int>) -> Range<Int> {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, code[lower].isWhitespace { lower += 1 }
        while upper > lower, code[upper - 1].isWhitespace { upper -= 1 }
        return lower..<upper
    }

    /// The name in an argument that is one string literal, spelled as written: libmpv judges it.
    func name(_ range: Range<Int>) -> String? {
        let r = trimmed(range)
        guard r.count >= 2, code[r.lowerBound] == "\"", code[r.upperBound - 1] == "\"",
              !code[(r.lowerBound + 1)..<(r.upperBound - 1)].contains("\"") else { return nil }
        return literal(at: r.lowerBound)
    }

    /// The identifier an argument is, if it is one.
    func identifier(_ range: Range<Int>) -> String? {
        let r = trimmed(range), text = String(code[r])
        return !text.isEmpty && text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) ? text : nil
    }

    /// The literals an argument can be: the branches of its `?:` and `??` that are one literal each.
    func values(_ range: Range<Int>) -> [String] {
        var branches: [Range<Int>] = [], depth = 0, start = range.lowerBound, i = range.lowerBound
        while i < range.upperBound {
            let c = code[i]
            if "([{".contains(c) { depth += 1 } else if ")]}".contains(c) { depth -= 1 }
            if depth == 0, c == "?" || c == ":" {
                branches.append(start..<i)
                if c == "?", i + 1 < range.upperBound, code[i + 1] == "?" { i += 1 }
                start = i + 1
            }
            i += 1
        }
        branches.append(start..<range.upperBound)
        return branches.compactMap(name)
    }
}

/// Calls in `range`: the callee and its "(". `x.f(` is left out, except for `self.` and `Self.`.
func calls(_ masked: Masked, in range: Range<Int>) -> [(callee: String, open: Int)] {
    let code = masked.code
    var found: [(String, Int)] = []
    for i in range where code[i] == "(" && i > 0 && (code[i - 1].isLetter || code[i - 1].isNumber || code[i - 1] == "_") {
        var j = i
        while j > 0, code[j - 1].isLetter || code[j - 1].isNumber || code[j - 1] == "_" { j -= 1 }
        let before = String(code[max(0, j - 5)..<j])
        if before.hasSuffix("func ") { continue }
        if j > 0, code[j - 1] == ".", !(before.hasSuffix("self.") || before.hasSuffix("Self.")) { continue }
        found.append((String(code[j..<i]), i))
    }
    return found
}

/// A function in the file, where a call reaches it, and, when it hands one of its own parameters to libmpv as a
/// name (or reads mpv's node map by one), what it names. A function that names nothing still hides an outer one.
struct Definition {
    let name: String
    let parameters: [String]
    let body: Range<Int>
    let scope: Range<Int>
    var target: Target?
}

func definitions(in masked: Masked) -> [Definition] {
    let code = masked.code
    var found: [Definition] = [], i = 0
    while let start = code[i...].indices.first(where: { k in
        k + 5 <= code.count && String(code[k..<(k + 5)]) == "func " && (k == 0 || !(code[k - 1].isLetter || code[k - 1].isNumber))
    }) {
        i = start + 5
        var k = i
        while k < code.count, code[k].isLetter || code[k].isNumber || code[k] == "_" { k += 1 }
        guard k < code.count, code[k] == "(", let params = masked.arguments(from: k), let close = masked.matching(k),
              let brace = code[close...].firstIndex(of: "{"), let end = masked.matching(brace) else { continue }
        // The internal name of each parameter: `_ name: String` is "name".
        let names = params.map { range -> String in
            let text = String(code[range]).split(separator: ":").first.map(String.init) ?? ""
            return text.split(separator: " ").last.map(String.init) ?? ""
        }
        var lineStart = start
        while lineStart > 0, code[lineStart - 1] != "\n" { lineStart -= 1 }
        let indent = code[lineStart...].prefix { $0 == " " }.count
        var scopeEnd = code.count
        if indent > 4 {
            // A local function reaches to the end of the block around it.
            var depth = 0
            for m in (end + 1)..<code.count {
                if code[m] == "{" { depth += 1 } else if code[m] == "}" {
                    if depth == 0 { scopeEnd = m; break }
                    depth -= 1
                }
            }
        }
        found.append(Definition(name: String(code[i..<k]), parameters: names, body: (brace + 1)..<end,
                                scope: indent > 4 ? start..<scopeEnd : 0..<code.count))
    }
    // Repeated until nothing changes: a wrapper can hand its name to another wrapper.
    for _ in 0..<4 {
        for d in found.indices where found[d].target == nil {
            let params = found[d].parameters
            for (callee, open) in calls(masked, in: found[d].body) {
                guard let args = masked.arguments(from: open),
                      let via = functions[callee] ?? resolve(callee, at: open, in: found)?.target,
                      via.name < args.count, let p = masked.identifier(args[via.name]).flatMap({ params.firstIndex(of: $0) }) else { continue }
                let value = via.value.flatMap { $0 < args.count ? masked.identifier(args[$0]) : nil }.flatMap { params.firstIndex(of: $0) }
                found[d].target = Target(kind: via.kind, name: p, value: value)
                break
            }
            if found[d].target == nil, let p = params.firstIndex(where: { name in
                !name.isEmpty && String(masked.code[found[d].body]).contains("[\(name)]")
            }) {
                found[d].target = Target(kind: .field, name: p, value: nil)
            }
        }
    }
    return found
}

/// The definition a call at `at` reaches: the innermost one whose scope holds it.
func resolve(_ callee: String, at: Int, in defs: [Definition]) -> Definition? {
    defs.filter { $0.name == callee && $0.scope.contains(at) }.min { $0.scope.count < $1.scope.count }
}

var uses = Set<Use>(), failures: [String] = []
for path in CommandLine.arguments.dropFirst(2) {
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    guard text.contains("import Libmpv") else { continue }
    let masked = Masked(text)
    let defs = definitions(in: masked)
    for (callee, open) in calls(masked, in: 0..<masked.code.count) {
        let target: Target?
        if let table = functions[callee] {
            target = table
        } else if callee.hasPrefix("mpv_"), callee.contains("property") || callee.contains("option") {
            failures.append("UNCHECKED CALL \(callee)")
            continue
        } else {
            target = resolve(callee, at: open, in: defs)?.target
        }
        guard let target, let args = masked.arguments(from: open), target.name < args.count, let name = masked.name(args[target.name]) else {
            continue
        }
        let given = target.value.flatMap { $0 < args.count ? masked.values(args[$0]) : nil } ?? []
        uses.insert(Use(name: name, kind: target.kind, values: given))
    }
}

// Pairs the app keeps as data, computed by MacTests/MPVNamesTests with the app's own code: "option|property<tab>name<tab>value".
if ProcessInfo.processInfo.environment["MPV_NAMES_PAIRS"] == "stdin" {
    while let line = readLine() {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind: Kind = parts[0] == "option" ? .option : parts[0] == "property" ? .property : nil else {
            fatalError("a data line is not option|property<tab>name<tab>value")
        }
        uses.insert(Use(name: parts[1], kind: kind, values: [parts[2]]))
    }
}

let scripts = ["load-scripts", "osc", "ytdl", "load-stats-overlay", "load-console", "load-auto-profiles", "load-select",
               "load-commands", "load-positioning", "load-context-menu", "input-default-bindings"]
guard let running = mpv_create() else { fatalError("mpv_create") }
for (name, value) in [("vo", "null"), ("ao", "null"), ("msg-level", "all=no"), ("terminal", "no"), ("pause", "yes"), ("sid", "1")]
    + scripts.map({ ($0, "no") }) {
    mpv_set_option_string(running, name, value)
}
guard mpv_initialize(running) >= 0 else { fatalError("libmpv did not start") }
let load = [strdup("loadfile"), strdup(CommandLine.arguments[1]), nil]
var words = load.map { $0.map { UnsafePointer($0) } }
mpv_command(running, &words)
let deadline = Date().addingTimeInterval(20)
while mpv_wait_event(running, 0.1)?.pointee.event_id != MPV_EVENT_PLAYBACK_RESTART {
    guard Date() < deadline else { fatalError("the test film did not play") }
}

func read(_ name: String) -> Int32 {
    var node = mpv_node()
    let result = mpv_get_property(running, name, MPV_FORMAT_NODE, &node)
    if result >= 0 { mpv_free_node_contents(&node) }
    return result
}

/// A property, or a sub-key of one, read on the test film.
func property(_ name: String) -> String? {
    let result = read(name)
    if result >= 0 || (result == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue && !name.contains("/")) { return nil }
    return result == MPV_ERROR_PROPERTY_NOT_FOUND.rawValue ? "UNKNOWN" : "UNVERIFIED (\(result))"
}

var verified = 0
let options = Set(uses.filter { $0.kind == .option }.map(\.name)).count
for use in uses.sorted(by: { $0.name < $1.name }) where use.kind == .option {
    for value in use.values.isEmpty ? [""] : use.values {
        // Each value on a player of its own, before it starts, as setUp sets it.
        guard let fresh = mpv_create() else { fatalError("mpv_create") }
        let result = mpv_set_option_string(fresh, use.name, value)
        mpv_destroy(fresh)
        if result == MPV_ERROR_OPTION_NOT_FOUND.rawValue { failures.append("UNKNOWN OPTION \(use.name)"); break }
        if result < 0, !use.values.isEmpty { failures.append("VALUE REFUSED \(use.name)") } else if !use.values.isEmpty { verified += 1 }
    }
}
let fields = Set(uses.filter { $0.kind == .field }.map(\.name))
for name in fields.sorted() {
    if !(0..<3).contains(where: { read("track-list/\($0)/\(name)") >= 0 }) { failures.append("UNKNOWN TRACK FIELD \(name)") }
}
let asProperties = uses.filter { $0.kind == .property }
let properties = Set(asProperties.map(\.name))
for name in properties.sorted() {
    if let failure = property(name) { failures.append("\(failure) \(name)") }
}
// Values last: setting them changes the test player, which stays paused on its film.
for use in asProperties.sorted(by: { $0.name < $1.name }) {
    for value in use.values {
        let result = mpv_set_property_string(running, use.name, value)
        if result >= 0 { verified += 1 } else if result != MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue { failures.append("VALUE REFUSED \(use.name)") }
        mpv_set_property_string(running, "pause", "yes")
    }
}
print("\(options) option names, \(properties.count) property names, \(fields.count) track fields, \(verified) values checked against this libmpv")
for failure in Set(failures).sorted() { print(failure) }
mpv_terminate_destroy(running)
// Names the caller requires to be among those checked: "MPV_NAMES_REQUIRE=name,name".
let checked = Set(uses.map(\.name))
for name in (ProcessInfo.processInfo.environment["MPV_NAMES_REQUIRE"] ?? "").split(separator: ",").map(String.init) where !checked.contains(name) {
    print("NOT CHECKED \(name)")
    failures.append(name)
}
exit(failures.isEmpty && options > 0 && !properties.isEmpty && !fields.isEmpty && verified > 0 ? 0 : 1)
