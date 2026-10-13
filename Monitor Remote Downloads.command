#!/bin/zsh
set -e
TASK_DIRECTORY="${0:A:h}"
exec /usr/bin/env python3 "${TASK_DIRECTORY}/scripts/remote-download-monitor.py" "$@"
