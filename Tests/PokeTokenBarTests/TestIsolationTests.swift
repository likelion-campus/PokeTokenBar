import XCTest

/// CI는 Xcode 16.4(Swift 6.1)로 컴파일한다. 그 SDK에서 `XCTestCase`의 동기 `setUp()`/`tearDown()`은 비격리라,
/// `@MainActor` 테스트 클래스의 동기 override가 격리된 프로퍼티나 메서드를 만지면 CI에서만 컴파일이 깨진다
/// (Xcode 26.5의 로컬 컴파일러는 통과시킨다). 저장소 관용구: 동기 override가 쓰는 프로퍼티는 `nonisolated(unsafe)`로 둔다.
/// defect-log "빌드·도구체인" 참고.
final class TestIsolationTests: XCTestCase {
    func testSynchronousSetUpAndTearDownInMainActorTestsTouchOnlyUnsafeState() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // PokeTokenBarTests
        let files = try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TestIsolationTests.swift" }   // 아래 예시 문자열은 빼고
        var offenders: [String] = []
        for url in files {
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            offenders += Self.offenders(in: lines, file: url.lastPathComponent)
        }
        XCTAssertTrue(offenders.isEmpty, """
            A synchronous setUp()/tearDown() in a @MainActor XCTestCase is nonisolated on CI's Xcode 16.4, so it can't touch \
            isolated members. Mark the member nonisolated(unsafe), drop the override, or make it `async throws`: \
            \(offenders.joined(separator: ", "))
            """)
    }

    /// 검사기 자체가 동기 override 안의 격리된 멤버를 잡고, `nonisolated(unsafe)`와 async override는 넘기는지 확인한다.
    func testTheScanFlagsIsolatedMembersOnly() {
        let bad = """
            @MainActor
            final class A: XCTestCase {
                private var clock: Double = 0
                nonisolated(unsafe) private var suites: [String] = []
                private func reset() {}
                override func setUp() { clock = 0 }
                override func tearDown() { suites = []; reset() }
            }
            """.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Self.offenders(in: bad, file: "A.swift"), ["A.swift:6 clock", "A.swift:7 reset"])

        let good = """
            @MainActor final class B: XCTestCase {
                private var clock: Double = 0
                nonisolated(unsafe) private var suites: [String] = []
                override func setUp() async throws { clock = 0 }
                override func tearDown() { suites = [] }
            }
            final class C: XCTestCase {
                private var clock: Double = 0
                override func setUp() { clock = 0 }
            }
            """.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Self.offenders(in: good, file: "B.swift"), [])
    }

    /// `@MainActor` XCTestCase마다 클래스 바로 아래 단계의 격리된 `var`/`func` 이름을 모으고,
    /// 같은 단계의 동기 `setUp()`/`tearDown()` 본문이 그 이름을 쓰면 "파일:줄 이름"으로 돌려준다.
    static func offenders(in lines: [String], file: String) -> [String] {
        let memberPattern = try! NSRegularExpression(pattern: #"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|class|final|lazy|weak|override|nonisolated\(unsafe\)|nonisolated)\s+)*(var|func)\s+(\w+)"#)
        let syncOverride = try! NSRegularExpression(pattern: #"override\s+func\s+(setUp|tearDown)\(\)\s*(throws\s*)?\{"#)
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let previous = lines[..<index].reversed().map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            guard trimmed.contains("class "), trimmed.contains(": XCTestCase"),
                  trimmed.contains("@MainActor") || previous == "@MainActor" else { index += 1; continue }
            // 클래스 본문을 중괄호로 잘라, 줄마다 그 줄이 시작할 때의 깊이를 적는다(클래스 안 첫 단계 = 1).
            var depth = 0, started = false, end = index
            var startDepth: [Int: Int] = [:]
            for j in index..<lines.count {
                startDepth[j] = depth
                for ch in lines[j] {
                    if ch == "{" { depth += 1; started = true } else if ch == "}" { depth -= 1 }
                }
                end = j
                if started && depth == 0 { break }
            }
            var isolated = Set<String>()
            for j in (index + 1)..<end where startDepth[j] == 1 {
                let text = lines[j]
                let range = NSRange(text.startIndex..., in: text)
                guard let m = memberPattern.firstMatch(in: text, range: range),
                      let name = Range(m.range(at: 2), in: text).map({ String(text[$0]) }) else { continue }
                if text.contains("nonisolated") || ["setUp", "tearDown"].contains(name) { continue }
                isolated.insert(name)
            }
            for j in (index + 1)..<end where startDepth[j] == 1 {
                let text = lines[j]
                guard syncOverride.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
                // 본문: 이 줄의 `{` 뒤부터 깊이가 1로 돌아올 때까지.
                var body = "", d = 1, opened = false, k = j
                outer: while k < end {
                    for ch in lines[k] {
                        if ch == "{" { d += 1; if d == 2 { opened = true; continue } }
                        if ch == "}" { d -= 1; if opened && d == 1 { break outer } }
                        if opened { body.append(ch) }
                    }
                    body.append("\n"); k += 1
                }
                for name in isolated.sorted()
                where body.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil {
                    result.append("\(file):\(j + 1) \(name)")
                }
            }
            index = end + 1
        }
        return result
    }
}
