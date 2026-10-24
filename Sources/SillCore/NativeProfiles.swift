import Foundation

/// One frame of a sampled stack: a function, the binary it is in, and where it is written when the symbols say.
public struct SampledFrame: Hashable, Sendable {
    public var name: String
    public var module: String
    public var file: String?
    public var line: Int?

    public init(name: String, module: String, file: String? = nil, line: Int? = nil) {
        self.name = name
        self.module = module
        self.file = file
        self.line = line
    }
}

/// Builds a profile document from sampled stacks, whatever recorded them: a call tree (program, thread, frames, root
/// first), and the hot spots, by the samples found in a function and no deeper (self) and with it anywhere on the stack
/// (total, once per sample however deep it recurses).
public struct CallTreeBuilder {
    private final class Node {
        var name: Int
        var samples = 0
        /// Its number in the document's preorder.
        var order = 0
        var children: [Int: Node] = [:]

        init(name: Int) { self.name = name }
    }

    private var names: [String] = []
    private var named: [String: Int] = [:]
    private let root: Node
    private var selfSamples: [String: Int] = [:]
    private var totals: [String: Int] = [:]
    /// Where each function is written, from the first frame of it that said.
    private var places: [String: (module: String, file: String?, line: Int?)] = [:]
    private(set) var samples = 0
    private var first = Double.infinity
    private var last = -Double.infinity

    public init(program: String) {
        names = [program]
        named = [program: 0]
        root = Node(name: 0)
    }

    private mutating func index(_ name: String) -> Int {
        if let index = named[name] { return index }
        names.append(name)
        named[name] = names.count - 1
        return names.count - 1
    }

    /// Frames with no symbol are named for their binary (`[libsystem_m.dylib]`); a run of them is one frame.
    public static func collapsed(_ frames: [SampledFrame]) -> [SampledFrame] {
        var out: [SampledFrame] = []
        for frame in frames {
            if frame.name.hasPrefix("["), out.last?.name == frame.name { continue }
            out.append(frame)
        }
        return out
    }

    /// Every sample's time, leaf node and weight, while times are known: the timeline and stretches come from them.
    private var timed: [(time: Double, leaf: Node, weight: Int)] = []
    private var untimed = false

    /// A sample: its thread, its frames root first, its weight (samples), and when (ms), if known.
    public mutating func add(thread: String, frames: [SampledFrame], weight: Int = 1, at time: Double? = nil) {
        guard weight > 0 else { return }
        samples += weight
        if let time {
            first = min(first, time)
            last = max(last, time)
        }
        root.samples += weight
        var node = root
        for name in [thread] + frames.map(\.name) {
            let key = index(name)
            let child = node.children[key] ?? {
                let made = Node(name: key)
                node.children[key] = made
                return made
            }()
            child.samples += weight
            node = child
        }
        if let time { timed.append((time, node, weight)) } else { untimed = true }
        if let leaf = frames.last { selfSamples[leaf.name, default: 0] += weight }
        for frame in Set(frames.map(\.name)) {
            totals[frame, default: 0] += weight
        }
        for frame in frames where places[frame.name] == nil || places[frame.name]?.file == nil && frame.file != nil {
            places[frame.name] = (frame.module, frame.file, frame.line)
        }
    }

    /// The document: the tree in preorder (heaviest child first), the 25 hottest functions.
    public func document(name: String, sampleMs: Double, exited: Bool) -> ProfileDocument {
        var frames: [Int] = []
        func walk(_ node: Node, _ depth: Int) {
            node.order = frames.count / 3
            frames += [node.name, depth, node.samples]
            for child in node.children.values.sorted(by: {
                $0.samples != $1.samples ? $0.samples > $1.samples : names[$0.name] < names[$1.name]
            }) {
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        let hot = selfSamples.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(25)
            .map { name, count in
                let place = places[name]
                return ProfileDocument.HotFrame(
                    name: name, module: place?.module ?? "", selfSamples: count, total: totals[name] ?? count,
                    file: place?.file, line: place?.line
                )
            }
        let duration = last > first ? last - first : Double(samples) * sampleMs
        var document = ProfileDocument(
            name: name, samples: samples, durationMs: duration, sampleMs: sampleMs, exited: exited, names: names,
            frames: frames, hotSpots: hot
        )
        if !untimed, !timed.isEmpty {
            let times = timed.map { $0.time - first }
            let weights = timed.contains { $0.weight != 1 } ? timed.map(\.weight) : nil
            document.sampleTimes = times
            document.sampleFrames = timed.map(\.leaf.order)
            document.sampleWeights = weights
            document.timeline = ProfileDocument.timeline(times: times, weights: weights)
        }
        return document
    }
}

/// samply's profile (the Firefox profiler's processed format) and the symbols it wrote beside it
/// (`--unstable-presymbolicate`), as a profile document.
public enum SamplyProfile {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case let .unreadable(why): "samply's profile does not read: \(why)"
            }
        }
    }

    public static func document(profile: Data, symbols: Data?, name: String, exited: Bool) throws -> ProfileDocument {
        guard let root = try JSONSerialization.jsonObject(with: profile) as? [String: Any],
              let threads = root["threads"] as? [[String: Any]] else { throw Failure.unreadable("no threads") }
        let libs = (root["libs"] as? [[String: Any]]) ?? []
        let interval = ((root["meta"] as? [String: Any])?["interval"] as? Double) ?? 1
        let symbolTable = try symbols.map(Symbols.init)
        var builder = CallTreeBuilder(program: name)
        for thread in threads {
            let strings = (thread["stringArray"] as? [String]) ?? []
            guard let samples = thread["samples"] as? [String: Any],
                  let stackTable = thread["stackTable"] as? [String: Any],
                  let frameTable = thread["frameTable"] as? [String: Any],
                  let funcTable = thread["funcTable"] as? [String: Any] else { continue }
            let resources = (thread["resourceTable"] as? [String: Any]) ?? [:]
            let prefix = array(stackTable["prefix"]), stackFrame = array(stackTable["frame"])
            let frameFunc = array(frameTable["func"]), frameAddress = array(frameTable["address"])
            let funcName = array(funcTable["name"]), funcResource = array(funcTable["resource"])
            let resourceLib = array(resources["lib"]), resourceName = array(resources["name"])
            let sampleStack = array(samples["stack"])
            let weights = array(samples["weight"])
            let times = (samples["time"] as? [Double]) ?? []
            // samply names the main thread for the process: as the program's own name it would say it twice.
            let threadName = (thread["name"] as? String).map { $0.isEmpty ? "thread" : $0 == name ? "main thread" : $0 }
                ?? "thread"
            var cache: [Int: [SampledFrame]] = [:]

            /// A frame of the table, as functions (inlined ones expanded), outermost first.
            func frames(_ frame: Int) -> [SampledFrame] {
                let function = frameFunc[safe: frame] ?? -1
                let resource = funcResource[safe: function] ?? -1
                let lib = resourceLib[safe: resource].flatMap { libs[safe: $0] }
                let module = resourceName[safe: resource].flatMap { strings[safe: $0] } ??
                    (lib?["name"] as? String) ?? "?"
                if let lib, let address = frameAddress[safe: frame], let symbolTable,
                   let found = symbolTable.lookup(lib: lib, address: address)
                {
                    return found.map { SampledFrame(name: $0.name, module: module, file: $0.file, line: $0.line) }
                }
                let name = funcName[safe: function].flatMap { strings[safe: $0] } ?? "?"
                return [SampledFrame(name: name.hasPrefix("0x") ? "[\(module)]" : name, module: module)]
            }

            /// A stack, root first.
            func stack(_ index: Int) -> [SampledFrame] {
                if let known = cache[index] { return known }
                let parent = prefix[safe: index].flatMap { $0 >= 0 ? stack($0) : nil } ?? []
                let made = CallTreeBuilder.collapsed(parent + (stackFrame[safe: index].map(frames) ?? []))
                cache[index] = made
                return made
            }

            for (sample, stackIndex) in sampleStack.enumerated() where stackIndex >= 0 {
                builder.add(
                    thread: threadName, frames: stack(stackIndex), weight: weights[safe: sample] ?? 1,
                    at: times[safe: sample]
                )
            }
        }
        return builder.document(name: name, sampleMs: interval, exited: exited)
    }

    /// An array of numbers, nulls as -1.
    private static func array(_ value: Any?) -> [Int] {
        ((value as? [Any]) ?? []).map { ($0 as? NSNumber)?.intValue ?? -1 }
    }

    /// The symbols samply wrote: per library, each known address's function and the functions inlined into it.
    struct Symbols {
        struct Entry {
            var name: String
            var frames: [(name: String, file: String?, line: Int?)]
        }

        /// By library (code id, else debug name): address to entry.
        private var tables: [String: [Int: Entry]] = [:]

        init(_ data: Data) throws {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let strings = root["string_table"] as? [String], let libraries = root["data"] as? [[String: Any]]
            else { throw Failure.unreadable("its symbols") }
            for library in libraries {
                let symbols = (library["symbol_table"] as? [[String: Any]]) ?? []
                let entries: [Entry] = symbols.map { symbol in
                    let name = (symbol["symbol"] as? Int).flatMap { strings[safe: $0] } ?? "?"
                    let frames = ((symbol["frames"] as? [[String: Any]]) ?? []).map { frame in
                        (
                            name: (frame["function"] as? Int).flatMap { strings[safe: $0] } ?? name,
                            file: (frame["file"] as? Int).flatMap { strings[safe: $0] },
                            line: frame["line"] as? Int
                        )
                    }
                    return Entry(name: name, frames: frames)
                }
                var table: [Int: Entry] = [:]
                for pair in (library["known_addresses"] as? [[Int]]) ?? [] where pair.count == 2 {
                    if let entry = entries[safe: pair[1]] { table[pair[0]] = entry }
                }
                for key in [library["code_id"] as? String, library["debug_name"] as? String].compactMap(\.self) {
                    tables[key.uppercased()] = table
                }
            }
        }

        /// A library's address as functions, outermost first: inlined ones expanded.
        func lookup(lib: [String: Any], address: Int) -> [(name: String, file: String?, line: Int?)]? {
            let keys = [lib["codeId"] as? String, lib["debugName"] as? String].compactMap(\.self)
            guard let entry = keys.lazy.compactMap({ tables[$0.uppercased()]?[address] }).first else { return nil }
            // samply lists the innermost first. The outermost is the symbol itself: its frame may carry the debug
            // info's
            // short name (`total`) where the symbol has the whole path (`rsample::pricing::total`).
            guard !entry.frames.isEmpty else { return [(entry.name, nil, nil)] }
            var frames = Array(entry.frames.reversed())
            if entry.name.hasSuffix(frames[0].name), entry.name != frames[0].name { frames[0].name = entry.name }
            // The function's own frame comes again as the first of its inlined ones: once is enough.
            var unique: [(name: String, file: String?, line: Int?)] = []
            for frame in frames {
                if let last = unique.last, entry.name.hasSuffix(frame.name), last.name == entry.name {
                    unique[unique.count - 1].line = frame.line ?? last.line
                    continue
                }
                unique.append(frame)
            }
            return unique
        }
    }
}

/// xctrace's Time Profiler, exported (`xctrace export --xpath …table[@schema="time-profile"]`), as a profile document.
/// The export names each element once with an id and refers back to it after; frames are leaf first.
public enum XctraceProfile {
    public static func document(xml: Data, name: String, exited: Bool) throws -> ProfileDocument {
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse() else {
            throw SamplyProfile.Failure.unreadable(parser.parserError?.localizedDescription ?? "the export")
        }
        var builder = CallTreeBuilder(program: name)
        for row in reader.rows {
            let frames = row.frames.reversed().map { frame in
                var frame = frame
                if frame.name.hasPrefix("0x") { frame.name = "[\(frame.module.isEmpty ? "?" : frame.module)]" }
                return frame
            }
            builder.add(thread: row.thread, frames: CallTreeBuilder.collapsed(frames), weight: 1, at: row.time)
        }
        return builder.document(name: name, sampleMs: reader.weightMs ?? 1, exited: exited)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Row {
            var time: Double?
            var thread = "thread"
            var frames: [SampledFrame] = []
        }

        private(set) var rows: [Row] = []
        private(set) var weightMs: Double?
        private var row: Row?
        /// What an id names: a frame, a thread's name, a binary's name, a path, a time.
        private var frames: [String: SampledFrame] = [:]
        private var threads: [String: String] = [:]
        private var binaries: [String: String] = [:]
        private var paths: [String: String] = [:]
        private var times: [String: Double] = [:]
        /// Whole backtraces by id: a row may refer to an earlier row's.
        private var backtraces: [String: [SampledFrame]] = [:]
        private var backtraceID: String?
        private var text = ""
        /// The frame being read, and its id, until its element ends.
        private var frame: (id: String?, value: SampledFrame)?
        private var pathID: String?
        private var timeID: String?
        private var inBacktrace = false

        func parser(
            _: XMLParser, didStartElement element: String, namespaceURI _: String?, qualifiedName _: String?,
            attributes: [String: String]
        ) {
            text = ""
            let id = attributes["id"], ref = attributes["ref"]
            switch element {
            case "row": row = Row()
            case "sample-time":
                if let ref { row?.time = times[ref] } else { timeID = id }
            case "thread":
                guard frame == nil, !inBacktrace else { break }
                if let ref { row?.thread = threads[ref] ?? "thread" } else {
                    let name = Self.threadName(attributes["fmt"] ?? "thread")
                    if let id { threads[id] = name }
                    row?.thread = name
                }
            case "weight":
                if weightMs == nil, let fmt = attributes["fmt"], fmt.hasSuffix(" ms") {
                    weightMs = Double(fmt.dropLast(3).trimmingCharacters(in: .whitespaces))
                }
            case "tagged-backtrace", "backtrace":
                if let ref {
                    row?.frames = backtraces[ref] ?? []
                } else {
                    inBacktrace = true
                    backtraceID = id
                }
            case "frame":
                if let ref, let known = frames[ref] {
                    row?.frames.append(known)
                } else {
                    frame = (id, SampledFrame(name: attributes["name"] ?? "?", module: ""))
                }
            case "binary":
                guard frame != nil else { break }
                if let ref { frame?.value.module = binaries[ref] ?? "" } else {
                    let name = attributes["name"] ?? ""
                    if let id { binaries[id] = name }
                    frame?.value.module = name
                }
            case "source":
                frame?.value.line = attributes["line"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            case "path":
                if let ref { frame?.value.file = paths[ref] } else { pathID = id }
            default: break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) { text += string }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            switch element {
            case "row":
                if let row { rows.append(row) }
                row = nil
            case "sample-time":
                if let timeID, let nanoseconds = Double(text.trimmingCharacters(in: .whitespaces)) {
                    times[timeID] = nanoseconds / 1_000_000
                    row?.time = nanoseconds / 1_000_000
                }
                timeID = nil
            case "path":
                if let pathID {
                    paths[pathID] = text
                    frame?.value.file = text
                }
                pathID = nil
            case "frame":
                if let current = frame {
                    if let id = current.id { frames[id] = current.value }
                    row?.frames.append(current.value)
                }
                frame = nil
            case "tagged-backtrace", "backtrace":
                if inBacktrace, let backtraceID { backtraces[backtraceID] = row?.frames ?? [] }
                inBacktrace = false
                backtraceID = nil
            default: break
            }
        }

        /// "Main Thread (0x2e296e1) (ssample, pid: 31765)" as "Main Thread".
        static func threadName(_ fmt: String) -> String {
            let name = fmt.components(separatedBy: " (0x").first ?? fmt
            return name.isEmpty ? "thread" : name
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
