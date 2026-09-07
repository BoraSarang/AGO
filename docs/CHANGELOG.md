# CHANGELOG - AGO

> 모든 기록은 한국어. platform 태그 + error_code + perf 영향 포함.

## [v0.1.0] - 2026-09-07 (macos) — 로컬 마무리 (GitHub 발행 보류)
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
- 이름 현지화 (가이드 준수): 번들 `AGO.app` 유지, 시스템 한국어→`열어줘`, 영어→`Automatic Gate Opener` (Launch Services 검증됨). `Sources/AGO/Info.plist`는 xcodegen 생성물 — 키는 `project.yml` > `info.properties`에 선언
- 앱 아이콘 적용 (`Resources/AppIcon.icns`, `CFBundleIconFile`)

## [v0.0] - 2026-09-07 (macos)
- 프로젝트 뼈대 생성: `project.yml`(xcodegen), `build_and_run.sh`, 최소 셸(`AGOApp`+핀 토글 스켈레톤), `DebugLogger`, `AppError` 7종
- 문서 4종 작성: PLAN/TODO/DESIGN/CHANGELOG
- 스켈레톤 빌드 + 테스트 통과 (perf: Cold Start 측정 로그 포함, 예산 1500ms)
