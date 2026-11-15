import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 보관함 섹션(NACHO-264 U9: I2) 장면별 캡처·동작 시험. macOS CI 오프스크린 렌더.
final class HubArchiveCaptureTests: XCTestCase {
    private let list = "{\"file_sections\":[{\"key\":\"2026-11-14\",\"date_label\":\"11월 14일 (토)\",\"items\":[{\"id\":\"p1\",\"name\":\"여행 계획\",\"kind\":\"page\",\"source_label\":\"나초와의 대화\",\"author_name_snapshot\":\"나초\"},{\"id\":\"f1\",\"name\":\"메모.pdf\",\"kind\":\"file\",\"author_name_snapshot\":\"나\"}]}],\"media_sections\":[{\"key\":\"2026-11-13\",\"date_label\":\"11월 13일 (금)\",\"items\":[{\"id\":\"m1\",\"is_video\":true,\"duration_label\":\"1:05\",\"author_name_snapshot\":\"나초\"}]}],\"backfill_complete\":true,\"next_cursor\":\"2026-11-01T00:00:00Z\"}"
    private let more = "{\"file_sections\":[{\"key\":\"2026-10-30\",\"date_label\":\"10월 30일 (금)\",\"items\":[{\"id\":\"p2\",\"name\":\"지난 문서\",\"kind\":\"page\",\"author_name_snapshot\":\"나초\"}]}],\"media_sections\":[]}"
    private let options = "{\"options\":[{\"kind\":\"document\",\"formats\":[\"md\"],\"prompt_text\":\"문서를 만들어 줘\",\"credit\":{\"estimate_min\":5,\"estimate_max\":8,\"task_label\":\"x\"}}],\"last_agent_id\":\"a1\",\"restrictions\":[{\"agent_id\":\"b\",\"reason\":\"resting\"}]}"

    private func http(listBody: String? = nil, deleteStatus: Int = 200) -> HubFakeHTTP {
        HubFakeHTTP { [self] r in
            switch (r.method, r.url.path) {
            case ("GET", "/api/v1/archive/files"): return HubU9.json(r.url.query?.contains("cursor=") == true ? more : (listBody ?? list))
            case ("DELETE", "/api/v1/archive/files/p1"): return deleteStatus == 200 ? HubU9.json("{\"status\":\"ok\"}") : HubU9.err(deleteStatus, "not_found")
            case ("GET", "/api/v1/archive/create-options"): return HubU9.json(options)
            case ("GET", "/api/v1/pages/p1/download"): return (200, "# 여행 계획", ["Content-Type": "text/markdown"])
            default: return HubU9.err(404, "not_found")
            }
        }
    }

    private func section(_ w: PetHubWindow) throws -> ArchiveSection { try XCTUnwrap(w.currentSection as? ArchiveSection) }

    func testListShowsFilesMediaAndPages() throws {
        let h = http()
        let w = HubU9.window(.archive, http: h)
        HubU9.pump()
        let all = HubU9.joined(w)
        for t in ["여행 계획", "메모.pdf", "동영상", "11월 14일 (토)", "문서", "파일"] { XCTAssertTrue(all.contains(t), "\(t)\n\(all)") }
        XCTAssertEqual(h.lines, ["GET /api/v1/archive/files"])
        try HubU9.captureAll(w, name: "archive-list")
        XCTAssertTrue(HubU9.tap("더 보기", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(h.lines.contains("GET /api/v1/archive/files?cursor=2026-11-01T00%3A00%3A00Z"), h.lines.joined(separator: "\n"))
        XCTAssertTrue(HubU9.joined(w).contains("지난 문서"))
    }

    func testEmptyAndError() throws {
        let w = HubU9.window(.archive, http: http(listBody: "{\"file_sections\":[],\"media_sections\":[]}"))
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w).contains("보관함이 비어 있어요"))
        try HubU9.capture(w, dark: false, name: "archive-empty")
        let bad = HubU9.window(.archive, http: HubFakeHTTP { _ in HubU9.err(500, "internal_error") })
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(bad).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
    }

    func testDetailOffersSaveOnlyWhereDownloadExists() throws {
        let w = HubU9.window(.archive, http: http())
        HubU9.pump()
        XCTAssertTrue(HubU9.tapRow("여행 계획", in: w.contentView!))
        let page = HubU9.joined(w)
        XCTAssertTrue(page.contains("저장…") && page.contains("삭제"), page)
        try HubU9.captureAll(w, name: "archive-detail")
        let s = try section(w)
        s.draw()
        XCTAssertTrue(HubU9.tapRow("메모.pdf", in: w.contentView!))
        XCTAssertFalse(HubU9.joined(w).contains("저장…"), "지식 문서는 내려받는 경로가 없다")
    }

    func testDeleteNeedsTwoConfirmationsThenReloads() throws {
        let h = http()
        let w = HubU9.window(.archive, http: h)
        HubU9.pump()
        let s = try section(w)
        let f = try XCTUnwrap(s.files.first { $0.id == "p1" })
        s.confirmDelete(f)
        HubU9.pump()
        let sheet1 = try XCTUnwrap(w.attachedSheet?.contentView)
        XCTAssertTrue(HubU9.texts(sheet1).contains("이 파일을 지울까요?"))
        XCTAssertTrue(h.log.filter { $0.method == "DELETE" }.isEmpty)
        XCTAssertTrue(HubU9.tap("계속", in: sheet1))
        HubU9.pump()
        let sheet2 = try XCTUnwrap(w.attachedSheet?.contentView)
        XCTAssertTrue(HubU9.texts(sheet2).contains("정말 지울까요?"))
        XCTAssertTrue(h.log.filter { $0.method == "DELETE" }.isEmpty)
        XCTAssertTrue(HubU9.tap("지우기", in: sheet2))
        HubU9.pump()
        XCTAssertEqual(h.log.filter { $0.method == "DELETE" }.map { $0.url.path }, ["/api/v1/archive/files/p1"])
        XCTAssertEqual(h.lines.filter { $0 == "GET /api/v1/archive/files" }.count, 2, "지운 뒤 목록을 새로 불러온다")
    }

    func testCreateOptionsScreen() throws {
        let h = http()
        let w = HubU9.window(.archive, http: h)
        HubU9.pump()
        XCTAssertTrue(HubU9.tap("문서 만들기 옵션", in: w.contentView!))
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("문서를 만들어 줘") && all.contains("예상 5~8 크레딧") && all.contains("문장 복사"), all)
        XCTAssertTrue(all.contains("쉬고 있거나 문서를 못 만드는 나초가 1개 있어요."), all)
        try HubU9.captureAll(w, name: "archive-create-options")
    }

    func testFileExtensionFollowsContentType() {
        let page = HubArchiveFile(id: "p", name: "n", kind: "page", detail: nil, sourceLabel: nil, author: "", dateLabel: "", isVideo: false)
        let img = HubArchiveFile(id: "m", name: "사진", kind: "media", detail: nil, sourceLabel: nil, author: "", dateLabel: "", isVideo: false)
        let vid = HubArchiveFile(id: "v", name: "동영상", kind: "media", detail: nil, sourceLabel: nil, author: "", dateLabel: "", isVideo: true)
        XCTAssertEqual(ArchiveSection.fileExtension(page, contentType: "text/markdown"), "md")
        XCTAssertEqual(ArchiveSection.fileExtension(img, contentType: "image/png"), "png")
        XCTAssertEqual(ArchiveSection.fileExtension(img, contentType: nil), "jpg")
        XCTAssertEqual(ArchiveSection.fileExtension(vid, contentType: "video/mp4"), "mp4")
    }
}
