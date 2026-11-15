# 나초 앱 창(허브) 골격

나초 앱 기능을 맥에 옮기는 자리다. 기능 이슈는 **자기 파일만** 고치며 병렬로 간다(NACHO-264, 근거 표 `docs/parity/nacho-app-gap-20261115.md`).

## 구조

| 자리 | 파일 | 누가 고치나 |
| --- | --- | --- |
| 창 | `Sources/NachoCombo/Pet/Hub/PetHubWindow.swift` | 공용(고치지 않는다) |
| 화면 부품 | `.../Hub/HubKit.swift` | 공용 |
| 섹션 등록·기반 클래스 | `.../Hub/HubSections.swift` | 공용 |
| 섹션 13개 | `.../Hub/Sections/<Id>Section.swift` | **자기 섹션 이슈만** |
| 모듈 연결 | `.../Pet/NachoPetModule+Hub.swift` | 공용 |
| Core 요청·응답 | `Sources/NachoComboCore/Pet/Hub/HubAPI.swift` | 공용 |
| 기능 스위치·섹션 id | `.../Hub/HubFeatureFlags.swift` | 공용 |

섹션 id와 순서는 고정이다: account · notifications · rooms · groups · tasks · schedules · memory · nachos · friends · trust · usage · explore · archive.

## 섹션 채우기

`<Id>Section.swift`의 `load()`만 채운다. `usage`(`UsageSection.swift`)가 본보기다.

```swift
final class FooSection: HubSectionBase {
    init() { super.init(id: .foo) }
    override func load() {
        guard let client = ctx.client else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        let e = client.endpoint
        client.send({ HubAPI.get(e, "/api/v1/foo", bearer: $0) }) { [weak self] result in
            guard let self = self else { return }
            self.onMain {
                switch result {
                case let .failure(err): self.state.show(.failed(err.text))      // 한국어, 「다시 시도」 단추가 load()를 다시 부른다
                case let .success(resp): /* HubAPI.page(resp) / HubAPI.object(resp)로 읽고 */ self.draw(...)
                }
            }
        }
    }
}
```

- 화면은 `state.contentHost`에 붙이고 `state.show(.content)`. 빈 목록은 `.empty("문구")`.
- 쓰기는 `HubAPI.post/patch/put/delete`. 만드는 요청은 `idempotencyKey: HubAPI.newIdempotencyKey()`, 낙관적 잠금은 `expectedVersion:`. 409 `version_conflict`는 `err.isVersionConflict` → 새로 불러온다.
- 목록: `HubAPI.page(resp)` → `items`, `nextCursor`(다음 요청의 `before`), `hasMore`. `HubListView.setRows/appendRows`.
- 되돌릴 수 없는 동작(삭제·나가기·차단·해제)은 `ctx.confirm([step1, step2]) { ... }`로 확인창을 두 번 거친다. 서버 미리보기가 있으면 첫 단계 `message`에 넣는다.
- 알림은 `ctx.toast("문구", isError)`. 입력 칸은 `HubFormField(validator:)`(검증 문구는 한국어).
- 색·크기·글꼴은 `PetTheme`/`PetTokens`만 쓴다(라이트·다크 자동).
- 기능 스위치는 `HubFeatureFlags`(코드 상수: accountDelete 꺼짐, memoryDeleteAll 꺼짐, scheduleRunNow 켜짐, agentPhotoCreate 켜짐).

공용 기반에 추가가 필요하면 자기 파일에 extension으로 둔다. 그래도 안 되면 PR 본문에 「공용 변경 요청」으로 적는다.

## 요청 규칙 (HubAPI)

- GET/DELETE: 쿼리(부른 순서 그대로). DELETE의 `expected_version`은 쿼리.
- POST/PATCH/PUT: JSON 본문(키 정렬), `expected_version`은 본문, `Idempotency-Key` 헤더.
- 오류 `{"error":{code,message,reason}}` → `PetAPIError.text`(한국어, `ErrorText`).
- 401은 토큰을 새로 받아 한 번만 다시 보낸다. 지금 모듈 연결은 세션의 `withAccessToken`을 쓰고 「강제 새로고침」은 아직 없다(`PetSession.swift`는 #47 파일이라 건드리지 않았다).
- 서버 변경 없음. 경로·필드는 nacho-server `spec/*.tsp`와 같게 한다.

## 시험 패턴

- Core: `Tests/NachoComboCoreTests/HubAPITests.swift` 방식. 가짜 `PetHTTPClient`로 요청 바이트(메서드·경로·쿼리·본문·`Idempotency-Key`)와 응답(정상·빈 목록·401·404·409·서버 오류 문구)을 확인한다. RED(시험만 있고 실패)를 먼저 남긴다.
- 화면: `Tests/NachoComboAppTests/HubWindowCaptureTests.swift` 방식. `PetHubWindow(env:autosaveName: nil)`에 가짜 `HubEnvironment`를 주고 장면별 라이트·다크 캡처. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 운영 서버는 부르지 않는다.
- 이 서버에는 swift가 없다. Core는 macOS CI(`swift test`)로 확인한다.
