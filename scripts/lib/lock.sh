#!/usr/bin/env bash
# Cross-platform mutex for serializing Sigil state-mutating operations.
# SessionStart hooks, slash commands, and scheduled tasks may run
# concurrently; this lock prevents manifest corruption and racing clones.
#
# Primitive: mkdir is POSIX-atomic and works without flock(1) (which macOS
# lacks). Holder writes its PID inside the lock dir so a stale lock from a
# killed process is detected and reclaimed automatically.

_LOCK_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=state.sh
source "${_LOCK_LIB_DIR}/state.sh"

SIGIL_LOCK_DEFAULT_TIMEOUT="${SIGIL_LOCK_DEFAULT_TIMEOUT:-30}"

# Acquire exclusive lock on the Sigil state directory.
# Args: [timeout_seconds]  (default: SIGIL_LOCK_DEFAULT_TIMEOUT, i.e. 30)
# Returns: 0 on success, 1 on timeout.
#
# Timeout guidance:
#   - SessionStart hooks should use a short timeout (e.g., 0-2 seconds)
#     so that an in-flight scan or update doesn't block the user's session.
#   - Interactive commands (/sigil:add, /sigil:update) should use the
#     default 30s — long enough to survive a concurrent scan finishing,
#     short enough to fail clearly if something is genuinely stuck.
sigil_acquire_lock() {
    local timeout="${1:-${SIGIL_LOCK_DEFAULT_TIMEOUT}}"
    local elapsed=0

    sigil_ensure_state_dir

    while true; do
        if mkdir "${SIGIL_LOCK_PATH}" 2>/dev/null; then
            echo "$$" > "${SIGIL_LOCK_PATH}/pid"
            return 0
        fi

        local holder_pid
        holder_pid="$(cat "${SIGIL_LOCK_PATH}/pid" 2>/dev/null || true)"
        # kill -0 returns 0 iff PID is live AND we have permission to signal it.
        # If the holder is dead, the lock is stale and we reclaim it.
        if [[ -n "${holder_pid}" ]] && ! kill -0 "${holder_pid}" 2>/dev/null; then
            # Race-safe cleanup: rename the stale dir first (atomic), then
            # remove. If two processes both detect the stale lock, only one
            # mv succeeds; the other's mv silently fails and it loops to
            # retry mkdir. This prevents the rm-rf-then-mkdir window where
            # a fresh acquirer could be torn down.
            if mv "${SIGIL_LOCK_PATH}" "${SIGIL_LOCK_PATH}.stale.$$" 2>/dev/null; then
                echo "Removing stale Sigil lock (PID ${holder_pid} no longer running)" >&2
                rm -rf "${SIGIL_LOCK_PATH}.stale.$$"
            fi
            continue
        fi

        if (( elapsed >= timeout )); then
            echo "ERROR: could not acquire Sigil lock at ${SIGIL_LOCK_PATH} after ${timeout}s (held by PID ${holder_pid:-unknown})" >&2
            return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# Release the lock IF we hold it. Won't yank a lock held by another process.
sigil_release_lock() {
    if [[ ! -d "${SIGIL_LOCK_PATH}" ]]; then
        return 0
    fi
    local holder_pid
    holder_pid="$(cat "${SIGIL_LOCK_PATH}/pid" 2>/dev/null || true)"
    if [[ "${holder_pid}" == "$$" ]]; then
        rm -rf "${SIGIL_LOCK_PATH}"
    fi
}

# Run a command under the lock and release on completion. Returns the
# command's exit code (or 1 if the lock could not be acquired).
#
# Does NOT install a signal trap — that would clobber callers' traps.
# If the process is killed mid-command, the lock will appear stale to the
# next acquire (PID gone) and be reclaimed automatically. Callers running
# long-lived operations may install their own EXIT trap calling
# sigil_release_lock to release immediately on shell exit.
sigil_with_lock() {
    if (($# == 0)); then
        echo "ERROR: sigil_with_lock requires at least one argument" >&2
        return 2
    fi

    sigil_acquire_lock || return 1

    local rc=0
    "$@" || rc=$?

    sigil_release_lock
    return "${rc}"
}
