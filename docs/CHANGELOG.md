# CHANGELOG - AGO

> 모든 기록은 한국어. platform 태그 + error_code + perf 영향 포함.

## [v0.2.2] - 2026-09-22 (macos) — 실행 런처 맥락 수정 + 업데이트 확인 + DMG 배포
- 업데이트 확인 (T-AGO-29, macos-app-update 가이드 적용): `ReleaseChecker`가 GitHub `releases/latest` 조회(404는 "릴리스 없음"으로 분리, User-Agent는 번들 버전). `UpdateModel` — 주기(실행 시/매일/매주/안 함, 기본 주 1회) + `updateCheckedAt` UserDefaults 영속화. UI: 하단 버전 자리에 주황 "vX 사용 가능" 배지 → `UpdateAvailableSheet`(릴리스 노트 줄 단위 블록 렌더링 — 가이드 실패 2·3번 회피, 한글 볼드 CLI 사전 검증) + 도움말 시트에 확인 버튼·주기 피커. 인앱 자동 교체는 하지 않고 릴리스 페이지로 연결
- 릴리스 파이프라인 (T-AGO-30): `.github/workflows/release.yml` — `v*.*.*` 태그 푸시 → xcodegen → 태그 vs Info.plist 버전 일치 검증 → 테스트 → Release 빌드 → ad-hoc 서명 → DMG(`hdiutil`, /Applications 심링크 포함) → `gh release create`(`release-notes/<tag>.md` 본문). `build_and_run.sh package`도 ZIP에서 DMG로 변경 + Release 빌드
- 버전 범프 0.2.2 (project.yml — CHANGELOG와 정렬) + `release-notes/v0.2.2.md` 작성
- 테스트 신규 12종 (버전 숫자 비교·JSON 디코드·주기 판정) — 총 35/35 통과. 주의: xcodebuild 요약의 "Executed 0 tests"는 XCTest 카운터만 표시, Swift Testing 실적은 "Test run with 35 tests in 6 suites" 라인에서 확인
- 원인 규명 (Netutilus 실전 반복 실패): macOS 26 Gatekeeper는 실행 주체의 responsibility 체인을 본다. 미인정 런처(AGO)가 직접 `open`/`do shell script`/`launchctl asuser`로 띄우면 provenance DB(`TA 2cad28d7d4beaa7b`)에 allow rule이 없어 `Terminating process due to Gatekeeper rejection`. 동일 파일을 터미널에서 실행하면 항상 통과 — xattr 제거 유무와 무관 (속성 0개 복사본도 AGO에선 차단, 터미널선 통과 실측)
- 실행 위임 (T-AGO-27): `runLaunch` ①번을 `osascript tell Terminal to do script`로 교체 — 정품 Terminal.app 자식 셸에서 `xattr -dr && open -g` 실행 → 사용자 세션 책임 체인으로 우회. 최초 1회 TCC 자동화 허용 필요(일반 권한 팝업). ②직접 open·③asuser는 예비로 유지. 실측: 하네스 통과 → AGO 실전 Netutilus 실행 성공 확인
- 생존 감지 버그 수정 (실패 오판 원인): `launchAndAlive`가 하드코딩한 `/bin/pgrep`은 macOS 26에 없음(→ `/usr/bin/pgrep`). `runProcess`가 파일 미존재 예외로 항상 exit 1 반환 → 런칭 성공인데 판정 전부 false ("실행은 됐는데 실패" 로그). 경로 수정 + pgrep 재시도(3초 후 1회, 1.5초 간격 최대 3회)로 Terminal 위임의 지연 뜨기를 흡수
- 서명 건너뛰기 체크박스 (T-AGO-28): 하단바 `sign.skipToggle` 기본 체크 — 신원이 있어도 확인 다이얼로그 없이 자동 스킵(`skipSigning`). 해제 시 기존 다이얼로그 복귀. ko/en 키 3종(`sign.skipToggle`·`sign.skipToggleHelp`·`pipe.signAutoSkipped`)
- 빌드: `./build_and_run.sh run macos` 주의 — `APP_PATH` 존재 시 `cmd_run`이 빌드를 건너뛰므로 변경 후엔 `build` 먼저 실행 필요
- 검증: Terminal 위임 하네스 통과 · `/usr/bin/pgrep` 감지 실측(pid 매칭) · AGO 실전 1회 성공(자동 카운트다운 종료 확인)

## [v0.2.1] - 2026-09-22 (macos) — macOS 26 출처 속성(com.apple.provenance) 대응
- 원인 규명 (Netutilus 실전 사례): macOS 15 이후 인터넷 다운로드 파일에 붙는 `com.apple.provenance`가 quarantine 제거 후에도 남으면, macOS 26+는 실행 시점에 Gatekeeper 재평가로 "악성 코드 확인 불가" 확인 창을 다시 띄움. AGO(quarantine만 제거)에서는 실행 게이트를 열어도 OS가 막는 상태였음
- 대응 (T-AGO-26): 파이프라인 단계 2에서 `com.apple.provenance` 감지(`AppInspector.hasProvenance`) → 단계 3에서 quarantine과 함께 `xattr -dr com.apple.provenance` 제거. 감지/제거를 로그로 남기고 `PipelineVerdict.hadProvenance`에 기록, 통과·경고 카드 양쪽에 "함께 제거됨" 안내 표시
- 현지화: ko/en 키 3종 신설(`pipe.provenanceFound`·`pipe.provenanceRemoved`·`verdict.provenance`) + 도움말 s1b 갱신. 키 parity 유지
- 테스트 신규 (detectsProvenance: quarantine과 독립 감지, emptyVerdict에 hadProvenance 기본값) — 현재까지 스위트 그린
- macOS 26+ 연속 규명 (Netutilus 실전): quarantine/provenance를 지워도 `com.apple.macl`(드래그·"다음으로 열기" 권한 귀속 표식)이 남으면, 미인정 서명 앱이 TCC(개발자 도구 등) 요청 시점에 커널이 강제종료(exit 9). 같은 날 발견한 "수동 실행(3속성 제거+open)은 성공" 대비, AGO가 macl을 남기는 차이 확인
- 추가 대응 (T-AGO-26): `AppInspector.hasMacl` 신설 + 단계 3 정리 대상에 `com.apple.macl` 포함. 로그(`pipe.maclFound`·`pipe.maclRemoved` ko/en)로 감지·제거 기록, 테스트 `detectsMacl` 추가

## [v0.2.0] - 2026-09-18 (macos) — 서명 단계 (v1.1, PLAN_v1.1)
- 파이프라인 `.signing` 단계 (T-AGO-21): 판정 후 자동으로 서명 확인 다이얼로그(확인/스킵) → 확인 시 `codesign --force -s` 개별 서명 (중첩 코드 먼저, 본체 마지막). 서명 전 확인한 변조 증거는 서명 후에도 verdict에 유지
- 서명 대상 확대 (60SecondsReatomized 실패 사례 반영): `Contents/PlugIns`의 `.appex`·`.bundle` + `Contents/Frameworks`의 `.framework`·`.dylib` 경로 정렬 후 개별 서명. `errSecInternalComponent` 미서명 중첩(`steam_api.bundle` 등) 해소 — E2E: 사본 전체 서명 → `valid on disk` + spctl `rejected`(개발 서명) 확인
- 경고 카드 게이트 완화: 서명 후 현재 유효(`codesignValid`)하면 변조 증거가 있어도 경고 카드 + 체크박스 실행 허용 (`AppInspector.spctlAllowGate`). 미서명·무효 변조는 여전히 완전 차단 (E-MAC-PERM-2005)
- 신원 관련 (T-AGO-22~23): `security find-identity -v -p codesigning` 파싱 버그 수정(해시 뒤 따옴표 이름 추출), 신원 자동탐지→없으면 수동 입력 + 미등록자 Xcode 유도 시트 신규 (SignPromptView)
- UI (T-AGO-24): 타임라인 5단계(조회→제거→검증→평가→서명) + 서명 상태 표시. 한/영 문자열 19키 추가 (parity). 하단 버전 v0.2.0
- 정책 (T-AGO-25): 변조 앱도 서명 허용으로 개정 (PLAN/도움말/README.ko·README.md/사이트 ko·en 동기화). adhoc 서명 금지 유지
- 에러코드 신설: `E-MAC-PERM-2005` (변조 무효 증거 차단/서명 실패). error_message_ko.json 추가
- 테스트 21/21 통과 (신규: signTargets 순서 `.bundle`·`.dylib` 반영, spctlAllowGate 4케이스). 빌드+배포 `~/Applications/AGO.app` 완료

## [v0.1.0] - 2026-09-07 (macos) — GitHub 공개 + Release + Pages 배포 완료
- M2 파이프라인: `GatePipeline`(조회→제거→검증→평가→확인 후 실행, 취소 지원) + `AppInspector`(xattr/codesign/spctl 파싱) 추가
- 풀커스텀 UI: 히어로 드롭존(아이콘·버전 미리보기) · 4단계 타임라인 · 터미널 로그 카드(복사·자동스크롤) · 변조 경고 카드(체크박스 게이트) · 도움말 시트(`⌘/`) · 파일 열기(`⌘O`)
- 에러코드: E-MAC-PERM-2001~2004, E-MAC-VAL-2001~2002 사용. 점검 결과 `validationFailed` 케이스는 미사용(중복 매핑) — v1.1에서 정리 예정
- 배포: `./build_and_run.sh package macos` → `dist/AGO-0.1.0-macos.zip` (unsigned, ditto). Release 노트에 차단 해제 안내 필요
- 테스트 10/10 통과 (smoke+unit). 빌드 통과 (perf: Cold Start 측정 로그 유지, 예산 1500ms)
- 실전 검증 반영 (Keep It.app 사례): codesign 잡음(`--prepared/--validated`) 요약 표시 + spctl 거부 후에도 변조 경고 카드 유지 (실행은 여전히 차단). 테스트 11/11
- 서명 정상 + spctl 거부(개발용 서명, boringNotch 사례) → 완전 차단 대신 경고 카드 + 체크박스 후 실행 허용. 변조 증거 있으면 기존대로 차단. 테스트 16/16
- 로그 스크롤 수정 (`LazyVStack`→`VStack` + 레이아웃 후 스크롤 + 하단 여백) + 하단 버전 표시(v0.1.0, 실행 중 빌드 확인용)
- 상태 배지 개선: 아이콘+캡슐(`fixedSize`, 찌그러짐 수정) + 단계별 툴팁 설명
- 하단 제작 정보: 제작 BoRaSaRang · 문의하기(메일) · GitHub 링크 (저장소 개설 후 연결됨). 링크는 종료 왼쪽 배치
- 상태 배지 제거 (타임라인·경고 카드와 중복, 툴바 렌더링 문제 원천 해소)
- 실행 성공 후 5초 카운트다운 → 자동 종료 (실행 버튼 자리에 "자동으로 종료됩니다… N" 표시)
- 앱 내 한/영 지원 (T-AGO-20): `Localizable.strings` en/ko 60종 + 전 UI·파이프라인 로그·에러 교체. 영문 실행 검증됨 (타이틀 Automatic Gate Opener)
- 리팩토링: 미사용 코드 제거 (`statusText`·`logText`·`validationFailed` 중복 케이스·`SkeletonTests` 중복) + 프로세스 실패 로그 현지화. 테스트 17/17
- MIT 라이선스 확정 + 랜딩/README에 실물 스크린샷 연결 (히어로 한/영, 경고 상태 한/영)
- 문서 언어 정리: README.md(영문 기본) + README.ko.md(한글), 한글 전면 다듬기 (비격식 표현·번역체 정리, 랜딩 로케일 일치)
- 이름 현지화 (가이드 준수): 번들 `AGO.app` 유지, 시스템 한국어→`열어줘`, 영어→`Automatic Gate Opener` (Launch Services 검증됨). `Sources/AGO/Info.plist`는 xcodegen 생성물 — 키는 `project.yml` > `info.properties`에 선언
- 앱 아이콘 적용 (`Resources/AppIcon.icns`, `CFBundleIconFile`)

## [v0.0] - 2026-09-07 (macos)
- 프로젝트 뼈대 생성: `project.yml`(xcodegen), `build_and_run.sh`, 최소 셸(`AGOApp`+핀 토글 스켈레톤), `DebugLogger`, `AppError` 7종
- 문서 4종 작성: PLAN/TODO/DESIGN/CHANGELOG
- 스켈레톤 빌드 + 테스트 통과 (perf: Cold Start 측정 로그 포함, 예산 1500ms)
