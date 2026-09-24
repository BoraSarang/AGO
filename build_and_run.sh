#!/usr/bin/env bash
# build_and_run.sh - AGO macOS 앱 빌드/실행 스크립트
# 사용법: ./build_and_run.sh <command> [platform] [options]
# 예: ./build_and_run.sh build macos
#     ./build_and_run.sh test macos smoke
#     ./build_and_run.sh debug macos
#     ./build_and_run.sh run macos

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────────────────────
PROJECT_NAME="AGO"
BUNDLE_ID="com.borasarang.ago"
VERSION="${VERSION:-0.2.3}"
XCODE_PROJECT="${PROJECT_NAME}.xcodeproj"
SCHEME="${PROJECT_NAME}"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${PWD}/.build/derived_data"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${PROJECT_NAME}.app"
TARGET_APP_PATH="${HOME}/Applications/${PROJECT_NAME}.app"
DIST_DIR="${PWD}/dist"
ZIP_PATH="${DIST_DIR}/${PROJECT_NAME}-${VERSION}-macos.zip"

# ──────────────────────────────────────────────────────────────
# 유틸리티 함수
# ──────────────────────────────────────────────────────────────
log_info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
log_ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

check_env_expiry() {
  log_info "환경변수 만료 체크 중..."
  if [[ -f ".env.expiry" ]]; then
    local expiry=$(cat .env.expiry)
    local now=$(date +%s)
    local days_left=$(( (expiry - now) / 86400 ))
    if [[ $days_left -lt 0 ]]; then
      log_error ".env 만료됨 (${days_left}일 전). 갱신 필요."
      exit 1
    elif [[ $days_left -le 30 ]]; then
      log_warn ".env 만료 임박: ${days_left}일 남음"
    else
      log_ok ".env 유효: ${days_left}일 남음"
    fi
  else
    log_warn ".env.expiry 파일 없음 (선택사항)"
  fi
}

run_gitleaks() {
  log_info "Gitleaks 시크릿 스캔..."
  if command -v gitleaks &>/dev/null; then
    gitleaks detect --source . --verbose --no-banner || {
      log_error "Gitleaks 감지됨. 커밋 전 시크릿 제거 필요."
      exit 1
    }
    log_ok "Gitleaks 통과"
  else
    log_warn "gitleaks 미설치 (brew install gitleaks)"
  fi
}

# ──────────────────────────────────────────────────────────────
# 서브커맨드
# ──────────────────────────────────────────────────────────────
cmd_build() {
  local platform="${1:-macos}"
  log_info "빌드 시작: ${platform} (${CONFIGURATION})"

  check_env_expiry
  run_gitleaks

  xcodebuild \
    -project "${XCODE_PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -quiet \
    build

  log_ok "빌드 완료: ${APP_PATH}"

  # 결과물을 ~/Applications (= /Users/lee/Applications)에 배치 (PLAN 명세)
  mkdir -p "${HOME}/Applications"
  if [[ -d "${TARGET_APP_PATH}" ]]; then
    log_info "기존 앱 제거: ${TARGET_APP_PATH}"
    rm -rf "${TARGET_APP_PATH}"
  fi
  log_info "앱 복사: ${TARGET_APP_PATH}"
  cp -R "${APP_PATH}" "${TARGET_APP_PATH}"
  log_ok "배치 완료: ${TARGET_APP_PATH}"
}

cmd_test() {
  local platform="${1:-macos}"
  local test_type="${2:-smoke}"

  log_info "테스트 실행: ${platform} (${test_type})"

  case "${test_type}" in
    smoke|unit|full)
      xcodebuild \
        -project "${XCODE_PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        test
      ;;
    *)
      log_error "알 수 없는 테스트 타입: ${test_type} (smoke|unit|full)"
      exit 1
      ;;
  esac

  log_ok "테스트 완료 (${test_type})"
}

cmd_debug() {
  local platform="${1:-macos}"

  cmd_build "${platform}"

  log_info "DebugPanel 검증용 앱 실행..."
  open "${APP_PATH}"

  log_ok "앱 실행됨. 로그 확인 (Console.app: subsystem com.borasarang.ago)"
}

cmd_run() {
  local platform="${1:-macos}"

  # 항상 재빌드 (APP_PATH가 이미 있으면 구 빌드를 배포하는 함정 방지)
  cmd_build "${platform}"

  # 기존 앱 제거 후 복사
  if [[ -d "${TARGET_APP_PATH}" ]]; then
    log_info "기존 앱 제거: ${TARGET_APP_PATH}"
    rm -rf "${TARGET_APP_PATH}"
  fi

  log_info "앱 복사: ${TARGET_APP_PATH}"
  cp -R "${APP_PATH}" "${TARGET_APP_PATH}"

  log_info "앱 실행..."
  open "${TARGET_APP_PATH}"

  log_ok "실행 완료"
}

cmd_clean() {
  log_info "빌드 산출물 정리..."
  rm -rf "${DERIVED_DATA_PATH}"
  rm -rf "${TARGET_APP_PATH}"
  log_ok "정리 완료"
}

cmd_package() {
  local platform="${1:-macos}"

  # 배포 패키징은 Release로 (Debug 아티팩트 배포 방지)
  CONFIGURATION="Release"
  APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${PROJECT_NAME}.app"
  cmd_build "${platform}"

  if [[ ! -d "${APP_PATH}" ]]; then
    log_error "빌드된 앱 없음: ${APP_PATH}"
    exit 1
  fi

  mkdir -p "${DIST_DIR}"
  local dmg_path="${DIST_DIR}/${PROJECT_NAME}-${VERSION}-macos.dmg"
  if [[ -f "${dmg_path}" ]]; then
    log_info "기존 DMG 제거: ${dmg_path}"
    rm -f "${dmg_path}"
  fi

  # DMG: 앱 + /Applications 심링크 (가이드 LiteRT-LM Studio 방식)
  local staging
  staging="$(mktemp -d)"
  cp -R "${APP_PATH}" "${staging}/"
  ln -s /Applications "${staging}/Applications"

  log_info "DMG 패키징 (unsigned): ${dmg_path}"
  hdiutil create -volname "${PROJECT_NAME} ${VERSION}" \
    -srcfolder "${staging}" -ov -format UDZO "${dmg_path}"
  rm -rf "${staging}"

  log_ok "패키징 완료: ${dmg_path}"
  log_warn "unsigned 배포 — 첫 실행 우클릭→열기 안내 포함 필요"
}

# ──────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────
main() {
  local command="${1:-help}"

  case "${command}" in
    build|test|debug|run|clean|package)
      cmd_"${command}" "${@:2}"
      ;;
    help|--help|-h)
      cat <<EOF
사용법: ./build_and_run.sh <command> [args...]
       VERSION=0.2.0 ./build_and_run.sh package macos  (버전 지정)

Commands:
  build [platform]           빌드 (기본: macos)
  test [platform] [type]     테스트 실행 (smoke|unit|full, 기본: smoke)
  debug [platform]           빌드 + 디버그 앱 실행
  run [platform]             빌드 + ~/Applications 복사 + 실행
  package [platform]         빌드(Release) + DMG 패키징 → dist/ (GitHub Release용, unsigned)
  clean                      빌드 산출물 정리
  help                       이 도움말

Platforms:
  macos (현재만 지원)

Examples:
  ./build_and_run.sh build macos
  ./build_and_run.sh test macos smoke
  ./build_and_run.sh debug macos
  ./build_and_run.sh run macos
EOF
      ;;
    *)
      log_error "알 수 없는 명령: ${command}"
      exit 1
      ;;
  esac
}

main "$@"
