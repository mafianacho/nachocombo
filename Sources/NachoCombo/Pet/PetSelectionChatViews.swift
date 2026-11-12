import AppKit
import NachoComboCore

// The selection bar's pieces in the chat (mockup scenes sel-preview, sel-long, sel-stream, sel-result, sel-intro):
// the preview card `.card.ctx`, the request chip `.reqchip`, the answer actions `.answer-acts`, what was sent, and the
// first-use card. Links go back to the chat window as nachopet://sel… URLs.

private typealias S = PetTokens.Size
private typealias Sp = PetTokens.Space
private typealias Rd = PetTokens.Radius

extension PetItemViews {
    private func cardBox() -> (PetBox, NSStackView) {
        let box = PetBox()
        box.fill = PetTheme.color(\.surfaceRaised)
        box.stroke = PetTheme.color(\.separator)
        box.radius = CGFloat(Rd.card)
        box.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CGFloat(Sp.xs)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: CGFloat(Sp.m)),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -CGFloat(Sp.m)),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: CGFloat(Sp.m)),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -CGFloat(Sp.m)),
        ])
        return (box, stack)
    }

    private var cardInner: CGFloat { width - CGFloat(2 * Sp.m) }

    /// `.q`: accent icon and the request in medium weight.
    private func head(_ symbol: String, _ title: String) -> NSView {
        let icon = NSImageView(image: PetTheme.symbol(symbol, size: S.icon) ?? NSImage())
        icon.contentTintColor = PetTheme.accent
        let t = PetLinkText(PetLinkText.plain(title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium), color: PetTheme.text),
                            maxWidth: cardInner - CGFloat(S.icon + Sp.s))
        let row = NSStackView(views: [icon, t])
        row.alignment = .top
        row.spacing = CGFloat(Sp.s)
        return row
    }

    private func caption(_ s: String, color: NSColor, weight: Double = PetTokens.Font.weightRegular, strike: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        var a: [NSAttributedString.Key: Any] = [.font: PetTheme.font(PetTokens.Font.caption, weight), .foregroundColor: color]
        if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        l.attributedStringValue = NSAttributedString(string: s, attributes: a)
        l.lineBreakMode = .byTruncatingTail
        l.cell?.usesSingleLineMode = true
        return l
    }

    private func linkButton(_ title: String, _ url: URL, label: String? = nil) -> NSView {
        let t = PetLinkText(PetLinkText.text([PetTextPart(title, link: url)], font: PetTheme.caption, color: PetTheme.link), maxWidth: 120)
        t.onLink = onLink
        t.setAccessibilityLabel(label ?? title)
        return t
    }

    /// One `.row2`: icon, label and value (or the quoted selection with 전체 보기 and the cut warning), 빼기/다시 넣기.
    private func contextRow(_ r: PetSelectionRow, editable: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = CGFloat(Sp.s)
        row.alignment = r.field == .selection ? .top : .centerY
        let icon = NSImageView(image: PetTheme.symbol(r.symbol, size: S.contextRowIcon) ?? NSImage())
        icon.contentTintColor = PetTheme.tertiary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: CGFloat(S.contextRowIcon)).isActive = true
        row.addArrangedSubview(icon)
        let buttonWidth: CGFloat = editable ? (r.removed ? 56 : 20) : 0
        let textWidth = cardInner - CGFloat(S.contextRowIcon + Sp.s) - (editable ? buttonWidth + CGFloat(Sp.s) : 0)
        let off = r.removed
        if r.field == .selection {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 2
            let top = NSStackView(views: [caption(r.label, color: off ? PetTheme.tertiary : PetTheme.secondary, weight: PetTokens.Font.weightMedium)])
            top.spacing = CGFloat(Sp.xs)
            if editable, !off { top.addArrangedSubview(linkButton("전체 보기", PetLinks.url("selfull"), label: "고른 글 전체 보기")) }
            col.addArrangedSubview(top)
            if let w = r.warning {
                let warn = NSImageView(image: PetTheme.symbol("exclamationmark.triangle", size: 12) ?? NSImage())
                warn.contentTintColor = PetTheme.color(\.warning)
                let line = NSStackView(views: [warn, caption(w, color: PetTheme.color(\.warning), weight: PetTokens.Font.weightMedium)])
                line.spacing = CGFloat(Sp.xs)
                col.addArrangedSubview(line)
            }
            let q = NSTextField(wrappingLabelWithString: r.value)
            q.font = PetTheme.caption
            q.textColor = off ? PetTheme.tertiary : PetTheme.text
            q.maximumNumberOfLines = 2
            q.cell?.truncatesLastVisibleLine = true
            q.lineBreakMode = .byTruncatingTail
            q.preferredMaxLayoutWidth = textWidth
            q.translatesAutoresizingMaskIntoConstraints = false
            q.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
            col.addArrangedSubview(q)
            col.translatesAutoresizingMaskIntoConstraints = false
            col.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            row.addArrangedSubview(col)
        } else {
            let kv = NSStackView()
            kv.spacing = CGFloat(Sp.s)
            let label = caption(r.label, color: off ? PetTheme.tertiary : PetTheme.secondary, weight: PetTokens.Font.weightMedium)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
            kv.addArrangedSubview(label)
            let value = caption(r.value, color: off ? PetTheme.tertiary : PetTheme.text, strike: off)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            kv.addArrangedSubview(value)
            if off { kv.addArrangedSubview(caption("뺐어요", color: PetTheme.secondary)) }
            else if let n = r.note { kv.addArrangedSubview(caption(n, color: PetTheme.tertiary)) }
            kv.translatesAutoresizingMaskIntoConstraints = false
            kv.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            row.addArrangedSubview(kv)
        }
        if editable {
            let url = PetLinks.url("selrm", ["f": r.field.rawValue])
            if off {
                row.addArrangedSubview(linkButton("다시 넣기", url, label: "\(r.label) 다시 넣기"))
            } else {
                let b = PetPill(symbol: "xmark", iconSize: 9, color: PetTheme.secondary, fill: PetTheme.color(\.surface), height: 20, radius: 10,
                                padding: 0, width: 20)
                b.toolTip = "빼기"
                b.setAccessibilityLabel("\(r.label) 빼기")
                b.onClick = { onLink(url) }
                row.addArrangedSubview(b)
            }
        }
        return row
    }

    /// `.card.ctx`: what will be sent, each row removable, 보내기 / 취소. Nothing has left the Mac yet.
    func selectionPreview(_ p: PetSelectionPreview) -> NSView {
        let (box, stack) = cardBox()
        stack.addArrangedSubview(head(p.action.symbol, p.title))
        stack.setCustomSpacing(CGFloat(Sp.xs + Sp.xxs), after: stack.arrangedSubviews[0])
        for r in p.rows { stack.addArrangedSubview(contextRow(r, editable: !p.sending)) }
        let send = PetPill(title: p.sending ? "보내는 중…" : "보내기", symbol: p.sending ? nil : "arrow.up", iconSize: S.lineIcon,
                           color: p.canSend ? PetTheme.color(\.onAccent) : PetTheme.tertiary,
                           fill: p.canSend ? PetTheme.accent : PetTheme.color(\.surface), height: S.control, radius: Rd.control, padding: Sp.m)
        send.isEnabled = p.canSend
        send.onClick = { onLink(PetLinks.url("selsend")) }
        let cancel = PetPill(title: "취소", fill: PetTheme.color(\.surface), stroke: PetTheme.color(\.separator))
        cancel.isEnabled = !p.sending
        cancel.onClick = { onLink(PetLinks.url("selcancel")) }
        let acts = NSStackView(views: [send, cancel])
        acts.spacing = CGFloat(Sp.s)
        stack.addArrangedSubview(acts)
        stack.setCustomSpacing(CGFloat(Sp.xs), after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        let foot = PetLinkText(PetLinkText.plain("보내기를 누르기 전에는 아무것도 서버로 가지 않아요.", font: PetTheme.caption, color: PetTheme.tertiary),
                               maxWidth: cardInner)
        stack.addArrangedSubview(foot)
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("보낼 내용 미리 보기")
        return box
    }

    /// `.reqchip` under the sent request: which app, how much was selected, how many context rows.
    func requestChip(_ text: String) -> NSView {
        let pill = PetPill(title: text, symbol: "quote.opening", iconSize: 12, font: PetTheme.caption,
                           color: PetTheme.color(\.mineText).withAlphaComponent(0.85), fill: PetTheme.color(\.mineBubble),
                           height: S.chipHeight, radius: Rd.chip, padding: Sp.s)
        pill.isEnabled = false
        pill.setAccessibilityRole(.staticText)
        return PetRow(pill, width: width, trailing: true)
    }

    /// `.answer-acts`: 복사 · 다시 · 보낸 내용 보기.
    func answerActions(_ turnID: String, showingSent: Bool) -> NSView {
        func chip(_ title: String, _ symbol: String, _ action: String) -> NSView {
            let b = PetPill(title: title, symbol: symbol, iconSize: 11, font: PetTheme.caption, color: PetTheme.secondary,
                            fill: PetTheme.color(\.surface), stroke: PetTheme.color(\.separator), height: 22, radius: Rd.chip, padding: Sp.s)
            b.onClick = { onLink(PetLinks.url(action, ["turn": turnID])) }
            return b
        }
        let row = NSStackView(views: [chip("복사", "doc.on.doc", "selcopy"), chip("다시", "arrow.clockwise", "selagain"),
                                      chip(showingSent ? "보낸 내용 닫기" : "보낸 내용 보기", "doc.text", "selshow")])
        row.spacing = CGFloat(Sp.xs)
        return PetRow(row, width: width)
    }

    /// What a request sent (read only), opened from 보낸 내용 보기.
    func sentContext(_ rows: [PetSelectionRow]) -> NSView {
        let (box, stack) = cardBox()
        stack.addArrangedSubview(head("doc.text", "보낸 내용"))
        for r in rows { stack.addArrangedSubview(contextRow(r, editable: false)) }
        return box
    }

    /// First-use card: the bar in small, what it does, 켜기 / 나중에, and that Accessibility is asked once.
    func selectionIntro() -> NSView {
        let (box, stack) = cardBox()
        stack.spacing = CGFloat(Sp.s)
        stack.addArrangedSubview(head("sparkles", "새로 생겼어요: 선택 동작 바"))
        let bar = PetSelectionBarView(mode: .buttons(compact: true), buttons: PetSelectionAction.orderable)
        bar.setAccessibilityElement(false)
        let center = NSStackView(views: [bar])
        center.orientation = .vertical
        center.alignment = .centerX
        center.translatesAutoresizingMaskIntoConstraints = false
        center.widthAnchor.constraint(equalToConstant: cardInner).isActive = true
        center.edgeInsets = NSEdgeInsets(top: CGFloat(Sp.xs), left: 0, bottom: CGFloat(Sp.xs), right: 0)
        stack.addArrangedSubview(center)
        stack.addArrangedSubview(PetLinkText(PetLinkText.plain("아무 앱에서나 글자를 고르면 작은 바가 떠요. 번역·요약·설명을 누르거나 나초에게 바로 물어볼 수 있어요. "
                                                               + "보낼 내용은 보내기 전에 보여 드려요.", font: PetTheme.caption, color: PetTheme.secondary),
                                             maxWidth: cardInner))
        let on = PetPill(title: "켜기", fill: PetTheme.color(\.accentSoft), stroke: PetTheme.accent)
        on.onClick = { onLink(PetLinks.url("selintro", ["a": "on"])) }
        let later = PetPill(title: "나중에", fill: PetTheme.color(\.surface), stroke: PetTheme.color(\.separator))
        later.onClick = { onLink(PetLinks.url("selintro", ["a": "later"])) }
        let opts = NSStackView(views: [on, later])
        opts.spacing = CGFloat(Sp.s)
        stack.addArrangedSubview(opts)
        stack.addArrangedSubview(PetLinkText(PetLinkText.plain("켜면 고른 글을 읽기 위해 손쉬운 사용 권한을 한 번 물어봐요.", font: PetTheme.caption,
                                                               color: PetTheme.tertiary), maxWidth: cardInner))
        return box
    }
}
