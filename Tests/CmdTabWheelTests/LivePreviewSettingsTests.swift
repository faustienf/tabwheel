import AppKit
import Testing
@testable import CmdTabWheel

@MainActor
struct LivePreviewSettingsTests {
    private func isolatedDefaults() -> (String, UserDefaults) {
        let suite = "com.faustienf.CmdTabWheel.LivePreviewTests." + UUID().uuidString
        return (suite, UserDefaults(suiteName: suite)!)
    }

    @Test func livePreviewIsOnUnlessTurnedOff() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LivePreviewSettings(defaults: defaults).isEnabled)
    }

    @Test func bothChoicesPersistAndOnlyChangesNotifyTheCaptureController() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LivePreviewSettings(defaults: defaults)
        var changes: [Bool] = []
        settings.onChange = { changes.append($0) }
        settings.setEnabled(true)
        #expect(changes.isEmpty)
        settings.setEnabled(false)
        settings.setEnabled(false)
        #expect(!LivePreviewSettings(defaults: defaults).isEnabled)
        #expect(changes == [false])
        settings.setEnabled(true)
        #expect(LivePreviewSettings(defaults: defaults).isEnabled)
        #expect(changes == [false, true])
    }

    @Test func theTraySwitchUpdatesAndPersistsTheSetting() throws {
        _ = NSApplication.shared
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LivePreviewSettings(defaults: defaults)
        let item = settings.makeMenuItem()
        let view = try #require(item.view as? SwitchMenuItemView)
        let toggle = try #require(view.subviews.compactMap { $0 as? NSSwitch }.first)
        var changes: [Bool] = []
        settings.onChange = { changes.append($0) }
        #expect(view.isOn)
        toggle.state = .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        #expect(!settings.isEnabled && !LivePreviewSettings(defaults: defaults).isEnabled)
        toggle.state = .on
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        #expect(settings.isEnabled && LivePreviewSettings(defaults: defaults).isEnabled)
        #expect(changes == [false, true])
    }
}
