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
    if !app.buttons["Тема Лунная"].isHittable { app.swipeUp() }
    app.buttons["Тема Лунная"].tap()
    capture("05-settings")
    app.buttons["Тема SVOI"].tap()
  }

  func testAMOLEDAndTools() {
    let app = launch()
    app.tabBars.buttons["Настройки"].tap()
    let amoled = app.segmentedControls["theme-mode"].buttons["AMOLED"]
    XCTAssertTrue(amoled.waitForExistence(timeout: 5))
    amoled.tap()
    app.tabBars.buttons["Подключение"].tap()
    capture("11-amoled")
    app.terminate()
    let restored = launch()
    restored.tabBars.buttons["Настройки"].tap()
    XCTAssertTrue(restored.segmentedControls["theme-mode"].buttons["AMOLED"].isSelected)
    restored.tabBars.buttons["Инструменты"].tap()
    XCTAssertTrue(restored.buttons["tool-speed"].waitForExistence(timeout: 5))
    capture("12-tools")
    restored.buttons["tool-speed"].tap()
    XCTAssertTrue(restored.buttons["speed-start"].waitForExistence(timeout: 5))
    capture("13-speed")
    restored.navigationBars.buttons.element(boundBy: 0).tap()
    restored.buttons["tool-dns"].tap()
    XCTAssertTrue(restored.buttons["dns-start"].waitForExistence(timeout: 5))
    capture("14-dns")
    restored.tabBars.buttons["Подключение"].tap()
    restored.buttons["vpn-toggle"].tap()
    restored.tabBars.buttons["Инструменты"].tap()
    XCTAssertFalse(restored.buttons["dns-start"].isEnabled)
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
    app.terminate()
    let active = launch(["--empty", "--connected"])
    XCTAssertTrue(active.buttons["vpn-toggle"].isHittable)
    XCTAssertEqual(active.buttons["vpn-toggle"].label, "Отключить VPN")
    active.buttons["vpn-toggle"].tap()
    XCTAssertTrue(active.buttons["welcome-import"].waitForExistence(timeout: 5))
  }

  func testLargeTextAndLandscape() {
    let app = launch(["--large-type"])
    XCTAssertTrue(app.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    capture("08-accessibility-text")
    app.swipeUp()
    app.tabBars.buttons["Настройки"].tap()
    if !app.buttons["Тема SVOI"].isHittable { app.swipeUp() }
    XCTAssertTrue(app.buttons["Тема SVOI"].waitForExistence(timeout: 5))
    capture("09-accessibility-settings")
    app.terminate()
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = launch()
    XCTAssertTrue(landscape.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    capture("10-landscape")
  }
}
