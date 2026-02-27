#!/bin/bash
# Generic retry helper — polls a command until it succeeds or times out.
#
# Usage:
#   retry <max_seconds> <interval> <command...>
#
# The command is evaluated via "$@" and must exit 0 to indicate success.
# Returns 1 if the timeout is reached without success.
#
# Example:
#   retry 180 5 check_droplet_active "$DROPLET_ID"

retry() {
    local max_wait=$1; shift
    local interval=$1; shift
    local elapsed=0

    while [ $elapsed -lt "$max_wait" ]; do
        if "$@"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}
