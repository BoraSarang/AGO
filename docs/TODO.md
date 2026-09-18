# TODO - AGO (열어줘) macOS 앱

> **프로젝트**: AGO (Automatic Gate Opener)
> **플랫폼**: macOS
> **버전**: v1.0 완료 → v1.1 진행 중 (서명 단계)
> **최종 갱신**: 2026-09-18
> **기준 문서**: `docs/plans/PLAN_v1.0_macos.md` + `docs/plans/PLAN_v1.1_macos.md`

---

## 📋 마일스톤 진행 현황

### M1: 프로젝트 뼈대 ✅ (2026-09-07 완료)
- [x] T-AGO-01: 프로젝트 생성 (`AGO`, SwiftUI, macOS 14+, 번들ID `com.borasarang.ago`) — xcodegen `project.yml`로 생성
- [x] T-AGO-02: `build_and_run.sh` + `.gitignore` + `error_message_ko.json` (7종) 작성
- [x] T-AGO-03: 최소 셸 (`AGOApp`, `DebugLogger`, `AppError`, 스켈레톤 테스트) — 빌드·테스트 통과
- [x] T-AGO-04: 문서 4종 (PLAN/TODO/DESIGN/CHANGELOG) 작성

### M2: 파이프라인 + 풀커스텀 UI ✅ (2026-09-07 완료, 로컬 검증까지)
- [x] T-AGO-10: `GatePipeline` — `Process` 래퍼, 단계별 실행 + 취소, `[INFO] [GATEOPEN]` 로그
- [x] T-AGO-11: `AppInspector` — `.app` 형식 검사 + xattr/codesign/spctl 결과 파싱
- [x] T-AGO-12: `DropZoneView` — 히어로 드롭존 (`.dropDestination` + `NSOpenPanel` 파일 선택, `.app`만 수락, 아이콘·버전 미리보기)
- [x] T-AGO-13: `TerminalLogView` — 터미널 카드 (SF Mono 로그, 명령/성공/에러 색 구분, 복사)
- [x] T-AGO-14: `VerdictCardView` — 파이프라인 타임라인 (4단계) + 상태 배지 + 변조 경고 카드 + 체크박스 실행 게이트
- [x] T-AGO-15: `HelpSheetView` + 종료 + 단축키 (`⌘O`, `⌘/`, `⌘T`, `⌘Q`)
- [x] T-AGO-16: smoke+unit 10/10 통과 + `./build_and_run.sh build macos` 성공
- [x] T-AGO-17(DoD 문서): `error_message_ko.json` 점검 (validationFailed 미사용 확인) + `docs/CHANGELOG.md` 기록 + session 로그
- [x] T-AGO-18: 풀커스텀 UI 확정 (히어로·타임라인·터미널카드·모션, `docs/DESIGN.md` §6) — 사용자 선택 2026-09-07
- [x] T-AGO-19: `package macos` + GitHub 공개 repo + Release `v0.1.0` + Pages 배포 — 2026-09-07 완료
- [x] T-AGO-20: 앱 내 한/영 지원 (`Localizable.strings` en/ko + `L10n` 헬퍼, 전 UI·로그·에러 교체, 영문 실행 검증) — 2026-09-07 완료, 테스트 18/18

### M3: 서명 단계 ✅ (v1.1, PLAN_v1.1 — 2026-09-18 완료)
- [x] T-AGO-21: 파이프라인 `.signing` phase + 확인/스킵 + 서명 전 증거 고정 + `E-MAC-PERM-2005`
- [x] T-AGO-22: 신원 자동탐지(`security find-identity` 파싱) + 수동 입력 폴백 (파싱 버그 수정 포함)
- [x] T-AGO-23: 미등록자 유도 시트 (Xcode 열기 + 다시 확인)
- [x] T-AGO-24: 5단계 타임라인 UI + 한/영 문자열 parity (19키)
- [x] T-AGO-25: 정책 문서 개정 (PLAN/도움말/README/사이트) + 실전 검증 (PageKit·60Seconds / steam_api.bundle 사례) + CHANGELOG + session 로그

---

## ✅ 완료 (Done)
- [x] PLAN v1.0 확정 (2026-09-07): `.app`만, 경고 후 허용, 자동 실행 금지
- [x] 프로젝트 뼈대 생성 + 빌드·테스트 통과 (2026-09-07)

---

## 📝 비고
- `.dmg` 처리는 v1 범위 밖 (v1.1 이후 검토)
- 강제 재서명(`codesign --force --sign -`) 기능 없음 — 보안 정책
- sudo 자동 승격 없음
- bd 연동 시: `bd create --title "..." --label macos --label ago`
