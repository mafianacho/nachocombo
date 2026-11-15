import AppKit
import NachoComboCore

/// 보관함(NACHO-264 U9: I2). 파일 목록·삭제(이중 확인)·문서 만들기 옵션. 파일 열기는 본인 토큰으로 내려받아
/// 사용자가 고른 곳에 저장한다(서명 URL을 앱이 따로 열지 않는다).
final class ArchiveSection: HubSectionBase {
    var files: [HubArchiveFile] = []
    var nextCursor: String?
    var list: HubListView?

    init() { super.init(id: .archive) }

    override func load() {
        guard ctx.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        loadPage(cursor: nil)
    }

    func loadPage(cursor: String?) {
        callHub({ HubArchiveAPI.list($0, bearer: $1, cursor: cursor) }) { [self] r in
            switch r.flatMap(HubArchiveAPI.decodeList) {
            case let .failure(e):
                if cursor == nil { state.show(.failed(e.text)) } else { say(e.text, error: true) }
            case let .success(page):
                if cursor == nil { files = page.files } else { files += page.files }
                nextCursor = page.nextCursor
                draw(append: cursor != nil ? page.files : nil)
            }
        }
    }

    private func row(_ f: HubArchiveFile) -> HubRow {
        var sub = [f.dateLabel]
        if let s = f.sourceLabel, !s.isEmpty { sub.append(s) } else if !f.author.isEmpty { sub.append(f.author) }
        if let d = f.detail, !d.isEmpty { sub.append(d) }
        let kind = f.kind == "page" ? "문서" : (f.kind == "media" ? (f.isVideo ? "동영상" : "사진") : "파일")
        let symbol = f.kind == "media" ? (f.isVideo ? "video" : "photo") : "doc.text"
        let r = HubRow(title: f.name, subtitle: sub.joined(separator: " · "), trailing: kind, symbol: symbol)
        r.onClick = { [weak self] in self?.showDetail(f) }
        return r
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다). `append`가 있으면 그 줄만 목록 끝에 붙인다.
    func draw(append: [HubArchiveFile]? = nil) {
        if let more = append, let l = list {
            l.appendRows(more.map(row), hasMore: nextCursor != nil)
            l.onLoadMore = { [weak self] in self?.loadPage(cursor: self?.nextCursor) }
            return
        }
        if files.isEmpty && nextCursor == nil {
            let host = state.contentHost
            for v in host.subviews { v.removeFromSuperview() }
            let empty = HubKit.vstack([
                HubKit.label("보관함이 비어 있어요. 나초가 만든 문서와 사진이 여기에 모여요.", color: PetTheme.secondary),
                HubKit.secondaryButton("문서 만들기 옵션", symbol: "plus.rectangle.on.folder") { [weak self] in self?.showCreateOptions() },
            ])
            HubKit.pin(empty, in: host, inset: Double(PetTokens.Space.l))
            state.show(.content)
            return
        }
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        let l = HubListView()
        l.setRows([topBar()] + files.map(row), hasMore: nextCursor != nil)
        l.onLoadMore = { [weak self] in self?.loadPage(cursor: self?.nextCursor) }
        list = l
        HubKit.pin(l, in: host)
        state.show(.content)
    }

    private func topBar() -> NSView {
        let bar = HubKit.hstack([
            HubKit.secondaryButton("새로고침", symbol: "arrow.clockwise") { [weak self] in self?.reload() },
            HubKit.secondaryButton("문서 만들기 옵션", symbol: "plus.rectangle.on.folder") { [weak self] in self?.showCreateOptions() },
        ])
        return bar
    }

    // MARK: 상세

    func showDetail(_ f: HubArchiveFile) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        var fields: [(String, String)] = [("날짜", f.dateLabel)]
        if let s = f.sourceLabel, !s.isEmpty { fields.append(("출처", s)) }
        if !f.author.isEmpty { fields.append(("만든 이", f.author)) }
        if let d = f.detail, !d.isEmpty { fields.append(("정보", d)) }
        var actions: [NSView] = [HubKit.secondaryButton("목록", symbol: "chevron.left") { [weak self] in self?.draw() }]
        if f.canSave { actions.append(HubKit.secondaryButton("저장…", symbol: "square.and.arrow.down") { [weak self] in self?.save(f) }) }
        actions.append(HubKit.primaryButton("삭제", symbol: "trash", danger: true) { [weak self] in self?.confirmDelete(f) })
        let detail = HubDetailView(title: f.name, fields: fields, actions: actions)
        HubKit.pin(detail, in: host)
        state.show(.content)
    }

    // MARK: 저장(열기)

    func save(_ f: HubArchiveFile) {
        callHub({ f.kind == "page" ? HubArchiveAPI.downloadPage($0, id: f.id, bearer: $1) : HubArchiveAPI.downloadMedia($0, id: f.id, bearer: $1) }) { [self] r in
            switch r {
            case let .failure(e): say(e.text, error: true)
            case let .success(resp): offerSave(f, resp)
            }
        }
    }

    static func fileExtension(_ f: HubArchiveFile, contentType: String?) -> String {
        if f.kind == "page" { return "md" }
        let t = (contentType ?? "").lowercased()
        if t.contains("png") { return "png" }
        if t.contains("jpeg") || t.contains("jpg") { return "jpg" }
        if t.contains("gif") { return "gif" }
        if t.contains("webp") { return "webp" }
        if t.contains("mp4") { return "mp4" }
        if t.contains("quicktime") { return "mov" }
        return f.isVideo ? "mp4" : "jpg"
    }

    private func offerSave(_ f: HubArchiveFile, _ resp: PetHTTPResponse) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = HubArchiveAPI.safeFileName(f.name, fallback: f.kind == "page" ? "문서" : "보관함", ext: ArchiveSection.fileExtension(f, contentType: resp.header("Content-Type")))
        panel.canCreateDirectories = true
        let body = resp.body
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try body.write(to: url, options: .atomic)
                self?.say("저장했어요.")
            } catch {
                self?.say("저장하지 못했어요. 다른 위치를 골라 주세요.", error: true)
            }
        }
        if let w = state.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    // MARK: 삭제(이중 확인)

    func confirmDelete(_ f: HubArchiveFile) {
        ctx.confirm([
            HubConfirmStep(title: "이 파일을 지울까요?", message: "「\(f.name)」\n지우면 보관함에서 사라지고, 나초가 대화에 붙여 둔 것도 지워진 것으로 보여요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "한 번 더 확인해요. 지운 파일은 되돌릴 수 없어요.", confirmTitle: "지우기"),
        ]) { [weak self] in
            guard let self = self else { return }
            self.callHub({ HubArchiveAPI.remove($0, id: f.id, bearer: $1) }) { r in
                switch r.flatMap(HubArchiveAPI.decodeDeleted) {
                case .success:
                    self.say("지웠어요.")
                    self.load()
                case let .failure(e):
                    self.say(e.isNotFound ? "이미 없는 파일이에요." : e.text, error: !e.isNotFound)
                    if e.isNotFound { self.load() }
                }
            }
        }
    }

    // MARK: 만들기 옵션

    func showCreateOptions() {
        callHub({ HubArchiveAPI.createOptions($0, bearer: $1) }) { [self] r in
            switch r.flatMap(HubArchiveAPI.decodeCreateOptions) {
            case let .failure(e): say(e.text, error: true)
            case let .success(o): drawCreateOptions(o)
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다). 만들기는 나초와의 대화에서 이 문장을 보내는 것이라 여기선 문장을 복사해 준다.
    func drawCreateOptions(_ o: HubCreateOptions) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        let parts = HubKit.scrollingStack()
        let stack = parts.stack
        stack.addArrangedSubview(HubKit.secondaryButton("목록", symbol: "chevron.left") { [weak self] in self?.draw() })
        stack.addArrangedSubview(HubKit.label("만들 수 있는 것", font: PetTheme.title))
        if o.options.isEmpty { stack.addArrangedSubview(HubKit.label("지금은 만들 수 있는 종류가 없어요.", color: PetTheme.secondary)) }
        for opt in o.options {
            let sub = [opt.formats.joined(separator: ", "), opt.creditText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let row = HubRow(title: opt.title + "  " + opt.promptText, subtitle: sub, trailing: nil, symbol: "doc.badge.plus")
            stack.addArrangedSubview(row)
            HubKit.fill(stack, [row])
            let copy = HubKit.secondaryButton("문장 복사", symbol: "doc.on.doc") { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(opt.promptText, forType: .string)
                self?.say("문장을 복사했어요. 나초와의 대화에 붙여 넣으세요.")
            }
            stack.addArrangedSubview(copy)
        }
        if o.restrictionCount > 0 {
            stack.addArrangedSubview(HubKit.label("쉬고 있거나 문서를 못 만드는 나초가 \(o.restrictionCount)개 있어요.", font: PetTheme.caption, color: PetTheme.secondary))
        }
        HubKit.pin(parts.scroll, in: host)
        state.show(.content)
    }
}
