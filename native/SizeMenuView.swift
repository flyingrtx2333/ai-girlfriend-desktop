import AppKit

@MainActor final class SizeMenuView: NSView {
    let slider: NSSlider
    private let percentage = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Double

    init(value: Double, onChange: @escaping (Double) -> Double) {
        slider = NSSlider(value: value, minValue: 0.5, maxValue: 1.5, target: nil, action: nil)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 188, height: 56))
        let title = NSTextField(labelWithString: "大小")
        title.font = .menuFont(ofSize: 13); title.frame = NSRect(x: 16, y: 33, width: 100, height: 18)
        percentage.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentage.textColor = AgentWorkbenchTheme.secondaryText; percentage.alignment = .right
        percentage.frame = NSRect(x: 120, y: 33, width: 52, height: 18)
        slider.frame = NSRect(x: 14, y: 5, width: 160, height: 24)
        slider.isContinuous = true; slider.target = self; slider.action = #selector(changed)
        slider.setAccessibilityLabel("角色大小")
        addSubview(title); addSubview(percentage); addSubview(slider); updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func changed() { slider.doubleValue = onChange(slider.doubleValue); updateLabel() }
    func setValue(_ value: Double) { slider.doubleValue = value; updateLabel() }
    private func updateLabel() { percentage.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%" }
}
