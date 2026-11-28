import Vision
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

        let window = app.windows.firstMatch
        let content = window.groups.firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(content.frame.size, CGSize(width: 800, height: 600))

        func attach(_ screenshot: XCUIScreenshot, _ name: String) {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // Flutter's controls are absent from the hosted runner's native
        // accessibility tree. Read the rendered window for navigation.
        func locateLabel(_ label: String, click: Bool = false) throws {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let deadline = Date().addingTimeInterval(10)
            repeat {
                let screenshot = window.screenshot()
                try VNImageRequestHandler(data: screenshot.pngRepresentation, options: [:]).perform([request])
                if let match = request.results?.first(where: {
                    $0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "") == label
                }) {
                    if click {
                        let bounds = match.boundingBox
                        window.coordinate(withNormalizedOffset: CGVector(dx: bounds.midX, dy: 1 - bounds.midY)).click()
                    }
                    return
                }
                if Date() >= deadline {
                    attach(screenshot, "Missing control")
                    XCTFail("Could not locate \(label)")
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            } while true
        }

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
            if XCTWaiter.wait(for: [response], timeout: 20) != .completed {
                attach(window.screenshot(), "Missing response")
                XCTFail("Did not receive \(status) for \(request)")
            }
        }

        click(0.50, 0.48) // Server address.
        app.typeText(serverAddress)
        try locateLabel("连接", click: true)
        try locateLabel("登录")
        click(0.55, 0.91) // Registration link beside its explanatory text.
        try locateLabel("创建账号")
        click(0.50, 0.48) // Username.
        enter("MacSandboxSmoke")
        enter(password)
        enter(password)
        expectResponse("/auth/register", status: 201)

        try locateLabel("去登录", click: true)
        try locateLabel("登录")
        click(0.50, 0.61) // Login password.
        enter(password)
        expectResponse("/auth/login", status: 200)
    }
}
