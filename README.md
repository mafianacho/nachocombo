# Nacho Combo (MVP)

하나의 macOS 앱에서 세 모듈을 각각 ON/OFF 한다. 타사 앱·코드·브랜드를 사용하지 않는다.

| 모듈 | 내용 | 권한 |
|---|---|---|
| 메뉴 막대 정리 | 구분선 왼쪽 아이콘 접기/펼치기 ([제약](docs/MENUBAR-CONSTRAINTS.md)) | 없음 |
| 시스템 모니터 | CPU·메모리·디스크·네트워크·센서 메뉴 막대 항목과 상세 패널 (2초 간격, [아래](#시스템-모니터)) | 없음 |
| 창 배치 | ⌃⌥← / ⌃⌥→ / ⌃⌥↩ 왼쪽·오른쪽·최대화 | 손쉬운 사용 |

- 대상: macOS 12 (Monterey) 이상, Swift 5.5+ (Package.swift `platforms: .macOS(.v12)`).
- 설정: `~/Library/Application Support/NachoCombo/settings.json` (기본값은 전부 OFF).
- OFF 계약: 모듈 `stop()`이 타이머·핫키·상태 아이템을 모두 해제한다. `state.json`(같은 폴더)에 확인용 카운터가 기록된다.
- 권한 거부: 창 배치를 켰는데 권한이 없으면 아무것도 등록하지 않고 안내(설정 열기 버튼, 재확인)를 표시한다. 우회하지 않는다.

## 시스템 모니터
메뉴 막대에 항목별 아이템(CPU, 메모리, 디스크, 네트워크, 센서)을 따로 띄우고, 클릭하면 상세 패널을 연다.
표시할 항목은 설정 창에서 고른다. 패널은 바깥 클릭·Esc·Space 전환으로 닫힌다.

| 패널 | 내용 |
|---|---|
| CPU | 사용자/시스템 히스토리, 코어별 게이지(효율 코어 분홍·성능 코어 파랑), 상위 프로세스, GPU(사용률·메모리·온도·클럭), 평균 부하, 가동시간 |
| 메모리 | 압력·사용량 링(앱·와이어드·압축됨), 상위 프로세스, 페이지 입출력, 스왑 사용량 |
| 디스크 | 시동 볼륨 사용량, 읽기/쓰기 속도와 히스토리, 기간 내 최고치, 부팅 후 누적, 프로세스별 R/W |
| 네트워크 | 업로드/다운로드 속도와 히스토리, 인터페이스, 공용 IP(옵트인), 로컬 IP, 프로세스별 ↑/↓ |
| 센서 | CPU/GPU 온도·클럭, 팬, 온도 센서 목록, 총 전력 히스토리 |

- 히스토리 그래프 기간: 10분 / 1시간 / 3시간 / 24시간(그래프마다 선택, 설정에 저장). 히스토리는 메모리에만 24시간 보관하고 재시작하면 비워진다.
- 데이터 출처와 한계:
  - 공개 API: Mach 호스트 통계(CPU·메모리), sysctl(압력·스왑·부하), IOKit 레지스트리(디스크 누적량, GPU 사용률), getifaddrs·SystemConfiguration(네트워크).
  - 프로세스 통계는 `proc_pid_rusage`로 **내 계정 소유 프로세스만** 집계한다(root 소유 프로세스는 macOS가 거부). 도우미 프로세스는 앱 번들 단위로 합산한다.
  - 프로세스별 네트워크는 `/usr/bin/nettop` 단발 스냅샷을 네트워크 패널이 열려 있을 때만 2초마다 실행해 차이를 계산한다.
  - 온도·팬·전력은 SMC 키(비문서화)를, CPU/GPU 클럭은 비공개 라이브러리 IOReport(dlopen)를 읽는다. 없거나 실패하면 "–"로 표시하고 다른 기능에는 영향이 없다.
    코어별 온도 이름은 키 배치를 확인한 M1 Pro/M1 Max에서만 붙이고, 다른 Apple 실리콘은 CPU 평균·최고로 표시한다. 클럭 표는 M1 Pro에서 검증했다.
  - 공용 IP는 외부 요청(`https://www.cloudflare.com/cdn-cgi/trace`)이므로 기본 OFF다. 패널의 "확인" 버튼 또는 설정의 자동 조회를 켰을 때만 요청한다.

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
  `ctl snap left|right|maximize`, `ctl dump`, `ctl quit`. 상태 JSON을 출력한다. 릴리스 사용 대상 아님.
  - 시스템 모니터: `ctl monitor show cpu|memory|disk|network|sensors`, `ctl monitor hide`, `ctl monitor items cpu,network`,
    `ctl monitor range <cpu|disk|network|power> <600|3600|10800|86400>`, `ctl monitor publicip`,
    `ctl monitor snapshot <항목> <파일.png> [light]`(패널을 PNG로 렌더), `ctl monitor menubar <파일.png> [light]`, `ctl settings snapshot <파일.png>`.

## 라이선스
[MIT](LICENSE) © 2026 Mafianacho (마피아나초). "Nacho Combo" 이름과 로고는 이 라이선스의 허락 대상이 아니다.
