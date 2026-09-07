# PLAN v1.0 - AGO (Automatic Gate Opener)

> **앱 이름**: AGO – Automatic Gate Opener (한글명: **열어줘**)
> **번들ID**: `com.borasarang.ago`
> **타겟**: macOS 14+ (Sonoma)
> **빌드**: xcodebuild(xcodegen `project.yml`), 결과물 `~/Applications/AGO.app`
> **작성일**: 2026-09-07
> **작성자**: BoRaSaRang (AI 공동)
> **상태**: 프로젝트 뼈대 + 문서만 생성. 구현은 다음 세션.

---

## 1. 배경

인터넷에서 `.dmg`로 받아 설치한 앱이 Gatekeeper quarantine(`com.apple.quarantine`) 때문에
바로 실행되지 않고, 시스템 설정 → 개인정보 보호 및 보안에서 수동으로 허용해 줘야 하는 불편이 있다.
작은 항상-위 창에 `.app`을 드래그하면 차단 해제→검증→실행을 한 흐름으로 끝내는 것이 목적이다.

범위 잠정 (2026-09-07 사용자 확정):
- 별도 프로젝트 (`/Users/lee/Documents/Apps/AGO`), MyWay 코드 손대지 않음
- **`.app`만 처리. `.dmg`는 v1 범위 밖** (마운트·복사 미지원)
- 파이프라인 전체 자동화 (조회→제거→검증→사용자 확인 후 실행)
- 서명 깨짐(변조 의심)은 **경고 후 허용** (체크박스 확인 시에만 실행, 강제 재서명 없음)

## 2. 동작 명세

### 2.1 윈도우
- 단일 윈도우 520×640 (최소 480×560), `.windowToolbarStyle(.unified)`
- 툴바: 상태 배지(좌) + 핀 버튼(`pin.fill`/`pin.slash`, 항상 위 on/off, `⌘T`)
- 파이프라인 타임라인: `확인 → 제거 → 검증 → 실행` 4단계, 단계별 스피너·체크·에러 아이콘 (풀커스텀, 2026-09-07 확정)
- 히어로 드롭존: 큰 드롭 타깃 + 앱 아이콘·이름·버전 미리보기 + 빈 상태 일러스트 (SF Symbol, accent 1곳만)
- 상태머신: `idle → inspecting → cleaning → verifying → ready | blocked(경고)`
- 핀 상태 `@AppStorage("agoPinned")` 복원. 기본 켜짐.

### 2.2 드롭 → 파이프라인 (자동 순차 실행, 로그에 `$ 명령` + 결과 출력)1. 형식 검사: `.app` 확장자·번들 구조 아니면 `E-MAC-VAL-2002`로 거부
2. `ls -ld` + `xattr -l` 조회 (차단 속성 확인)
3. `xattr -dr com.apple.quarantine "<경로>"` 제거 (sudo 없이 시도, 권한 실패면 `E-MAC-PERM-2002`로 중단)
4. `codesign --verify --deep --strict --verbose=4` 검증
   - `file added/modified` 나오면 변조 경고 카드 + 공식 재설치 권장
5. `spctl -a -vv` 평가 → 통과면 실행 버튼 활성화
6. 사용자가 실행 버튼을 눌러야 `open "<경로>"` (자동 실행 금지)

### 2.3 하단 버튼 2개
- 도움말 (`⌘/`): 왜 필요한지 / 드래그 후 절차 / 경고 의미 / 공식 재설치 권장
- 종료 (`⌘Q`)

### 2.4 보안 정책
- 서명 정상 → 바로 실행 가능
- 서명 깨짐 → 빨간 경고(추가·수정 파일 목록) + 체크박스 확인 후에만 실행
- `codesign --force --sign -` 같은 강제 재서명 기능 없음
- sudo 자동 승격 없음 (권한 실패는 안내 후 중단)

## 3. 파일 구성 (예정)

| 파일 | 내용 |
|---|---|
| `Sources/AGO/App/AGOApp.swift` | 앱 셸, 핀 윈도우, 메뉴바 (뼈대 완료) |
| `Sources/AGO/Core/DebugLogger.swift` | 통합 로거 (뼈대 완료, 패널 연동은 후속) |
| `Sources/AGO/Core/AppError.swift` | 에러코드 7종 (뼈대 완료) |
| `Sources/AGO/Core/GatePipeline.swift` | `Process` 래퍼, 단계별 실행 (다음 세션) |
| `Sources/AGO/Core/AppInspector.swift` | xattr/codesign/spctl 결과 파싱 (다음 세션) |
| `Sources/AGO/Views/DropZoneView.swift` | 드롭존 + 파일 선택 (다음 세션) |
| `Sources/AGO/Views/TerminalLogView.swift` | 터미널 로그, 복사 (다음 세션) |
| `Sources/AGO/Views/VerdictCardView.swift` | 경고 카드 + 체크박스 (다음 세션) |
| `Sources/AGO/Views/HelpSheetView.swift` | 도움말 시트 (다음 세션) |
| `Tests/AGOTests/` | 파이프라인 단위 테스트 (다음 세션) |

## 4. 배포 (2026-09-07 확정)

- **형식**: `.zip` (DMG 안 씀). `ditto -c -k --sequesterRsrc --keepParent` 사용, 시스템 내장 도구만
- **경로**: GitHub 공개 저장소 Release 첨부 (`BoraSarang/AGO` 예정), 산출물 `dist/AGO-<버전>-macos.zip`
- **서명**: unsigned (Developer ID 없음). 받는 쪽 Gatekeeper 경고 발생 가능 → Release 노트에 차단 해제 안내 포함
  (`xattr -dr com.apple.quarantine` 후 압축 해제)
- **버전**: 첫 릴리스 `v0.1.0` (M2 파이프라인 + 풀커스텀 UI 완료 후). 릴리스 노트는 CHANGELOG 해당 항목 그대로 사용
- **제외**: Sparkle 자동 업데이트 (v1.1 이후 검토), 볼륨 아이콘·배경 같은 DMG 연출 없음
- **빌드 명령**: `./build_and_run.sh package macos` (build → zip → dist/ 출력)

## 5. 검증
- 기본 피드백 루프 = smoke+unit만. full은 커밋/PR 게이트 + 사용자 허락 시
- 성능 예산: Cold Start ≤1.5s (스켈레톤에 측정 로그 포함)
- DebugPanel 대신 Console.app(subsystem `com.borasarang.ago`) 로그 확인 (v1)
- DoD: 플랫폼 명시 / 문서 우선 / 코드+DebugLogger+error_code / 한국어 / smoke+unit 통과 / build 성공 / 로그 첨부 / error_message_ko.json / CHANGELOG / TODO+session 로그
