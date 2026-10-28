import XCTest

final class InterfaceTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  override func tearDown() { XCUIDevice.shared.orientation = .portrait }

  private func launch(_ arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"] + arguments
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Подключение"].waitForExistence(timeout: 15))
    return app
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testConnectionAndServerSelection() {
    let app = launch()
    let power = app.buttons["vpn-toggle"]
    XCTAssertTrue(power.waitForExistence(timeout: 5))
    XCTAssertTrue(power.isHittable)
    XCTAssertGreaterThanOrEqual(power.frame.width, 44)
    XCTAssertGreaterThanOrEqual(power.frame.height, 44)
    capture("01-connection")
    power.tap()
    XCTAssertTrue(app.staticTexts["VPN включён"].waitForExistence(timeout: 5))
    capture("02-connected")
    app.tabBars.buttons["Серверы"].tap()
    let next = app.buttons["server-nl"]
    XCTAssertTrue(next.waitForExistence(timeout: 5))
    capture("03-servers")
    next.tap()
    XCTAssertTrue(app.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["vpn-toggle"].label, "Переключить VPN на выбранный сервер")
    app.buttons["vpn-toggle"].tap()
    XCTAssertEqual(app.buttons["vpn-toggle"].label, "Отключить VPN")
    app.buttons["vpn-toggle"].tap()
    XCTAssertTrue(app.staticTexts["VPN выключен"].waitForExistence(timeout: 5))
    app.tabBars.buttons["Профиль"].tap()
    XCTAssertTrue(app.staticTexts["Свои — рядом."].waitForExistence(timeout: 5))
    capture("04-profile")
    app.tabBars.buttons["Настройки"].tap()
    XCTAssertTrue(app.buttons["Тема Лунная"].waitForExistence(timeout: 5))
    app.buttons["Тема Лунная"].tap()
    capture("05-settings")
    app.buttons["Тема SVOI"].tap()
  }

  func testFirstRunImportIsImmediatelyAvailable() {
    let app = launch(["--empty"])
    let add = app.buttons["welcome-import"]
    XCTAssertTrue(add.isHittable)
    capture("06-first-run")
    add.tap()
    XCTAssertTrue(app.textViews["import-text"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["confirm-import"].isEnabled)
    capture("07-import")
    app.buttons["Отмена"].tap()
    XCTAssertTrue(add.waitForExistence(timeout: 5))
  }

  func testLargeTextAndLandscape() {
    let app = launch(["--large-type"])
    XCTAssertTrue(app.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    capture("08-accessibility-text")
    app.swipeUp()
    app.tabBars.buttons["Настройки"].tap()
    XCTAssertTrue(app.buttons["Тема SVOI"].waitForExistence(timeout: 5))
    capture("09-accessibility-settings")
    app.terminate()
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = launch()
    XCTAssertTrue(landscape.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    capture("10-landscape")
  }
}
