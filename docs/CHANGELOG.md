# CHANGELOG - AGO

> 모든 기록은 한국어. platform 태그 + error_code + perf 영향 포함.

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
