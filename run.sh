#!/bin/sh
# Apply before Go package initialization, preserving unrelated runtime settings.
export GODEBUG="${GODEBUG:+${GODEBUG},}multipathtcp=0"
exec "$(dirname "$0")/N2X" "$@"
