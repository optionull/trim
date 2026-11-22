import Foundation
@testable import FrameRun
import Testing

@Suite("What can be run")
struct RunEntriesTests {
    private func folder(_ files: [String: String]) throws -> String {
        let root = NSTemporaryDirectory() + "frame-run-\(UUID().uuidString)"
        for (name, text) in files {
            let path = root + "/" + name
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("VS Code's JSON has comments and trailing commas")
    func jsonc() {
        let value = VSCode.parse("""
        {
          // a comment
          "a": "has // inside", /* block */
          "b": [1, 2,],
        }
        """) as? [String: Any]
        #expect(value?["a"] as? String == "has // inside")
        #expect((value?["b"] as? [Int]) == [1, 2])
    }

    @Test("tasks: a shell task, a process task with arguments, the default build, a working folder and variables")
    func tasks() throws {
        let root = try folder([".vscode/tasks.json": """
        {
          "version": "2.0.0",
          "tasks": [
            { "label": "build", "type": "shell", "command": "dotnet build ${workspaceFolder}/App.sln",
              "group": { "kind": "build", "isDefault": true } },
            { "label": "lint", "type": "process", "command": "eslint", "args": ["src dir", "--fix"],
              "options": { "cwd": "${workspaceFolder}/web", "env": { "CI": "1" } } },
            { "label": "no command" },
          ]
        }
        """])
        let entries = VSCode.tasks(in: root)
        #expect(entries.map(\.title) == ["build", "lint"])
        #expect(entries[0].command == "dotnet build \(root)/App.sln" && entries[0].kind == .build && entries[0]
            .isDefault)
        #expect(entries[1].command == "eslint 'src dir' --fix")
        #expect(entries[1].directory == root + "/web" && entries[1].environment == ["CI": "1"])
    }

    @Test("launch configurations: node, a built dll and a native binary are commands; attach and unknown types are not")
    func launches() throws {
        let root = try folder([".vscode/launch.json": """
        {
          "configurations": [
            { "name": "Server", "type": "node", "request": "launch", "program": "${workspaceFolder}/server.js", "args": ["--port", "80"] },
            { "name": "Api", "type": "coreclr", "request": "launch", "program": "${workspaceFolder}/bin/Api.dll", "cwd": "${workspaceFolder}/src" },
            { "name": "Tool", "type": "lldb", "request": "launch", "program": "${workspaceFolder}/.build/debug/tool" },
            { "name": "Attach", "type": "node", "request": "attach" },
            { "name": "Odd", "type": "chrome", "request": "launch", "url": "http://x" },
          ]
        }
        """])
        let entries = VSCode.launches(in: root)
        #expect(entries.map(\.title) == ["Server", "Api", "Tool"])
        #expect(entries[0].command == "node \(root)/server.js --port 80")
        #expect(entries[1].command == "dotnet \(root)/bin/Api.dll" && entries[1].directory == root + "/src")
        #expect(entries[2].command == "\(root)/.build/debug/tool")
    }

    @Test("make: targets, not variables, pattern rules or special names")
    func make() throws {
        let root = try folder(["Makefile": """
        CC := gcc
        .PHONY: all test
        all: build
        build: main.o
        \tcc -o app main.o
        %.o: %.c
        \tcc -c $<
        test-unit test:
        \t./run
        FLAGS ?= -O2
        """])
        let entries = RunEntries.make(in: root)
        #expect(entries.map(\.title) == ["all", "build", "test-unit", "test"], "\(entries.map(\.title))")
        #expect(entries[1].command == "make build" && entries[1].kind == .build && entries[2].kind == .test)
    }

    @Test("builds: a solution before its projects, a package, Cargo; and everything comes back builds first")
    func builds() throws {
        let root = try folder([
            "App.slnx": "<Solution/>", "src/App.csproj": "<Project/>", "Package.swift": "// swift-tools-version:5.9\n",
            "Makefile": "test:\n\t:\n",
        ])
        let builds = RunEntries.builds(in: root)
        #expect(builds.map(\.command) == ["dotnet build App.slnx", "swift build"], "\(builds.map(\.command))")
        let all = RunEntries.find(in: root)
        #expect(all.first?.kind == .build)
        #expect(all.contains { $0.source == "make" && $0.title == "test" })
    }
}
