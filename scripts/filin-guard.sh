#!/usr/bin/env bash
# ExecStartPre guard for airbridge-awdl.service.
# Refuses to start when any filin is already running (e.g. a manual `sudo filin ...`),
# which would otherwise fight over the awdl0 TAP (Io(16)/EBUSY) and port 9930.
# Runs before the service's own filin exists, so any match is foreign.
PIDS=$(pgrep -x filin)
if [ -n "$PIDS" ]; then
  echo "filin-guard: another filin is already running; refusing to start a second one:" >&2
  for p in $PIDS; do ps -o pid=,args= -p "$p" >&2; done
  echo "filin-guard: stop it (Ctrl+C in its terminal) and the service will start on the next retry." >&2
  exit 1
fi
exit 0
