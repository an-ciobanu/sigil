#!/usr/bin/env bash
# vexscan bootstrap. Two paths:
#   1. Fast path: download a pre-built binary from a Sigil release matching
#      the pinned commit, verify SHA256 against checksums.txt, install.
#   2. Source build (fallback): clone vexscan at the pinned commit, copy our
#      pinned Cargo.lock into the clone, run cargo build --release --locked,
#      install. Used when the release artifact is unavailable for the
#      current platform or download fails.
#
# Trust anchor for the fast path: (commit SHA, checksums.txt) — both
# committed to Sigil's repo, so a release artifact that doesn't match what
# we audited is rejected at install time.
#
# Trust anchor for the fallback: (commit SHA, Cargo.lock) — same as before.
#
# Override SIGIL_VEXSCAN_FROM_SOURCE=1 to force the source build (skip
# release download). Useful when the user wants the strongest verification
# property: rebuild from audited source rather than trust the maintainer's
# release.

_VEXSCAN_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=../state.sh
source "${_VEXSCAN_LIB_DIR}/../state.sh"
# shellcheck source=pin.sh
source "${_VEXSCAN_LIB_DIR}/pin.sh"

VEXSCAN_PIN_LOCKFILE="${_VEXSCAN_LIB_DIR}/Cargo.lock"
VEXSCAN_PIN_CHECKSUMS="${_VEXSCAN_LIB_DIR}/checksums.txt"

# Override for testing or forks. Default is the canonical Sigil repo.
SIGIL_VEXSCAN_RELEASE_BASE="${SIGIL_VEXSCAN_RELEASE_BASE:-https://github.com/an-ciobanu/sigil}"

sigil_vexscan_short_sha() {
    printf '%s' "${VEXSCAN_PIN_COMMIT:0:7}"
}

sigil_vexscan_binary_path() {
    printf '%s/vexscan-%s' "${SIGIL_VEXSCAN_DIR}" "$(sigil_vexscan_short_sha)"
}

sigil_vexscan_is_installed() {
    [[ -x "$(sigil_vexscan_binary_path)" ]]
}

# Maps `uname -s/-m` to a release asset name, e.g. "vexscan-macos-aarch64".
# Returns 1 on unsupported platform.
sigil_vexscan_platform() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux) os="linux" ;;
        *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) return 1 ;;
    esac
    printf 'vexscan-%s-%s' "${os}" "${arch}"
}

sigil_vexscan_release_url() {
    local platform
    platform="$(sigil_vexscan_platform)" || return 1
    printf '%s/releases/download/vexscan-%s/%s' \
        "${SIGIL_VEXSCAN_RELEASE_BASE}" \
        "$(sigil_vexscan_short_sha)" \
        "${platform}"
}

# Looks up the expected sha256 for the current platform from checksums.txt.
# Returns 1 if no entry exists for the current platform.
# Pattern enforces 64 hex chars + two spaces + platform + EOL, so a malformed
# line or substring collision can't yield a fake match.
sigil_vexscan_expected_sha256() {
    local platform
    platform="$(sigil_vexscan_platform)" || return 1
    local line
    line="$(grep -E "^[0-9a-f]{64}  ${platform}[[:space:]]*\$" "${VEXSCAN_PIN_CHECKSUMS}" 2>/dev/null)" || return 1
    printf '%s' "${line%% *}"
}

# Cross-platform SHA-256 of a file. macOS has shasum; Linux has sha256sum.
sigil_compute_sha256() {
    local file="$1"
    if command -v sha256sum &> /dev/null; then
        sha256sum "${file}" | awk '{print $1}'
    elif command -v shasum &> /dev/null; then
        shasum -a 256 "${file}" | awk '{print $1}'
    else
        echo "ERROR: need sha256sum or shasum to verify download" >&2
        return 1
    fi
}

# Try to install vexscan from a pre-built release artifact.
# Returns:
#   0 on success
#   1 on recoverable failure (caller may fall back to source build)
#   2 on hard failure (SHA mismatch — DO NOT silently fall back)
sigil_vexscan_install_from_release() {
    if ! command -v curl &> /dev/null; then
        echo "curl not available; skipping release download" >&2
        return 1
    fi

    local platform url expected_sha
    if ! platform="$(sigil_vexscan_platform)"; then
        echo "Unsupported platform for release download (uname: $(uname -sm))" >&2
        return 1
    fi
    if ! expected_sha="$(sigil_vexscan_expected_sha256)"; then
        echo "No checksum for ${platform} in checksums.txt; skipping release download" >&2
        return 1
    fi
    url="$(sigil_vexscan_release_url)" || return 1

    local target_binary tmp_binary
    target_binary="$(sigil_vexscan_binary_path)"
    if ! tmp_binary="$(mktemp "${target_binary}.download.XXXXXX")"; then
        echo "ERROR: failed to create temp file for download" >&2
        return 1
    fi

    echo "Downloading vexscan from ${url}..." >&2
    # curl follows redirects; redirect target is NOT trusted. The SHA-256
    # verification below is the gate that decides whether to install.
    if ! curl -fsSL --max-time 60 "${url}" -o "${tmp_binary}"; then
        rm -f "${tmp_binary}"
        echo "Release download failed (${url})" >&2
        return 1
    fi

    local actual_sha
    if ! actual_sha="$(sigil_compute_sha256 "${tmp_binary}")"; then
        rm -f "${tmp_binary}"
        return 1
    fi

    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
        rm -f "${tmp_binary}"
        echo "ERROR: SHA-256 mismatch on downloaded vexscan binary" >&2
        echo "  expected: ${expected_sha}" >&2
        echo "  got:      ${actual_sha}" >&2
        echo "  This is a HARD FAIL. The release artifact does not match what" >&2
        echo "  we audited. Do not proceed; investigate the release first." >&2
        return 2
    fi

    chmod +x "${tmp_binary}"
    mv "${tmp_binary}" "${target_binary}"
    echo "vexscan installed (release) at ${target_binary}" >&2
    return 0
}

# Build vexscan from source at the pinned commit, using our pinned Cargo.lock.
sigil_vexscan_install_from_source() {
    if ! command -v git &> /dev/null; then
        echo "ERROR: git is required for source build" >&2
        return 1
    fi
    if ! command -v cargo &> /dev/null; then
        echo "ERROR: cargo (Rust toolchain) is required for source build" >&2
        echo "       Install: https://rustup.rs/" >&2
        return 1
    fi
    if [[ ! -f "${VEXSCAN_PIN_LOCKFILE}" ]]; then
        echo "ERROR: pinned Cargo.lock not found at ${VEXSCAN_PIN_LOCKFILE}" >&2
        return 1
    fi

    local build_dir="${SIGIL_VEXSCAN_DIR}/build-$(sigil_vexscan_short_sha)"
    rm -rf "${build_dir}"

    echo "Cloning ${VEXSCAN_PIN_REPO}..." >&2
    if ! git clone --quiet "${VEXSCAN_PIN_REPO}" "${build_dir}"; then
        echo "ERROR: failed to clone vexscan from ${VEXSCAN_PIN_REPO}" >&2
        return 1
    fi

    if ! git -C "${build_dir}" checkout --quiet "${VEXSCAN_PIN_COMMIT}" 2>/dev/null; then
        echo "ERROR: pinned commit ${VEXSCAN_PIN_COMMIT} not found in clone" >&2
        rm -rf "${build_dir}"
        return 1
    fi

    local actual_sha
    actual_sha="$(git -C "${build_dir}" rev-parse HEAD)"
    if [[ "${actual_sha}" != "${VEXSCAN_PIN_COMMIT}" ]]; then
        # Defensive: should be impossible after a successful checkout, but if
        # the repo is somehow tampered, this catches it before we run cargo.
        echo "ERROR: vexscan commit SHA mismatch after checkout" >&2
        echo "  expected: ${VEXSCAN_PIN_COMMIT}" >&2
        echo "  got:      ${actual_sha}" >&2
        rm -rf "${build_dir}"
        return 1
    fi

    cp "${VEXSCAN_PIN_LOCKFILE}" "${build_dir}/Cargo.lock"

    echo "Building vexscan from source (this takes a few minutes on first run)..." >&2
    if ! (cd "${build_dir}" && cargo build --release --locked); then
        echo "ERROR: cargo build failed" >&2
        rm -rf "${build_dir}"
        return 1
    fi

    local built_binary="${build_dir}/target/release/vexscan"
    if [[ ! -x "${built_binary}" ]]; then
        echo "ERROR: build did not produce executable at ${built_binary}" >&2
        rm -rf "${build_dir}"
        return 1
    fi

    local target_binary
    target_binary="$(sigil_vexscan_binary_path)"
    mv "${built_binary}" "${target_binary}"
    chmod +x "${target_binary}"
    rm -rf "${build_dir}"

    echo "vexscan installed (source) at ${target_binary}" >&2
    return 0
}

# Idempotent. Try fast path (release download), fall back to source build.
sigil_vexscan_bootstrap() {
    if sigil_vexscan_is_installed; then
        return 0
    fi

    sigil_ensure_state_dir

    if [[ -z "${SIGIL_VEXSCAN_FROM_SOURCE:-}" ]]; then
        # Capture the return code with `|| rc=$?` so `set -e` in callers
        # doesn't abort us before we can route on the value.
        local rc=0
        sigil_vexscan_install_from_release || rc=$?
        case "${rc}" in
            0) return 0 ;;
            1) echo "Falling back to source build..." >&2 ;;
            2) return 1 ;;  # hard fail — never silently fall back
        esac
    fi

    sigil_vexscan_install_from_source
}
