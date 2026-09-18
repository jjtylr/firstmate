#!/bin/bash
set -eu

if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Options: --tui-mode <mode>'
  exit 0
fi

approved=0
extension=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --approve) approved=1 ;;
    -e) shift; extension=$1 ;;
  esac
  shift
done

printf '%s\n' verified-pi-worker
if [ "$approved" -eq 1 ]; then
  [ -n "$extension" ]
  EXT_PATH="$extension" node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const handlers = {};
const extension = await import(pathToFileURL(process.env.EXT_PATH).href);
extension.default({ on: (name, fn) => { handlers[name] = fn; } });
await handlers.agent_start({}, {});
JS
fi

while :; do
  /bin/sleep 60
done
