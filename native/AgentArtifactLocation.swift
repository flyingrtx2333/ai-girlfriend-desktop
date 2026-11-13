import AppKit

enum AgentArtifactLocation: String, Codable, CaseIterable {
    case workspace, window
    var title: String { self == .workspace ? "在右侧栏查看" : "新窗口查看" }
    static func menu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for location in allCases {
            let item = NSMenuItem(title: location.title, action: action, keyEquivalent: "")
            item.target = target; item.representedObject = location.rawValue; menu.addItem(item)
        }
        return menu
    }
}
