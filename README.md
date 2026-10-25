# Nacho Combo

## 사용법 (앱 하나)
1. `NachoCombo.app`을 더블클릭한다(공증 전 ad-hoc 서명이므로 처음에는 우클릭 ▸ 열기가 필요할 수 있다).
2. 가젯 설정 창이 열린다. 가젯마다 스위치로 독립 ON/OFF. 각 가젯에 `꺼짐 / 동작 중 / 권한 필요 / 오류` 상태가 표시된다.
3. 권한이 필요한 가젯(창 배치=손쉬운 사용, 캡처 고정=화면 기록)은 **직접 켠 순간에만** OS 동의 창이 뜬다. 거부하면 해당 가젯 카드에 안내와 설정 열기 버튼이 표시된다. 재서명(재빌드) 시 기존 허용이 무효가 되어 다시 동의해야 할 수 있다.
4. 설정 창을 닫아도 켜 둔 가젯은 계속 동작한다. 메뉴 막대 `NC ▸ 설정…`이나 앱을 다시 열면 설정 창이 다시 열린다. `Nacho Combo 종료`(또는 NC ▸ 종료)로 모든 감시·단축키·오버레이를 정리한다.
5. 선택은 자동 저장되고 다음 실행 때 복원된다(로그인 시 자동 실행은 등록하지 않는다).

## 빠른 패널 (메뉴 막대)
- 메뉴 막대 `NC`를 누르면 **도구 목록**이 열린다. 행마다 왼쪽 상태 원, 도구 심볼·이름, 오른쪽 `화면 열기 단축키`(없으면 `미설정`), 맨 오른쪽 `›`.
  도구를 누르면 같은 팝오버에서 그 도구의 **조작 화면**으로 바뀐다(목록 → 조작 두 단계까지). `‹ 모든 도구`, `Esc`로 목록에 돌아간다(목록에서 Esc는 닫기).
- 상태 원: 초록 = 사용자가 켬, 회색 = 끔. 켰지만 권한/추가 설정이 필요하면 노란 원이 초록 원 뒤에 반쯤 겹쳐 보인다(오류는 빨간 원). 색만으로 판단하지 않도록 조작 화면에 `동작 중 / 권한 필요 / 오류` 글자와 설명이 항상 함께 나오고, 툴팁·접근성 이름에도 같은 내용이 들어간다. 초록은 “켰다”는 뜻이며 동작 성공의 증거는 상태 글자다.
- 도구별 **메뉴 막대 고정/해제**: 고정하면 그 도구만의 아이콘이 메뉴 막대에 생기고, 누르면 목록을 거치지 않고 해당 도구 조작 화면이 바로 열린다. 고정은 켜기/끄기와 별개이며 켜기·OS 권한 요청을 대신하지 않는다. 기본값은 아무것도 고정하지 않음.
- **화면 열기 단축키**(도구별, 설정 창에서 지정): 해당 도구 조작 화면을 여는 용도이며 기능 실행 단축키(⌃⌥←/→/↩, ⌃⌥S, ⌃⌥C, ⌃⌥D)와 다르다. 기본값은 `미설정`. ⌃ 또는 ⌥를 포함한 수정 키 2개 이상(F키는 1개)이 필요하고, 기능 실행 단축키·macOS 예약 조합·다른 도구와 같은 조합·다른 앱이 이미 쓰는 조합은 거부된다. 이 단축키는 화면만 열며, 앱이 실행 중인 동안 도구가 꺼져 있어도 유지된다(도구 자체의 실행 단축키는 도구를 끄면 해제됨).
- 조작 화면: 메뉴 막대 정리(접기/펼치기), 시스템 모니터(CPU·메모리·네트워크 실측 수치), 창 배치(왼쪽/오른쪽/최대화 + 결과 미리보기 → 적용, 직전에 쓰던 앱의 창이 대상), 파일 선반(열기/닫기·항목 수), 캡처 고정(패널이 닫힌 뒤 영역 선택), 집중 디밍(강도). 상세 설정은 `설정…`으로 기존 설정 창을 연다.
- 고정 여부와 단축키는 `settings.json`의 `pinnedTools`, `toolShortcuts`에 저장되고 다음 실행 때 복원된다. 이전 버전 설정 파일은 그대로 읽힌다(고정·단축키 없음).

하나의 macOS 앱에서 여섯 가젯을 각각 ON/OFF 한다. 타사 앱·코드·브랜드를 사용하지 않는다.

| 모듈 | 내용 | 권한 |
|---|---|---|
| 메뉴 막대 정리 | 구분선 왼쪽 아이콘 접기/펼치기 ([제약](docs/MENUBAR-CONSTRAINTS.md)) | 없음 |
| 시스템 모니터 | CPU·메모리·네트워크 (2초 간격) | 없음 |
| 창 배치 | ⌃⌥← / ⌃⌥→ / ⌃⌥↩ 왼쪽·오른쪽·최대화 | 손쉬운 사용 |
| 파일 선반 | 파일·이미지·텍스트를 임시 선반에 모았다가 다른 앱으로 다시 끌어냄(복사만, 원본 이동·삭제 없음). ⌃⌥S 열기/닫기 | 없음 |
| 캡처 고정 | ⌃⌥C로 영역 선택 캡처 → 다른 창 위에 고정. 여러 장 이동·크기 조절·고정 해제·닫기·복사·저장 | 화면 기록 |
| 집중 디밍 | 활성 창만 밝게, 배경 창은 어둡게(클릭 통과). 강도 조절, ⌃⌥D 즉시 해제 | 없음 |

- 대상: macOS 12 (Monterey) 이상, Swift 5.5+ (Package.swift `platforms: .macOS(.v12)`).
- 설정: `~/Library/Application Support/NachoCombo/settings.json` (기본값은 전부 OFF, 디밍 강도 `dimIntensity` 0.1~0.9 포함).
- OFF 계약: 모듈 `stop()`이 타이머·핫키·상태 아이템을 모두 해제한다. `state.json`(같은 폴더)에 확인용 카운터가 기록된다.
- 선반 OFF/종료: 선반이 만든 이미지 사본(`Shelf/`)만 지우고 사용자의 원본 파일은 건드리지 않는다.
- 캡처 고정: 화면 기록 권한이 없으면 아무것도 등록하지 않고 안내만 표시한다(우회 없음). 허용 뒤 앱을 다시 실행해야 적용될 수 있다.
- 권한 거부: 창 배치를 켰는데 권한이 없으면 아무것도 등록하지 않고 안내(설정 열기 버튼, 재확인)를 표시한다. 우회하지 않는다.

## 설치 (릴리즈)
- [Releases](../../releases)에서 `NachoCombo-<버전>-macos.zip` 또는 `.dmg`와 `SHA256SUMS.txt`를 받는다. 유니버설 바이너리(Apple Silicon + Intel), macOS 12 이상.
- 검증: `shasum -a 256 -c SHA256SUMS.txt`
- **서명 한계: ad-hoc 서명이며 Apple Developer ID 서명·공증(notarization)이 없다.** 처음 실행하면 Gatekeeper가 막는다.
  앱을 우클릭 → 열기 → 열기, 또는 시스템 설정 ▸ 개인정보 보호 및 보안에서 허용한다. 업데이트·재빌드하면 코드 서명이 바뀌므로
  창 배치의 손쉬운 사용 권한을 다시 허용해야 한다.
- 릴리즈는 `v0.1.0` 형식 태그를 푸시하면 GitHub Actions(`.github/workflows/release.yml`)가 macOS 러너에서 빌드·패키징해 자동 생성한다.

## 빌드 / 시험
- macOS: `scripts/build-app.sh` → `build/NachoCombo.app` (ad-hoc 서명). 실행 `open build/NachoCombo.app`.
  유니버설 빌드 `UNIVERSAL=1`, 버전 지정 `VERSION=x.y.z`, 패키징 `VERSION=x.y.z scripts/package.sh` (zip·dmg·SHA256SUMS → `dist/`).
- Core 단위시험(Linux/macOS 공통): `swift test` (Linux에서는 AppKit 타깃이 매니페스트에서 제외됨).
- 디버그 제어 채널: `NachoCombo --debug-ctl`로 실행 후 `NachoCombo ctl set systemMonitor off|on`, `ctl collapse on|off`,
  `ctl snap left|right|maximize`, `ctl shelf show|hide|clear|addfile <path>|addtext <text>|paste|remove <i>`,
  `ctl capture select|rect x y w h`, `ctl float pin|unpin|close|copy|width|save <i> [arg]`, `ctl dim intensity <0.1-0.9>|refresh`,
  `ctl pin <module> on|off`, `ctl shortcut <module> <keyCode> <carbonMods>|clear`, `ctl panel list|tool <module>|back|close`,
  `ctl dump`, `ctl quit`. 상태 JSON을 출력한다(`ui` 절에 패널·고정·단축키 상태). 릴리스 사용 대상 아님.
- 서명은 ad-hoc이며 재빌드하면 손쉬운 사용·화면 기록 허용을 다시 해야 한다.

## 라이선스
[MIT](LICENSE) © 2026 Mafianacho (마피아나초). "Nacho Combo" 이름과 로고는 이 라이선스의 허락 대상이 아니다.
