# 열어줘 (AGO — Automatic Gate Opener)

> 받은 맥 앱이 바로 열리지 않을 때 — 드래그 한 번이면 실행 준비 완료.
>
> [English](README.en.md) · [릴리스](https://github.com/BoraSarang/AGO/releases) · [소개 페이지](https://borasarang.github.io/AGO/)

![열어줘 실행 화면](site/images/ago-hero.png)

---

## 개발 배경

인터넷(브라우저·메신저)으로 받은 `.app`에는 차단 속성(`com.apple.quarantine`)이 붙습니다.
그래서 바로 열리지 않고 시스템 설정 → 개인정보 보호 및 보안에서 "확인 없이 열기"를 눌러줘야 합니다.
열어줘는 이 귀찮음을 드래그 한 번으로 끝내는 작은 macOS 유틸리티입니다.

## 사용 사례

- DMG 없이 받은 `.app`, 압축 풀자마자 실행이 막히는 앱을 열 때
- "손상되었기 때문에 열 수 없습니다"가 아니라 **차단 속성 문제**인 경우를 빠르게 처리할 때
- 단, 서명이 깨진 앱은 그냥 통과시키지 않고 **경고 후에만** 실행할 때

## 사용 방법

1. `.app`을 열어줘 창에 드래그 (또는 `⌘O`로 선택)
2. 파이프라인이 끝까지 자동 실행: 확인 → 제거 → 검증 → 평가
3. 결과에 따라 **실행 버튼**이 활성화되면 직접 눌러서 실행 (자동 실행 없음)

## 메시지별 대응 방법

| 화면 메시지 | 의미 | 할 일 |
|---|---|---|
| `차단 속성 제거됨` | quarantine 제거 성공 | 그대로 진행 |
| `서명 정상 (valid on disk)` + `Gatekeeper 평가 통과` | 검사 통과 | 실행 버튼으로 실행 |
| `변조 의심: N개 파일 추가·수정됨` | 서명과 실제 파일 불일치 (dylib 주입 등) | 빨간 경고 카드 확인 → 공식 출처 재설치 권장. 그래도 실행하려면 체크박스 선택 후 실행 |
| `개발용 서명 — 공식 배포 서명이 아니라 Gatekeeper가 거부합니다` | 개발 인증서 서명 (배포용 아님). 악성 아님 | 경고 카드 확인 → 체크박스 선택 후 실행 |
| `Gatekeeper가 실행을 거부했습니다` | 평가 실패 + 변조 증거 있음 | 실행 불가. 공식 출처에서 다시 받기 |
| `차단 속성 제거에 실패했습니다` | 권한 문제 (주로 `/Applications` 안) | 앱을 다른 폴더(예: `~/Downloads`)로 옮겨서 다시 시도 |

## 보안 정책

하지 않는 일:

- 강제 재서명 (`codesign --force`) 없음 — 변조 증거를 덮어버리므로
- `sudo` 자동 승격 없음
- 사용자 확인 없는 자동 실행 없음
- `.dmg` 처리 없음 (v1 범위 밖)

## 설치

1. [Releases](https://github.com/BoraSarang/AGO/releases)에서 `AGO-<버전>-macos.zip` 다운로드
2. 압축 해제 후 `AGO.app`을 `/Applications`에 복사
3. 첫 실행 시 차단 경고가 뜨면: `xattr -dr com.apple.quarantine ~/Downloads/AGO-*.zip` 후 압축 해제
   (서명 없는 배포판이라 macOS가 1회 차단합니다)

## 소스에서 빌드

요구 사항: Xcode 26+, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```bash
xcodegen generate
./build_and_run.sh build macos   # → ~/Applications/AGO.app 배치
./build_and_run.sh test macos unit
./build_and_run.sh package macos # → dist/AGO-<버전>-macos.zip (VERSION=0.2.0 지정 가능)
```

> `Sources/AGO/Info.plist`는 xcodegen 생성물입니다. 직접 수정 금지 — 키는 `project.yml` > `info.properties`에 선언합니다.

## 프로젝트 문서

- `docs/plans/PLAN_v1.0_macos.md` — 명세
- `docs/DESIGN.md` — 디자인 (풀커스텀 콘텐츠 + 네이티브 크롬)
- `docs/TODO.md` — 작업 목록
- `docs/CHANGELOG.md` — 변경 기록

## 제작·문의

- 제작: BoRaSaRang (`leeborasarang@gmail.com`)
- 버그 제보·질문: [Issues](https://github.com/BoraSarang/AGO/issues)

## 라이선스

MIT — [LICENSE](LICENSE) 참조.
