#!/usr/bin/env bash
# Wait until every started service is healthy (or, for one-shot services,
# exited with code 0). Usage: scripts/wait-healthy.sh [timeout-seconds]
set -euo pipefail
cd "$(dirname "$0")/.."

timeout=${1:-300}
deadline=$(( $(date +%s) + timeout ))

while :; do
  pending=""
  broken=""
  while read -r svc state health exitcode; do
    [ -n "$svc" ] || continue
    case "$state" in
      exited)
        [ "$exitcode" = 0 ] || broken="$broken $svc(exit $exitcode)" ;;
      running)
        case "$health" in
          healthy|"-") ;;
          *) pending="$pending $svc($health)" ;;
        esac ;;
      restarting|dead) broken="$broken $svc($state)" ;;
      *) pending="$pending $svc($state)" ;;
    esac
  done < <(docker compose ps -a --format '{{.Service}} {{.State}} {{if .Health}}{{.Health}}{{else}}-{{end}} {{.ExitCode}}')

  if [ -n "$broken" ]; then
    echo "wait: failed services:$broken" >&2
    exit 1
  fi
  if [ -z "$pending" ]; then
    echo "wait: all services healthy"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "wait: timed out after ${timeout}s, still waiting for:$pending" >&2
    docker compose ps -a >&2
    exit 1
  fi
  sleep 5
done
