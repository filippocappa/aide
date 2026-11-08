#!/bin/sh
# Aide's memory budget follows what else runs on cappa: 10 GB while it's free, aide.slice's own 8 GB while an Android
# emulator, Expo, Metro or Gradle runs, or anything else uses more than 4 GB. It grows back only after 2 min of that
# gone (Expo restarts often). Checked every 15 s; a change is logged. --dry: say what it would do, once, and change
# nothing. Install: README.md, "Running as a service".
BIG=${AIDE_BUDGET_BIG:-'qemu-system|Android/Sdk/emulator|expo start|metro|GradleDaemon|KotlinCompileDaemon'}
OTHER_MAX_MB=4096
QUIET_S=120
uid=$(id -u)
slice=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/aide.slice
current=""
last_big=0

while true; do
  now=$(date +%s)
  why=$(pgrep -fa -- "$BIG" | grep -v -e aide-budget -e earlyoom | head -1 | cut -d' ' -f2- | cut -c1-70)
  used_kb=$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {print t-a}' /proc/meminfo)
  aide_kb=$(awk '$1 == "anon" {print int($2/1024)}' "$slice/memory.stat" 2>/dev/null || echo 0)
  other_mb=$(( (used_kb - ${aide_kb:-0}) / 1024 ))
  [ -z "$why" ] && [ "$other_mb" -gt "$OTHER_MAX_MB" ] && why="${other_mb} MB used outside Aide"
  [ -n "$why" ] && last_big=$now
  if [ $(( now - last_big )) -ge $QUIET_S ]; then
    want=10G high=9G why="nothing big running"
  else
    want=8G high=7G why=${why:-"waiting $(( QUIET_S - (now - last_big) )) s for it to stay quiet"}
  fi
  if [ "$1" = "--dry" ]; then
    echo "would be $want: $why"
    exit 0
  fi
  if [ "$want" != "$current" ]; then
    if systemctl --user set-property --runtime aide.slice MemoryHigh=$high MemoryMax=$want; then
      echo "Aide's memory budget: $want ($why)"
      current=$want
    fi
  fi
  sleep 15
done
