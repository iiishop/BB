import XCTest

final class MacOSAuthSmokeTests: XCTestCase {
    @MainActor
    func testRegistrationAndLogin() throws {
        continueAfterFailure = false
        let settingsURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "settings", withExtension: "json")
        )
        let settings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: settingsURL))
        let appURL = URL(fileURLWithPath: try XCTUnwrap(settings["app"]))
        let serverAddress = try XCTUnwrap(settings["server"])
        let serverLog = URL(fileURLWithPath: try XCTUnwrap(settings["server_log"]))
        let password = "MacSmoke3Test"

        let app = XCUIApplication(url: appURL)
        app.launch()
        defer { app.terminate() }

        // The hosted runner exposes Flutter's native content view only. Drive
        // its shipped 800 × 600 desktop window with pointer and keyboard input.
        let content = app.windows.firstMatch.groups.firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(content.frame.size, CGSize(width: 800, height: 600))

        func click(_ x: Double, _ y: Double) {
            content.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        }

        func enter(_ text: String) {
            app.typeText(text)
            app.typeKey(.return, modifierFlags: [])
        }

        func expectResponse(_ request: String, status: Int) {
            let received = NSPredicate { _, _ in
                let log = try? String(contentsOf: serverLog, encoding: .utf8)
                return log?.contains("\"POST \(request) HTTP/1.1\" \(status) ") == true
            }
            let response = XCTNSPredicateExpectation(predicate: received, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [response], timeout: 20), .completed, request)
        }

        click(0.50, 0.48) // Server address.
        enter(serverAddress)
        for _ in 0..<5 { app.typeKey(.tab, modifierFlags: []) }
        app.typeKey(.space, modifierFlags: []) // Registration link.
        click(0.50, 0.48) // Username.
        enter("MacSandboxSmoke")
        enter(password)
        enter(password)
        expectResponse("/auth/register", status: 201)

        click(0.50, 0.77) // Continue with the assigned account.
        click(0.50, 0.61) // Login password.
        enter(password)
        expectResponse("/auth/login", status: 200)
    }
}
