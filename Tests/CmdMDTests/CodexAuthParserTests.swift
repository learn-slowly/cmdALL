import XCTest
@testable import CmdMD

final class CodexAuthParserTests: XCTestCase {
    func testParseLoggedInWithChatGPT() {
        let s = CodexAuthParser.parse("Logged in using ChatGPT")
        XCTAssertEqual(s.loggedIn, true)
        XCTAssertEqual(s.method, "ChatGPT")
    }

    func testParseLoggedInWithApiKey() {
        let s = CodexAuthParser.parse("Logged in using an API key")
        XCTAssertEqual(s.loggedIn, true)
        XCTAssertEqual(s.method, "an API key")
    }

    func testParseNotLoggedIn() {
        let s = CodexAuthParser.parse("Not logged in")
        XCTAssertEqual(s.loggedIn, false)
        XCTAssertNil(s.method)
    }

    func testParseEmptyOutputIsLoggedOut() {
        let s = CodexAuthParser.parse("")
        XCTAssertEqual(s.loggedIn, false)
    }

    func testParseTolerateSurroundingTextAndCase() {
        let s = CodexAuthParser.parse("noise\nlogged in using ChatGPT\ntrailing")
        XCTAssertEqual(s.loggedIn, true)
        XCTAssertEqual(s.method, "ChatGPT")
    }

    func testParseUnrecognizedOutputFallsBackToLoggedOut() {
        let s = CodexAuthParser.parse("some unexpected banner text")
        XCTAssertEqual(s.loggedIn, false)
    }
}
