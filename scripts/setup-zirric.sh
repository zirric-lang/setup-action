#!/usr/bin/env bash
# Downloads a zirric release archive, puts the binary on PATH and exports ZIRRIC_PATH.
#
# Inputs are passed as environment variables (see action.yml):
#   ZIRRIC_SETUP_VERSION, ZIRRIC_SETUP_VERSION_FILE, ZIRRIC_SETUP_PRERELEASE,
#   ZIRRIC_SETUP_FORGE_URL, ZIRRIC_SETUP_REPOSITORY, ZIRRIC_SETUP_TOKEN,
#   ZIRRIC_SETUP_INSTALL_DIR, ZIRRIC_SETUP_ZIRRIC_PATH, ZIRRIC_SETUP_VERIFY_CHECKSUM
set -euo pipefail

VERSION_INPUT="${ZIRRIC_SETUP_VERSION:-latest}"
VERSION_FILE="${ZIRRIC_SETUP_VERSION_FILE:-}"
ALLOW_PRERELEASE="${ZIRRIC_SETUP_PRERELEASE:-false}"
FORGE_URL="${ZIRRIC_SETUP_FORGE_URL:-https://code.knabel.dev}"
REPOSITORY="${ZIRRIC_SETUP_REPOSITORY:-zirric-lang/zirric}"
TOKEN="${ZIRRIC_SETUP_TOKEN:-}"
INSTALL_DIR_INPUT="${ZIRRIC_SETUP_INSTALL_DIR:-}"
ZIRRIC_HOME_INPUT="${ZIRRIC_SETUP_ZIRRIC_PATH:-}"
VERIFY_CHECKSUM="${ZIRRIC_SETUP_VERIFY_CHECKSUM:-true}"

FORGE_URL="${FORGE_URL%/}"
API="${FORGE_URL}/api/v1/repos/${REPOSITORY}"

info() { printf 'zirric-setup: %s\n' "$*"; }
die() { printf 'zirric-setup: error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
is_true() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in true|yes|1|on) return 0 ;; *) return 1 ;; esac; }

# http <url> <output-file>; "-" writes to stdout.
http() {
  local url="$1" out="${2:--}"
  if have curl; then
    local args=(--fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 20 --output "$out")
    [ -n "$TOKEN" ] && args+=(--header "Authorization: token ${TOKEN}")
    curl "${args[@]}" "$url"
  elif have wget; then
    local args=(--quiet --tries=3 --timeout=20 -O "$out")
    [ -n "$TOKEN" ] && args+=(--header="Authorization: token ${TOKEN}")
    wget "${args[@]}" "$url"
  else
    die "neither curl nor wget is available"
  fi
}

# read_version_file <path> -> version string
read_version_file() {
  local file="$1" line
  [ -f "$file" ] || die "version file not found: ${file}"
  case "$file" in
    *.tool-versions|*/.tool-versions|.tool-versions)
      line="$(grep -E '^[[:space:]]*zirric[[:space:]]+' "$file" | head -n 1 | awk '{print $2}')"
      ;;
    *)
      # First meaningful line; tolerates both "1.2.3" and "zirric 1.2.3".
      line="$(grep -vE '^[[:space:]]*(#|$)' "$file" | head -n 1 | awk '{print $NF}')"
      ;;
  esac
  line="$(printf '%s' "${line:-}" | tr -d '[:space:]')"
  [ -n "$line" ] || die "no zirric version found in ${file}"
  printf '%s' "$line"
}

# resolve_latest -> newest non-draft release tag
resolve_latest() {
  local json tags flags pair tag flag
  json="$(http "${API}/releases?limit=50&draft=false" -)" \
    || die "could not list releases of ${REPOSITORY} at ${FORGE_URL}"
  tags="$(printf '%s' "$json" | grep -o '"tag_name":"[^"]*"' | sed 's/.*:"//; s/"$//')"
  [ -n "$tags" ] || die "no releases found for ${REPOSITORY} at ${FORGE_URL}"

  if is_true "$ALLOW_PRERELEASE"; then
    printf '%s' "$tags" | head -n 1
    return 0
  fi

  flags="$(printf '%s' "$json" | grep -oE '"prerelease":(true|false)' | sed 's/.*://')"
  while IFS=' ' read -r tag flag; do
    [ "$flag" = "false" ] || continue
    printf '%s' "$tag"
    return 0
  done < <(paste -d' ' <(printf '%s\n' "$tags") <(printf '%s\n' "$flags"))

  die "no stable release found for ${REPOSITORY}; set prerelease: true to allow pre-releases, or pin a tag"
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  elif have openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1
  fi
}

set_output() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT" || true; }
set_env() {
  export "$1=$2"
  [ -n "${GITHUB_ENV:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_ENV" || true
}
add_path() {
  if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\n' "$1" >>"$GITHUB_PATH"; fi
  export PATH="$1:${PATH}"
}

# --- resolve the version ------------------------------------------------------
if [ -n "$VERSION_FILE" ]; then
  VERSION_INPUT="$(read_version_file "$VERSION_FILE")"
  info "using version ${VERSION_INPUT} from ${VERSION_FILE}"
fi

VERSION_INPUT="$(printf '%s' "$VERSION_INPUT" | tr -d '[:space:]')"
[ -n "$VERSION_INPUT" ] && [ "$VERSION_INPUT" != "*" ] || VERSION_INPUT="latest"

case "$VERSION_INPUT" in
  latest|LATEST)
    TAG="$(resolve_latest)"
    info "resolved latest to ${TAG}"
    ;;
  v*) TAG="$VERSION_INPUT" ;;
  *)  TAG="v${VERSION_INPUT}" ;;
esac
VERSION="${TAG#v}"

# --- detect the platform ------------------------------------------------------
case "${RUNNER_OS:-$(uname -s)}" in
  Linux|Linux*)               OS=Linux ;;
  macOS|Darwin|Darwin*)       OS=Darwin ;;
  Windows|MINGW*|MSYS*|CYGWIN*|Windows_NT) OS=Windows ;;
  *) die "unsupported operating system: ${RUNNER_OS:-$(uname -s)}" ;;
esac

case "${RUNNER_ARCH:-$(uname -m)}" in
  X64|x86_64|amd64)      ARCH=x86_64 ;;
  ARM64|arm64|aarch64)   ARCH=arm64 ;;
  *) die "unsupported architecture: ${RUNNER_ARCH:-$(uname -m)}; zirric ships x86_64 and arm64 builds" ;;
esac

if [ "$OS" = Windows ]; then
  EXT=zip
  BIN=zirric.exe
else
  EXT=tar.gz
  BIN=zirric
fi
ARCHIVE="zirric_${OS}_${ARCH}.${EXT}"

# --- install ------------------------------------------------------------------
TOOL_CACHE="${RUNNER_TOOL_CACHE:-${HOME}/.cache/zirric-tools}"
INSTALL_DIR="${INSTALL_DIR_INPUT:-${TOOL_CACHE}/zirric/${VERSION}/${ARCH}}"
CACHE_HIT=false

if [ -x "${INSTALL_DIR}/${BIN}" ]; then
  CACHE_HIT=true
  info "found cached zirric ${VERSION} in ${INSTALL_DIR}"
else
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT
  mkdir -p "${TMP_DIR}/extract"

  DOWNLOAD_URL="${FORGE_URL}/${REPOSITORY}/releases/download/${TAG}/${ARCHIVE}"
  info "downloading ${DOWNLOAD_URL}"
  http "$DOWNLOAD_URL" "${TMP_DIR}/${ARCHIVE}" \
    || die "could not download ${ARCHIVE} for ${TAG}; check that the release exists and ships ${OS}/${ARCH} archives"

  if is_true "$VERIFY_CHECKSUM"; then
    if http "${FORGE_URL}/${REPOSITORY}/releases/download/${TAG}/checksums.txt" "${TMP_DIR}/checksums.txt"; then
      expected="$(awk -v name="$ARCHIVE" '$2 == name || $2 == "*" name {print $1}' "${TMP_DIR}/checksums.txt" | head -n 1)"
      [ -n "$expected" ] || die "checksums.txt of ${TAG} has no entry for ${ARCHIVE}"
      actual="$(sha256_of "${TMP_DIR}/${ARCHIVE}")" \
        || die "no sha256 tool (sha256sum, shasum, openssl) found; set verify-checksum: false to skip verification"
      [ "$expected" = "$actual" ] \
        || die "checksum mismatch for ${ARCHIVE}: expected ${expected}, got ${actual}"
      info "verified sha256 ${actual}"
    else
      die "could not download checksums.txt of ${TAG}; set verify-checksum: false to skip verification"
    fi
  fi

  case "$EXT" in
    tar.gz) tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}/extract" ;;
    zip)
      if have unzip; then unzip -q "${TMP_DIR}/${ARCHIVE}" -d "${TMP_DIR}/extract"
      else tar -xf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}/extract"
      fi
      ;;
  esac

  BIN_SRC="$(find "${TMP_DIR}/extract" -maxdepth 2 -type f -name "$BIN" | head -n 1)"
  [ -n "$BIN_SRC" ] || die "${ARCHIVE} did not contain ${BIN}"

  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  cp -R "$(dirname "$BIN_SRC")/." "${INSTALL_DIR}/"
  chmod +x "${INSTALL_DIR}/${BIN}"
  info "installed zirric ${VERSION} to ${INSTALL_DIR}"
fi

# --- wire up the environment --------------------------------------------------
PATH_ENTRY="$INSTALL_DIR"
if [ "$OS" = Windows ] && have cygpath; then
  PATH_ENTRY="$(cygpath -w "$INSTALL_DIR")"
fi
add_path "$PATH_ENTRY"

ZIRRIC_HOME="${ZIRRIC_HOME_INPUT:-${HOME}/.zirric}"
mkdir -p "${ZIRRIC_HOME}/registry"
set_env ZIRRIC_PATH "$ZIRRIC_HOME"

"${INSTALL_DIR}/${BIN}" --help >/dev/null 2>&1 \
  || die "the installed binary at ${INSTALL_DIR}/${BIN} is not runnable on this machine"

set_output zirric-version "$VERSION"
set_output zirric-tag "$TAG"
set_output zirric-bin "${INSTALL_DIR}/${BIN}"
set_output zirric-dir "$INSTALL_DIR"
set_output zirric-path "$ZIRRIC_HOME"
set_output cache-hit "$CACHE_HIT"

info "zirric ${VERSION} ready (ZIRRIC_PATH=${ZIRRIC_HOME})"
