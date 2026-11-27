#!/bin/sh
# Apply before Go package initialization, preserving unrelated runtime settings.
export GODEBUG="${GODEBUG:+${GODEBUG},}multipathtcp=0"
if [ "${1:-}" = server ] && [ -f /run/n2x-upgrade/ready ]; then
    set -- "$@" --prepared-startup /run/n2x-upgrade/ready
fi
exec "$(dirname "$0")/N2X" "$@"
