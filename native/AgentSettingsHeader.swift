import AppKit

@MainActor final class AgentSettingsHeader: NSView {
    private enum Arrangement { case titleOnly, inline, stacked }
    private let title: NSStackView, heading: NSTextField, spacer: NSView, actions: NSStackView
    private var titleOnly: [NSLayoutConstraint] = [], inline: [NSLayoutConstraint] = [], stacked: [NSLayoutConstraint] = []
    private var arrangement: Arrangement = .titleOnly

    init(title: NSStackView, heading: NSTextField, spacer: NSView, actions: NSStackView) {
        self.title = title; self.heading = heading; self.spacer = spacer; self.actions = actions
        super.init(frame: .zero)
        for view in [title, actions] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        let fullTitle = title.trailingAnchor.constraint(equalTo: trailingAnchor)
        let titleBottom = bottomAnchor.constraint(equalTo: title.bottomAnchor)
        titleOnly = [fullTitle, titleBottom, actions.centerYAnchor.constraint(equalTo: title.centerYAnchor)]
        inline = [title.trailingAnchor.constraint(equalTo: actions.leadingAnchor),
                  actions.centerYAnchor.constraint(equalTo: title.centerYAnchor), titleBottom]
        stacked = [fullTitle, actions.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
                   bottomAnchor.constraint(equalTo: actions.bottomAnchor)]
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            actions.heightAnchor.constraint(equalToConstant: 28)
        ] + titleOnly)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = bounds.width != newSize.width
        super.setFrameSize(newSize)
        if resized { needsUpdateConstraints = true }
    }

    override func updateConstraints() {
        let next = fittingArrangement()
        if next != arrangement {
            NSLayoutConstraint.deactivate(constraints(for: arrangement))
            NSLayoutConstraint.activate(constraints(for: next))
            arrangement = next
        }
        super.updateConstraints()
    }

    private func constraints(for arrangement: Arrangement) -> [NSLayoutConstraint] {
        switch arrangement {
        case .titleOnly: return titleOnly
        case .inline: return inline
        case .stacked: return stacked
        }
    }

    private func fittingArrangement() -> Arrangement {
        guard !actions.isHidden, !actions.arrangedSubviews.isEmpty else { return .titleOnly }
        let items = title.arrangedSubviews.filter { !$0.isHidden }
        let titleWidth = items.reduce(title.edgeInsets.left + title.edgeInsets.right) { width, item in
            if item === spacer { return width }
            if item === heading { return width + min(160, heading.intrinsicContentSize.width) }
            if item.identifier?.rawValue == "settings-editing-context" { return width + min(96, item.intrinsicContentSize.width) }
            return width + item.fittingSize.width
        } + title.spacing * CGFloat(max(0, items.count - 1))
        // Reserve room for actions that can appear after a preview or an error.
        let actionWidth = actions.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.fittingSize.width } +
            actions.spacing * CGFloat(max(0, actions.arrangedSubviews.count - 1))
        return titleWidth + actionWidth + 16 <= bounds.width + 0.5 ? .inline : .stacked
    }
}
