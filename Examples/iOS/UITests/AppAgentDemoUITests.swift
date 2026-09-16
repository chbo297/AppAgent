//
//  AppAgentDemoUITests.swift
//  End-to-end UI verification for the AppAgent demo:
//  drives the real input box, sends a message, and waits for the
//  live agent (OneAPI provider) reply to render in the chat panel.
//

import XCTest

final class AppAgentDemoUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testInputBoxSendsAndAgentReplies() throws {
        let app = XCUIApplication(bundleIdentifier: "com.appagent.demo")
        app.launch()

        // 1) Chat panel + input box must render (overlay mounts asynchronously).
        let inputField = app.textFields.firstMatch
        XCTAssertTrue(
            inputField.waitForExistence(timeout: 25),
            "Input text field of the chat panel did not appear"
        )
        attachScreenshot(app, name: "01-panel-rendered")

        // 2) Focus the input box and type a prompt whose answer token
        //    ("384") does NOT appear in the prompt itself, so we can
        //    unambiguously detect the agent's reply.
        inputField.tap()
        inputField.typeText("计算 128 加 256 等于多少，只回复数字")
        attachScreenshot(app, name: "02-typed")

        // Return triggers textFieldShouldReturn -> didSendText (send).
        inputField.typeText("\n")

        // 3) Wait for the live agent reply to stream into the chat panel.
        let reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "384")
        ).firstMatch
        let appeared = reply.waitForExistence(timeout: 120)
        attachScreenshot(app, name: appeared ? "03-agent-replied" : "03-no-reply")
        XCTAssertTrue(appeared, "Agent reply containing '384' did not appear in the chat panel")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
