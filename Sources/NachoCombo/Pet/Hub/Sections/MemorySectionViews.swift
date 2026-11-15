import AppKit
import NachoComboCore

/// 기억 섹션의 작은 화면 부품: 여러 줄 입력, 사실·추억 양식, 되돌리기 막대. 색·크기는 PetTheme/PetTokens만 쓴다.
enum MemoryUI {
    /// 여러 줄로 감기는 입력 칸(긴 기억·추억 내용).
    static func multiline(_ f: HubFormField, minHeight: CGFloat) {
        f.field.usesSingleLineMode = false
        f.field.maximumNumberOfLines = 0
        f.field.lineBreakMode = .byWordWrapping
        f.field.cell?.wraps = true
        f.field.cell?.isScrollable = false
        f.field.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: NSLayoutConstraint.Orientation.horizontal)
        return v
    }
}

/// 사실 추가·고치기 양식. 저장 전에 앱 검증 규칙(1–4000자, 빈 값 금지)을 거치고, 서버 오류는 칸 아래에 한국어로 보여 준다.
final class MemoryFactForm: NSView {
    let text = HubFormField(title: "내용", placeholder: "나초에게 알려 줄 것", validator: HubMemoryRules.factTextProblem)
    let category = NSPopUpButton(frame: .zero, pullsDown: false)
    let share = NSButton(checkboxWithTitle: "모든 나초와 함께 쓰기", target: nil, action: nil)
    private let save: PetPill
    private let cancel: PetPill
    var onSave: ((_ text: String, _ category: String, _ shared: Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, text initial: String, category initialCategory: String, shared: Bool, shareLocked: Bool) {
        save = HubKit.primaryButton("저장") {}
        cancel = HubKit.secondaryButton("취소") {}
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        text.field.stringValue = initial
        MemoryUI.multiline(text, minHeight: 90)
        category.translatesAutoresizingMaskIntoConstraints = false
        category.addItems(withTitles: HubMemoryCategory.all.map { $0.title })
        category.selectItem(at: HubMemoryCategory.all.firstIndex { $0.id == initialCategory } ?? HubMemoryCategory.all.count - 1)
        share.state = shared ? .on : .off
        share.isEnabled = !shareLocked
        share.translatesAutoresizingMaskIntoConstraints = false
        save.onClick = { [weak self] in self?.submit() }
        cancel.onClick = { [weak self] in self?.onCancel?() }
        let heading = HubKit.label(title, font: PetTheme.title)
        let catLabel = HubKit.label("분류", font: PetTheme.caption, color: PetTheme.secondary)
        let stack = HubKit.vstack([heading, text, catLabel, category, share, HubKit.hstack([cancel, save])], spacing: Double(PetTokens.Space.m))
        HubKit.pin(stack, in: self, inset: Double(PetTokens.Space.l))
        HubKit.fill(stack, [heading, text])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selectedCategory: String {
        let i = max(0, category.indexOfSelectedItem)
        return HubMemoryCategory.all[min(i, HubMemoryCategory.all.count - 1)].id
    }

    /// 검증을 통과하면 `onSave`를 부른다. 통과 못 하면 문구를 보여 주고 아무것도 보내지 않는다.
    func submit() {
        guard text.validate() else { return }
        onSave?(text.value, selectedCategory, share.state == .on)
    }

    func setBusy(_ busy: Bool) {
        save.isEnabled = !busy
        cancel.isEnabled = !busy
    }
}

/// 추억 고치기 양식(제목 1–100자, 내용 ≤20000자).
final class MemoryEpisodeForm: NSView {
    let title = HubFormField(title: "제목", validator: HubFormField.nonEmpty("제목", maxLength: HubMemoryRules.titleMax))
    let content = HubFormField(title: "내용", validator: HubFormField.nonEmpty("내용", maxLength: HubMemoryRules.contentMax))
    private let problem = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
    private let save: PetPill
    private let cancel: PetPill
    var onSave: ((_ title: String, _ content: String) -> Void)?
    var onCancel: (() -> Void)?

    init(title initialTitle: String, content initialContent: String) {
        save = HubKit.primaryButton("저장") {}
        cancel = HubKit.secondaryButton("취소") {}
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.field.stringValue = initialTitle
        content.field.stringValue = initialContent
        MemoryUI.multiline(content, minHeight: 160)
        problem.isHidden = true
        save.onClick = { [weak self] in self?.submit() }
        cancel.onClick = { [weak self] in self?.onCancel?() }
        let heading = HubKit.label("추억 고치기", font: PetTheme.title)
        let stack = HubKit.vstack([heading, title, content, problem, HubKit.hstack([cancel, save])], spacing: Double(PetTokens.Space.m))
        HubKit.pin(stack, in: self, inset: Double(PetTokens.Space.l))
        HubKit.fill(stack, [heading, title, content, problem])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func submit() {
        let t = title.value, c = content.value
        // 앱과 같은 문구: 둘 중 하나라도 비면 「제목과 내용을 모두 써 주세요.」
        if let p = HubMemoryRules.episodeProblem(title: t, content: c) {
            problem.stringValue = p
            problem.isHidden = false
            return
        }
        problem.isHidden = true
        onSave?(t, c)
    }

    func showServerError(_ text: String) {
        problem.stringValue = text
        problem.isHidden = false
    }

    func setBusy(_ busy: Bool) {
        save.isEnabled = !busy
        cancel.isEnabled = !busy
    }
}

/// 잊은 뒤 10초 동안 보이는 「되돌리기」 막대.
final class MemoryUndoBar: PetBox {
    let undo: PetPill

    init(text: String, onUndo: @escaping () -> Void) {
        undo = HubKit.secondaryButton("되돌리기", symbol: "arrow.uturn.backward", onClick: onUndo)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = PetTheme.color(\.tooltip)
        radius = CGFloat(PetTokens.Radius.chip)
        let l = HubKit.label(text, color: PetTheme.color(\.onTooltip), wrap: false)
        let row = HubKit.hstack([l, undo], spacing: Double(PetTokens.Space.m))
        addSubview(row)
        let h = CGFloat(PetTokens.Space.l), v = CGFloat(PetTokens.Space.s)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: h),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -h),
            row.topAnchor.constraint(equalTo: topAnchor, constant: v),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -v),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
