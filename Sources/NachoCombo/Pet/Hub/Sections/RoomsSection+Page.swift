import AppKit
import NachoComboCore

/// 받은 파일·문서 페이지 보기(B11): `GET /pages/{id}`(마크다운은 PetLinkText 재사용), `GET /pages/{id}/download`, `GET·DELETE /media/{id}`.
/// 파일을 어디에 둘지는 사용자가 저장 창에서 고른다. 앱이 정하지 않고, 서버가 준 이름은 안전한 이름으로 바꿔 미리 적어 둘 뿐이다.
extension RoomsSection {
    static let pageWidth: CGFloat = 520

    // MARK: 문서 페이지

    func openPage(_ id: String, title: String, back: @escaping () -> Void) {
        guard let client = ctx.client else { showFailure("로그인이 필요해요."); return }
        state.show(.loading)
        call(client, { HubRoomsAPI.pageRequest($0, id: id, bearer: $1) }) { [self] result in
            onMain {
                switch self.decode(result, HubRoomsAPI.decodePage) {
                case let .failure(e):
                    // 지운 문서·남의 문서는 404. 빈 화면 대신 알리고 돌아간다.
                    self.ctx.toast(e.isNotFound ? "지워졌거나 열 수 없는 문서예요." : e.text, true)
                    back()
                case let .success(doc): self.showPage(doc, back: back)
                }
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func showPage(_ doc: HubPageDoc, back: @escaping () -> Void) {
        let backButton = HubKit.secondaryButton("돌아가기", symbol: "chevron.left", onClick: back)
        let save = HubKit.primaryButton("내려받기", symbol: "arrow.down.circle") { [self] in downloadPage(doc) }
        let title = HubKit.label(doc.title, font: PetTheme.title)
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m), inset: Double(PetTokens.Space.l))
        if doc.blocks.isEmpty { parts.stack.addArrangedSubview(HubKit.label("내용이 없어요.", color: PetTheme.secondary)) }
        for b in doc.blocks { parts.stack.addArrangedSubview(pageBlockView(b)) }
        present(screen(header: [HubKit.hstack([backButton, save]), title], body: parts.scroll))
    }

    func rich(_ s: String, font: NSFont = PetTheme.body, color: NSColor = PetTheme.text, width: CGFloat = RoomsSection.pageWidth) -> NSView {
        PetLinkText(PetLinkText.markdown(s, font: font, color: color), maxWidth: width)
    }

    func pageBlockView(_ b: HubPageBlock) -> NSView {
        switch b.type {
        case "heading":
            return rich(b.text ?? "", font: PetTheme.font(PetTokens.Font.title, PetTokens.Font.weightSemibold))
        case "paragraph":
            return rich(b.text ?? "")
        case "list":
            return HubKit.vstack(b.items.map { rich("•  " + $0) }, spacing: Double(PetTokens.Space.xs))
        case "table":
            let rowViews: [NSView] = b.rows.enumerated().map { idx, cells in
                let cellWidth = max(80, RoomsSection.pageWidth / CGFloat(max(1, cells.count)) - 8)
                // 칸마다 같은 너비의 상자에 담아 줄이 달라도 세로로 맞춘다.
                let views: [NSView] = cells.map { c in
                    let text = idx == 0 ? rich(c, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold), width: cellWidth) : rich(c, width: cellWidth)
                    let box = NSView()
                    box.translatesAutoresizingMaskIntoConstraints = false
                    box.addSubview(text)
                    NSLayoutConstraint.activate([
                        box.widthAnchor.constraint(equalToConstant: cellWidth),
                        text.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                        text.topAnchor.constraint(equalTo: box.topAnchor),
                        text.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                    ])
                    return box
                }
                let h = HubKit.hstack(views, spacing: Double(PetTokens.Space.m))
                h.alignment = .top
                return h
            }
            return HubKit.vstack(rowViews, spacing: Double(PetTokens.Space.s))
        case "link":
            if let href = b.href, let u = URL(string: href), let s = u.scheme?.lowercased(), s == "http" || s == "https" {
                return HubKit.secondaryButton(b.text ?? href, symbol: "link") { NSWorkspace.shared.open(u) }
            }
            return rich(b.text ?? "")
        case "image":
            return HubKit.label("이미지는 앱에서 볼 수 있어요.", color: PetTheme.secondary)
        default:
            return HubKit.label("이 부분은 표시할 수 없어요.", color: PetTheme.secondary)
        }
    }

    /// 저장 위치는 사용자가 고른다. 고른 뒤에 서버에서 받아 쓴다.
    func downloadPage(_ doc: HubPageDoc) {
        guard let client = ctx.client else { return }
        let toast = ctx.toast
        let panel = NSSavePanel()
        panel.nameFieldStringValue = HubRoomsAPI.downloadFileName(title: doc.title)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        call(client, { HubRoomsAPI.pageDownloadRequest($0, id: doc.id, bearer: $1) }) { result in
            DispatchQueue.main.async {
                switch result {
                case let .failure(e): toast(e.text, true)
                case let .success(resp):
                    do {
                        try resp.body.write(to: url, options: .atomic)
                        toast("내려받았어요.", false)
                    } catch {
                        toast("파일을 저장하지 못했어요. 저장 위치를 확인해 주세요.", true)
                    }
                }
            }
        }
    }

    // MARK: 받은 파일·사진 (미리보기·저장·삭제)

    func openMedia(_ item: HubMediaItem, room: HubRoom, tab: RoomTab) {
        guard let client = ctx.client else { showFailure("로그인이 필요해요."); return }
        let back: () -> Void = { [self] in showRoom(room, tab: tab) }
        guard item.isImage else { showMedia(item, image: nil, back: back); return }
        state.show(.loading)
        call(client, { HubRoomsAPI.mediaRequest($0, id: item.id, bearer: $1) }) { [self] result in
            onMain {
                switch result {
                case let .failure(e):
                    self.ctx.toast(e.isNotFound ? "지워졌거나 열 수 없는 파일이에요." : e.text, true)
                    back()
                case let .success(resp): self.showMedia(item, image: NSImage(data: resp.body), back: back)
                }
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func showMedia(_ item: HubMediaItem, image: NSImage?, back: @escaping () -> Void) {
        let backButton = HubKit.secondaryButton("돌아가기", symbol: "chevron.left", onClick: back)
        let save = HubKit.secondaryButton("저장…", symbol: "arrow.down.circle") { [self] in saveMedia(item) }
        let del = HubKit.primaryButton("삭제", symbol: "trash", danger: true) { [self] in confirmDeleteMedia(item, back: back) }
        let title = HubKit.label(item.name ?? "이름 없는 파일", font: PetTheme.title)
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m), inset: Double(PetTokens.Space.l))
        let info = [item.mime, RoomsSection.sizeText(item.bytes)].compactMap { $0 }.joined(separator: " · ")
        if !info.isEmpty { parts.stack.addArrangedSubview(HubKit.label(info, font: PetTheme.caption, color: PetTheme.secondary)) }
        if let img = image {
            let v = NSImageView(image: img)
            v.imageScaling = .scaleProportionallyUpOrDown
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
            v.widthAnchor.constraint(lessThanOrEqualToConstant: RoomsSection.pageWidth).isActive = true
            parts.stack.addArrangedSubview(v)
        } else if item.isImage {
            parts.stack.addArrangedSubview(HubKit.label("미리 볼 수 없어요. 저장해서 열어 보세요.", color: PetTheme.secondary))
        } else {
            parts.stack.addArrangedSubview(HubKit.label("이 파일은 미리 볼 수 없어요. 저장해서 열어 보세요.", color: PetTheme.secondary))
        }
        present(screen(header: [HubKit.hstack([backButton, save, del]), title], body: parts.scroll))
    }

    func saveMedia(_ item: HubMediaItem) {
        guard let client = ctx.client else { return }
        let toast = ctx.toast
        let panel = NSSavePanel()
        panel.nameFieldStringValue = HubRoomsAPI.attachmentFileName(item.name, fallback: "파일")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        call(client, { HubRoomsAPI.mediaRequest($0, id: item.id, bearer: $1) }) { result in
            DispatchQueue.main.async {
                switch result {
                case let .failure(e): toast(e.text, true)
                case let .success(resp):
                    do {
                        try resp.body.write(to: url, options: .atomic)
                        toast("저장했어요.", false)
                    } catch {
                        toast("파일을 저장하지 못했어요. 저장 위치를 확인해 주세요.", true)
                    }
                }
            }
        }
    }

    func confirmDeleteMedia(_ item: HubMediaItem, back: @escaping () -> Void) {
        ctx.confirm([
            HubConfirmStep(title: "이 파일을 삭제할까요?", message: "‘\(item.name ?? "이름 없는 파일")’\n서버에서 지워지고 대화의 모아보기에서도 빠져요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 삭제할까요?", message: "한 번 더 확인해요. 지우면 되돌릴 수 없어요.", confirmTitle: "삭제"),
        ]) { [self] in deleteMedia(item, back: back) }
    }

    func deleteMedia(_ item: HubMediaItem, back: @escaping () -> Void) {
        guard let client = ctx.client else { return }
        let toast = ctx.toast
        call(client, { HubRoomsAPI.mediaDeleteRequest($0, id: item.id, bearer: $1) }) { [self] result in
            onMain {
                switch result {
                case let .failure(e):
                    toast(e.isNotFound ? "이미 지워진 파일이에요." : e.text, true)
                    if e.isNotFound { back() }
                case .success:
                    toast("파일을 지웠어요.", false)
                    back()
                }
            }
        }
    }
}
