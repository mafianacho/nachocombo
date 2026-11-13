import AppKit
import NachoComboCore

/// Nacho Pet settings: what Nacho may do on this Mac (with the Accessibility state) and the saved workspaces, each with
/// a Delete button. Workspaces are saved and put back from the chat ("업무 모드 저장해 줘"); here they are only listed
/// and removed.
final class PetWorkspaceSettingsSection: NSObject {
    let view = NSStackView()
    var openAccessibility: (() -> Void)?

    private let desktop: PetDesktopActions
    private let width: CGFloat
    private let permissionLine: NSTextField
    private let permissionButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    private let list = NSStackView()
    private let empty: NSTextField
    private var names: [String] = []

    init(desktop: PetDesktopActions, width: CGFloat) {
        self.desktop = desktop
        self.width = width
        permissionLine = UI.wrapLabel("", width: width, style: .caption1, color: UI.secondaryText)
        empty = UI.wrapLabel("No workspace yet. Ask Nacho: \"지금 화면을 업무 모드로 저장해 줘\".", width: width,
                             style: .caption1, color: UI.secondaryText)
        super.init()
        build()
        refresh()
    }

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        permissionLine.setAccessibilityIdentifier("pet-desktop-permission")
        permissionButton.target = self
        permissionButton.action = #selector(permissionClicked)
        permissionButton.setAccessibilityIdentifier("pet-desktop-permission-open")
        view.addArrangedSubview(permissionLine)
        view.addArrangedSubview(permissionButton)

        view.addArrangedSubview(UI.sectionTitle("Workspaces"))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.setAccessibilityIdentifier("pet-workspaces")
        view.addArrangedSubview(list)
        view.addArrangedSubview(empty)
    }

    func refresh() {
        let trusted = desktop.isTrusted()
        permissionLine.stringValue = trusted
            ? "Accessibility: allowed. Nacho can list, move and arrange windows and save workspaces."
            : "Accessibility: not allowed. Nacho can open, switch and hide apps, but cannot list or move windows or save "
                + "workspaces until Nacho Combo is switched on in Privacy & Security > Accessibility."
        permissionButton.isHidden = trusted

        let workspaces = desktop.store.workspaces
        guard workspaces.map({ $0.name }) != names || list.arrangedSubviews.count != workspaces.count else { return }
        names = workspaces.map { $0.name }
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for (index, w) in workspaces.enumerated() {
            let title = UI.wrapLabel(w.name, width: width - 110, style: .callout, color: .labelColor)
            let detail = UI.wrapLabel("\(w.summary) · \(formatter.string(from: w.savedAt))", width: width - 110,
                                      style: .caption1, color: UI.secondaryText)
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteClicked(_:)))
            delete.tag = index
            delete.setAccessibilityIdentifier("pet-workspace-delete-\(index)")
            delete.setAccessibilityLabel("Delete workspace \(w.name)")
            list.addArrangedSubview(UI.hstack([text, UI.spacer(), delete], spacing: 8))
        }
        empty.isHidden = !workspaces.isEmpty
    }

    @objc private func permissionClicked() { openAccessibility?() }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard names.indices.contains(sender.tag) else { return }
        desktop.deleteWorkspace(named: names[sender.tag])
        refresh()
    }
}
