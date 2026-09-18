# PLAN v1.1 - AGO 서명 단계 추가

> **기준**: PLAN v1.0 (`PLAN_v1.0_macos.md`)
> **버전**: v0.2.0 목표
> **작성일**: 2026-09-18
> **작성자**: BoRaSaRang (AI 공동)
> **상태**: 구현 전. 사용자 확정 사항 반영됨.

---

## 1. 배경

v1.0 보안 정책(§2.4)은 `codesign --force` 강제 재서명을 전면 금지했다. 목적은 변조 증거 덮기 방지였다.
그러나 실전 사례(PageKit for Safari, 2026-09-18)가 보여준 것:

- 미서명/adhoc 앱을 본인 개발자 신원으로 서명하는 것은 증거 덮기가 아니라 **정상적인 서명 부여**다.
- 서명 후에도 개발용 서명은 `spctl`이 거부하므로, 서명≠실행 허용이다. 기존 체크박스 게이트는 그대로 유효하다.

이에 v1.0 정책을 **부분 철회**하고, 사용자 확인 기반의 서명 단계를 파이프라인에 추가한다.
단, adhoc(`--sign -`) 덮어씌우기는 여전히 금지다. 서명은 **실명 개발자 신원**으로만 수행한다.

## 2. 동작 명세

### 2.1 파이프라인 (5단계)

```
확인 → 제거 → 검증 → 서명 → 실행
```

- 검증(`codesign --verify`) 완료 후, 서명 가능 상태면 `.signing` phase 진입 + 확인 다이얼로그:
  **"서명하시겠습니까?"** → `[서명하기]` / `[건너뛰기]`
- 건너뛰기 → 기존 흐름 그대로 (경고 → 체크박스 → 실행).
- 서명하기 → 신원 해결 → 서명 실행 → `spctl` 평가 → 판정 (기존 게이트 유지).
- 서명 전 `codesign --verify` 결과(변조 파일 목록 포함)는 verdict에 **영구 고정**한다. 서명이 증거를 덮어도 로그·카드에는 남는다.

### 2.2 서명 대상 (사용자 확정)

- 미서명/adhoc → 서명 허용.
- 만료된 개발서명 → 서명 허용.
- **변조 의심 앱도 서명 허용** (v1.0 정책 철회). 단 증거 고정 + 빨간 경고 카드 유지. 실행은 여전히 체크박스 확인 후에만.

### 2.3 서명 실행 순서

1. 중첩 코드 먼저 개별 서명 (존재 시):
   - `Contents/PlugIns/`의 `*.appex`·`*.bundle`
   - `Contents/Frameworks/`의 `*.framework`·`*.dylib`
   - 경로 정렬 후 하나씩 서명 (개임 앱의 미서명 `steam_api.bundle` 같은 사례 대응, 2026-09-18)
2. 마지막에 `.app` 본체 서명.
3. 명령: `codesign --force -s "<신원>" "<경로>"` (each, `--deep` 사용 금지 — 중첩 서명은 순서대로 개별 수행).
4. adhoc(`-`) 서명 금지. 신원 없으면 서명 단계 진입 불가(§2.4).
5. 서명 후 `codesign --verify --deep --strict` 재검증으로 현재 유효성 갱신. 변조 증거(modifiedFiles)는 verdict에 유지.

### 2.4 신원 해결 (사용자 확정)

1. `security find-identity -v -p codesigning` 자동 탐지 → 목록 선택 (기본값: 첫 번째 유효 신원).
2. 탐지 결과 없음 → 수동 입력 필드 (신원 문자열 직접 입력. Apple ID 비번 수집 없음).
3. 둘 다 없음 → **미등록 유도 시트**:
   - "Xcode에 Apple ID 로그인이 필요합니다" + 3단계 안내.
   - `[Xcode 열기]` 버튼 (`NSWorkspace`로 Xcode 실행) + `[다시 확인]` 버튼 (재탐지).
   - 시트 닫기 = 서명 스킵 → 기존 흐름 유지.

### 2.5 실패 처리

- 서명 프로세스 실패 → 새 에러코드 `E-MAC-PERM-2005` (서명 실패) + 해당 phase에서 중단 (idle 복귀, 타임라인에 실패 지점 표시).
- 취소(⌘. / 취소 버튼) → 기존 `cancel()` 경로, 서명 대기 중 결정도 취소로 해제.

## 3. 보안 정책 개정 (v1.0 §2.4 대체)

| 항목 | v1.0 | v1.1 |
|---|---|---|
| `codesign --force --sign -` (adhoc 덮기) | 금지 | **금지 유지** |
| 실명 개발자 신원 서명 (확인 후) | 기능 없음 | 허용 (변조 앱 포함, 증거 고정 조건) |
| sudo 자동 승격 | 없음 | 없음 (유지) |
| 사용자 확인 없는 자동 실행 | 금지 | 금지 (유지, 서명도 확인 필수) |

## 4. 파일 변경 목록

| 파일 | 변경 |
|---|---|
| `Sources/AGO/Core/GatePipeline.swift` | `.signing` phase, `SignDecision` 대기/재개, `runSign()` (appex→app 순서), `resolveIdentities()` |
| `Sources/AGO/Core/AppInspector.swift` | `parseIdentities()` (find-identity 출력 파싱), `signTargets(appURL:)` (서명 순서 목록) |
| `Sources/AGO/Core/AppError.swift` | `signingFailed` 케이스 + `E-MAC-PERM-2005` |
| `Sources/AGO/Core/PipelineViewModel.swift` | 서명 확인/스킵/신원 상태, `decideSign()`, `openXcode()`, `refreshIdentities()` |
| `Sources/AGO/Views/PipelineTimelineView.swift` | 5단계 (확인→제거→검증→서명→실행) |
| `Sources/AGO/Views/SignPromptView.swift` | 신규: 확인 다이얼로그 + 미등록 유도 시트 + 수동 입력 |
| `Sources/AGO/Views/VerdictCardView.swift` | 서명됨 표시 (증거 유지, 최소 변경) |
| `Sources/AGO/App/AGOApp.swift` | 서명 시트/다이얼로그 연결 (최소 변경) |
| `Resources/*/Localizable.strings` | `sign.*`·`step.sign`·`status.signing`·`err.signing` 한/영 parity |
| `error_message_ko.json` | `E-MAC-PERM-2005` 추가 |
| `Tests/AGOTests/PipelineTests.swift` | 신원 파싱·서명 순서·신규 에러코드·타임라인 매핑 |
| `project.yml` | 버전 0.2.0 |
| `docs/TODO.md` | T-AGO-21~25 등록 |
| `docs/DESIGN.md` | 5단계 타임라인·서명 시트 명세 |
| `docs/CHANGELOG.md` | v0.2.0 항목 |
| 도움말·README(ko/en)·사이트 | "재서명 없음" 문구 개정 |

## 5. 검증

- smoke+unit (신규 테스트 포함, 목표 전 통과) → `./build_and_run.sh build macos` 성공.
- 실전 3종: PageKit(미서명), ImprovedTube(adhoc), boringNotch(개발서명).
- Console.app (subsystem `com.borasarang.ago`): `[INFO] [GATEOPEN]` 서명 시작/완료/스킵, `[ERROR] E-MAC-PERM-2005` 실패.
- DoD: 플랫폼 명시 / 문서 우선 / 코드+DebugLogger+error_code / 한국어 / smoke+unit / build 성공 / 로그 첨부 / error_message_ko.json / CHANGELOG / TODO+session 로그.
