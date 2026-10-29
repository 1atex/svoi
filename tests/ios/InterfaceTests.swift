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
    app.buttons["selected-server"].tap()
    let next = app.buttons["server-nl"]
    for _ in 0..<5 where !next.isHittable { app.swipeUp() }
    XCTAssertTrue(next.waitForExistence(timeout: 5))
    capture("03-servers")
    next.tap()
    XCTAssertTrue(app.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["vpn-toggle"].label, "Переключить VPN на выбранный сервер")
    app.buttons["vpn-toggle"].tap()
    XCTAssertEqual(app.buttons["vpn-toggle"].label, "Отключить VPN")
    app.buttons["vpn-toggle"].tap()
    XCTAssertTrue(app.staticTexts["VPN выключен"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.tabBars.buttons.count, 3)
    app.tabBars.buttons["Настройки"].tap()
    app.buttons["settings-profile"].tap()
    XCTAssertTrue(app.staticTexts["Свои — рядом."].waitForExistence(timeout: 5))
    capture("04-profile")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    for _ in 0..<4 where !app.buttons["Тема Лунная"].isHittable { app.swipeUp() }
    XCTAssertTrue(app.buttons["Тема Лунная"].waitForExistence(timeout: 5))
    app.buttons["Тема Лунная"].tap()
    capture("05-settings")
    app.buttons["Тема SVOI"].tap()
  }

  func testSubscriptionCollapseAndRemoval() {
    let app = launch(["--connected", "--reset-collapse"])
    app.buttons["selected-server"].tap()
    let toggle = app.buttons["subscription-toggle-demo"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
    toggle.tap()
    XCTAssertFalse(app.buttons["server-fi"].exists)
    capture("18-collapsed-subscription")
    toggle.tap()
    XCTAssertTrue(app.buttons["server-fi"].waitForExistence(timeout: 5))
    app.buttons["subscription-delete-demo"].tap()
    XCTAssertTrue(app.alerts.buttons["Удалить подписку"].waitForExistence(timeout: 5))
    capture("20-delete-confirmation")
    app.alerts.buttons["Отмена"].tap()
    XCTAssertTrue(app.buttons["server-fi"].exists)
    app.buttons["subscription-delete-demo"].tap()
    app.alerts.buttons["Удалить подписку"].tap()
    let welcome = app.buttons["welcome-import"]
    for _ in 0..<4 where !welcome.isHittable { app.swipeDown() }
    XCTAssertTrue(welcome.waitForExistence(timeout: 5))
    capture("19-removed-subscription")
  }

  func testConnectionDetailsAreOpenedOnDemand() {
    let app = launch()
    let details = app.buttons["connection-details"]
    XCTAssertTrue(details.isHittable)
    XCTAssertFalse(app.staticTexts["IP без подключения SVOI"].exists)
    details.tap()
    XCTAssertTrue(app.staticTexts["IP без подключения SVOI"].waitForExistence(timeout: 5))
    capture("21-connection-details")
    app.buttons["Готово"].tap()
    XCTAssertTrue(app.buttons["vpn-toggle"].isHittable)
    app.buttons["vpn-toggle"].tap()
    app.buttons["connection-details"].tap()
    XCTAssertTrue(app.staticTexts["IP изменился после подключения"].waitForExistence(timeout: 5))
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
    XCTAssertTrue(restored.staticTexts["speed-route-explanation"].exists)
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

  func testInterfaceIconStylesPersist() {
    let app = launch()
    app.tabBars.buttons["Настройки"].tap()
    let choice = app.segmentedControls["icon-style"].buttons["Двухцветные"]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    choice.tap()
    capture("15-duotone-settings")
    app.tabBars.buttons["Инструменты"].tap()
    capture("16-duotone-tools")
    app.terminate()
    let restored = launch()
    restored.tabBars.buttons["Настройки"].tap()
    XCTAssertTrue(restored.segmentedControls["icon-style"].buttons["Двухцветные"].isSelected)
    restored.segmentedControls["icon-style"].buttons["Контурные"].tap()
    restored.tabBars.buttons["Подключение"].tap()
    capture("17-outline-connection")
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
    app.buttons["selected-server"].tap()
    let search = app.textFields["server-search"]
    for _ in 0..<5 where !search.isHittable { app.swipeUp() }
    XCTAssertTrue(search.isHittable)
    capture("22-accessibility-subscriptions")
    app.tabBars.buttons["Настройки"].tap()
    for _ in 0..<4 where !app.buttons["Тема SVOI"].isHittable { app.swipeUp() }
    XCTAssertTrue(app.buttons["Тема SVOI"].waitForExistence(timeout: 5))
    capture("09-accessibility-settings")
    app.terminate()
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = launch()
    XCTAssertTrue(landscape.buttons["vpn-toggle"].waitForExistence(timeout: 5))
    capture("10-landscape")
  }
}
