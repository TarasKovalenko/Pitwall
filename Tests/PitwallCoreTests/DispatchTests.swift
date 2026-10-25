import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

@Suite struct MiniYAMLTests {
    @Test func blockMapsListsAndScalars() throws {
        let doc = try MiniYAML.parse("""
        # comment
        name: CI   # trailing comment
        quoted: "a: b # not a comment"
        single: 'it''s'
        list:
          - one
          - "two"
        same_indent_list:
        - x
        - y
        flow: [a, "b, c", 'd']
        flow_map: {k: v, n: 1}
        nested:
          deeper:
            key: value
        empty:
        url: https://example.com/a#frag
        """)
        #expect(doc["name"] == .scalar("CI"))
        #expect(doc["quoted"] == .scalar("a: b # not a comment"))
        #expect(doc["single"] == .scalar("it's"))
        #expect(doc["list"] == .list([.scalar("one"), .scalar("two")]))
        #expect(doc["same_indent_list"] == .list([.scalar("x"), .scalar("y")]))
        #expect(doc["flow"] == .list([.scalar("a"), .scalar("b, c"), .scalar("d")]))
        #expect(doc["flow_map"]?["n"] == .scalar("1"))
        #expect(doc["nested"]?["deeper"]?["key"] == .scalar("value"))
        #expect(doc["empty"] == .scalar(""))
        #expect(doc["url"] == .scalar("https://example.com/a#frag"))
    }

    @Test func blockScalarsKeepTheirText() throws {
        let doc = try MiniYAML.parse("""
        literal: |
          line one
          # not a comment

          line three
        folded: >-
          folded
          text
        after: yes
        """)
        #expect(doc["literal"] == .scalar("line one\n# not a comment\n\nline three"))
        #expect(doc["folded"] == .scalar("folded text"))
        #expect(doc["after"] == .scalar("yes"))
    }

    @Test func listsOfMaps() throws {
        let doc = try MiniYAML.parse("""
        steps:
          - name: Checkout
            uses: actions/checkout@v5
          - run: echo "hi: there"
        """)
        guard case .list(let steps)? = doc["steps"] else { Issue.record("not a list"); return }
        #expect(steps.count == 2)
        #expect(steps[0]["uses"] == .scalar("actions/checkout@v5"))
        #expect(steps[1]["run"] == .scalar("echo \"hi: there\""))
    }

    @Test func multiLineFlowList() throws {
        let doc = try MiniYAML.parse("""
        options: [
          dev,
          prod
        ]
        """)
        #expect(doc["options"] == .list([.scalar("dev"), .scalar("prod")]))
    }

    @Test func malformedDocumentsSayWhere() {
        #expect(throws: YAMLError.malformed(line: 2, reason: "unexpected indentation")) { try MiniYAML.parse("a: 1\n  b: 2") }
        #expect(throws: YAMLError.malformed(line: 2, reason: "unexpected indentation")) { try MiniYAML.parse("  a: 1\nb: 2") }
        #expect(throws: YAMLError.malformed(line: 2, reason: "expected `key: value`")) { try MiniYAML.parse("a: 1\njust text") }
        #expect(throws: YAMLError.malformed(line: 1, reason: "text after flow collection")) { try MiniYAML.parse("a: [x] y") }
    }

    @Test func smallerCases() throws {
        #expect(try MiniYAML.parse("") == .map([]))
        #expect(try MiniYAML.parse("---\na: 1\n...") ["a"] == .scalar("1"))
        #expect(try MiniYAML.parse(#"a: "x\ny\tz\"q\\""#)["a"] == .scalar("x\ny\tz\"q\\"))
        #expect(YAMLNode.scalar("x")["k"] == nil)
        #expect(YAMLNode.list([]).string == nil)
        #expect(try MiniYAML.parse("a:\n  -\n    b: 1\n  -\n")["a"] == .list([.map([.init(key: "b", value: .scalar("1"))]), .scalar("")]))
        #expect(try MiniYAML.parse("a: {k}")["a"] == .map([.init(key: "k", value: .scalar(""))]))
        #expect(try MiniYAML.parse("a: []")["a"] == .list([]))
        #expect(try MiniYAML.parse("- [a, [b]]") == .list([.list([.scalar("a"), .list([.scalar("b")])])]))
    }

    @Test func rejectsHostileInput() {
        #expect(throws: YAMLError.tooLarge) { try MiniYAML.parse(String(repeating: "a", count: MiniYAML.maxBytes + 1)) }
        let deep = (0..<200).map { String(repeating: "  ", count: $0) + "k\($0):" }.joined(separator: "\n")
        #expect(throws: YAMLError.tooDeep) { try MiniYAML.parse(deep) }
        #expect(throws: YAMLError.tooDeep) { try MiniYAML.parse("a: " + String(repeating: "[", count: 200) + String(repeating: "]", count: 200)) }
        #expect(throws: (any Error).self) { try MiniYAML.parse("a:\n\tb: c") }
        #expect(throws: (any Error).self) { try MiniYAML.parse("a: [unclosed") }
    }
}

@Suite struct DispatchSpecTests {
    let workflow = """
    name: Deploy
    on:
      push:
        branches: [main]
      workflow_dispatch:
        inputs:
          environment:
            description: 'Where to deploy'
            required: true
            type: choice
            options:
              - staging
              - production
            default: staging
          dry_run:
            description: Skip the actual deploy
            type: boolean
            default: true
          replicas:
            type: number
            default: 3
          note:
            description: >
              Free text
              for the log
          target_env:
            type: environment
          "bad key!":
            type: string
    jobs:
      deploy:
        runs-on: ubuntu-latest
        steps:
          - run: echo hi
    """

    @Test func readsInputsInOrder() throws {
        let spec = try #require(try DispatchSpec.parse(workflowYAML: workflow))
        #expect(spec.inputs.map(\.key) == ["environment", "dry_run", "replicas", "note", "target_env"])
        let env = spec.inputs[0]
        #expect(env.kind == .choice(["staging", "production"]))
        #expect(env.required)
        #expect(env.description == "Where to deploy")
        #expect(env.initialValue == "staging")
        #expect(spec.inputs[1].kind == .boolean)
        #expect(spec.inputs[1].initialValue == "true")
        #expect(spec.inputs[2].kind == .number)
        #expect(spec.inputs[3].description == "Free text for the log")
        #expect(spec.inputs[4].kind == .environment)
    }

    @Test func otherTriggerShapes() throws {
        #expect(try DispatchSpec.parse(workflowYAML: "on: workflow_dispatch\njobs: {}") == DispatchSpec(inputs: []))
        #expect(try DispatchSpec.parse(workflowYAML: "on: [push, workflow_dispatch]") == DispatchSpec(inputs: []))
        #expect(try DispatchSpec.parse(workflowYAML: "\"on\":\n  workflow_dispatch:\n") == DispatchSpec(inputs: []))
        #expect(try DispatchSpec.parse(workflowYAML: "on:\n  push:\n") == nil)
        #expect(try DispatchSpec.parse(workflowYAML: "on: push") == nil)
        #expect(try DispatchSpec.parse(workflowYAML: "name: no trigger") == nil)
    }

    @Test func choiceWithoutOptionsIsSkipped() throws {
        let spec = try DispatchSpec.parse(workflowYAML: """
        on:
          workflow_dispatch:
            inputs:
              broken:
                type: choice
              fine:
                default: x
        """)
        #expect(spec?.inputs.map(\.key) == ["fine"])
    }

    @Test func valuesAreCheckedBeforeSending() throws {
        let spec = try #require(try DispatchSpec.parse(workflowYAML: workflow))
        let values = try spec.values(from: ["environment": "production", "replicas": "5"])
        #expect(values == ["environment": "production", "dry_run": "true", "replicas": "5"])

        #expect(throws: GitHubError.invalidInput("environment is required.")) {
            try spec.values(from: ["environment": ""])
        }
        #expect(throws: GitHubError.invalidInput("replicas must be a number.")) {
            try spec.values(from: ["replicas": "many"])
        }
        #expect(throws: GitHubError.invalidInput("environment must be one of the listed options.")) {
            try spec.values(from: ["environment": "moon"])
        }
    }
}

@Suite struct DispatchOptionsTests {
    let options = DispatchOptions(
        workflows: [makeWorkflow(id: 1), makeWorkflow(id: 2, state: "disabled_manually")],
        branches: ["feature/release-notes", "main", "release/2.0"],
        tags: ["v1.0", "release-2.0", "v2.0"]
    )

    @Test func branchesThenTagsAndMainSuggested() {
        #expect(options.workflows.map(\.id) == [1])
        #expect(options.refs.count == 6)
        #expect(options.refs.prefix(3).allSatisfy { $0.kind == .branch })
        #expect(options.suggestedRef == GitRef(kind: .branch, name: "main"))
    }

    @Test func searchCoversBranchesAndTagsPrefixFirst() {
        let hits = options.refs(matching: "RELEASE")
        #expect(hits.map(\.name) == ["release/2.0", "release-2.0", "feature/release-notes"])
        #expect(options.refs(matching: "v2").map(\.name) == ["v2.0"])
        #expect(options.refs(matching: "  ").count == 6)
    }

    @Test func tagOnlyRepoSuggestsATag() {
        #expect(DispatchOptions(workflows: [], branches: [], tags: ["v1"]).suggestedRef == GitRef(kind: .tag, name: "v1"))
    }
}
