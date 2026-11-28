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
        let password = "MacSmoke3Test"

        let app = XCUIApplication(url: appURL)
        app.launch()
        defer { app.terminate() }

        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 25), app.debugDescription)
        address.click()
        address.typeText(serverAddress)
        app.typeKey(.return, modifierFlags: [])

        let registerLink = app.buttons["注册"].firstMatch
        XCTAssertTrue(registerLink.waitForExistence(timeout: 15), app.debugDescription)
        registerLink.click()
        let username = app.textFields.firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 10), app.debugDescription)
        username.click()
        username.typeText("MacSandboxSmoke")
        app.typeKey(.return, modifierFlags: [])
        app.typeText(password)
        app.typeKey(.return, modifierFlags: [])
        app.typeText(password)
        app.typeKey(.return, modifierFlags: [])

        let goToLogin = app.buttons["去登录"].firstMatch
        XCTAssertTrue(goToLogin.waitForExistence(timeout: 20), app.debugDescription)
        goToLogin.click()
        let account = app.textFields.firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), app.debugDescription)
        account.click()
        app.typeKey(.return, modifierFlags: [])
        app.typeText(password)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(registerLink.waitForNonExistence(timeout: 20), app.debugDescription)
    }
}
