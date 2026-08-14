#!/usr/bin/env bash
# Long-running footprint/stability soak for the iOS Packet Tunnel extension.
#
# Samples the App Group metrics snapshot the extension writes each second and
# records footprint, CPU, throughput and Go runtime memory over time. Answers
# two questions a short manual test cannot: does resident memory drift upward
# under sustained traffic, and does the session survive without the extension
# being jetsammed or restarted.
#
# A NEPacketTunnelProvider runs under a much tighter jetsam footprint cap than
# a normal app, so a slow leak shows up as a mid-session kill rather than a
# crash log. Sampling `packet_tunnel_started_at` catches exactly that: the
# value changes when the extension was restarted underneath the user.
#
# Usage:
#   scripts/ios_packet_tunnel_soak.sh [duration_minutes] [interval_seconds]
#   scripts/ios_packet_tunnel_soak.sh --report <csv>
#
# Env:
#   IOS_DEVICE   device UDID (default: first attached iOS device)
#   SOAK_OUT     output directory (default: build/soak)
#
# Generate real traffic on the device for the duration; an idle soak only
# measures the extension sitting still.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GROUP_ID="group.plus.svc.xconnect"
PLIST_PATH="Library/Preferences/${GROUP_ID}.plist"

CSV_COLUMNS="wall_clock,epoch,uptime_s,started_at,rss_bytes,cpu_percent,down_bps,up_bps,go_heap_inuse,go_heap_idle,go_heap_released,go_sys,go_num_gc,go_goroutines,last_error"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# Summarises a soak CSV. Split out so an interrupted run still produces a
# report, and so an earlier run's CSV can be re-summarised later.
report_csv() {
  local csv="$1"
  if [[ ! -f "$csv" ]]; then
    echo "No such CSV: $csv" >&2
    return 1
  fi

  awk -F, '
    function fmt_mb(bytes) { return sprintf("%.1f MB", bytes / 1048576) }
    function fmt_kbs(bps)  { return sprintf("%.1f KB/s", bps / 1024) }
    function stat_line(label, unit, min, max, sum, n) {
      if (n == 0) { printf "  %-22s no samples\n", label; return }
      if (unit == "mb")
        printf "  %-22s min %-12s avg %-12s peak %s\n", label,
               fmt_mb(min), fmt_mb(sum / n), fmt_mb(max)
      else if (unit == "kbs")
        printf "  %-22s min %-12s avg %-12s peak %s\n", label,
               fmt_kbs(min), fmt_kbs(sum / n), fmt_kbs(max)
      else
        printf "  %-22s min %-12.1f avg %-12.1f peak %.1f\n", label,
               min, sum / n, max
    }
    function track(value, idx) {
      if (value == "") return
      n[idx]++
      sum[idx] += value
      if (n[idx] == 1 || value < min[idx]) min[idx] = value
      if (n[idx] == 1 || value > max[idx]) max[idx] = value
    }

    NR == 1 { next }
    {
      samples++
      if ($4 != "") {
        if (first_session == "") first_session = $4
        if (prev_session != "" && $4 != prev_session) {
          restarts++
          restart_at[restarts] = $1 " (" prev_session " -> " $4 ")"
        }
        prev_session = $4
        last_uptime = $3
      }
      if ($15 != "") { error_samples++; if (first_error == "") first_error = $1 " " $15 }

      track($5, "rss"); track($6, "cpu")
      track($7, "down"); track($8, "up")
      track($9, "goheap"); track($12, "gosys")
      track($14, "goroutines")

      if ($5 != "") { if (rss_first == "") rss_first = $5; rss_last = $5 }
      if ($13 != "") { if (gc_first == "") gc_first = $13; gc_last = $13 }
      if ($2 != "")  { if (t_first == "") t_first = $2; t_last = $2 }
    }
    END {
      printf "samples=%d  span=%ds  final_uptime=%ss\n",
             samples, (t_last - t_first), last_uptime
      printf "restarts=%d  error_samples=%d\n", restarts + 0, error_samples + 0
      for (i = 1; i <= restarts; i++) printf "  RESTART %s\n", restart_at[i]
      if (first_error != "") printf "  FIRST ERROR %s\n", first_error
      print ""
      stat_line("process RSS", "mb", min["rss"], max["rss"], sum["rss"], n["rss"])
      stat_line("go runtime Sys", "mb", min["gosys"], max["gosys"], sum["gosys"], n["gosys"])
      stat_line("go heap in use", "mb", min["goheap"], max["goheap"], sum["goheap"], n["goheap"])
      stat_line("cpu percent", "num", min["cpu"], max["cpu"], sum["cpu"], n["cpu"])
      stat_line("download", "kbs", min["down"], max["down"], sum["down"], n["down"])
      stat_line("upload", "kbs", min["up"], max["up"], sum["up"], n["up"])
      stat_line("goroutines", "num", min["goroutines"], max["goroutines"], sum["goroutines"], n["goroutines"])
      print ""
      if (rss_first != "" && rss_last != "")
        printf "  RSS drift              %+.1f MB over the run (%.1f -> %.1f MB)\n",
               (rss_last - rss_first) / 1048576, rss_first / 1048576, rss_last / 1048576
      if (gc_first != "" && gc_last != "" && (t_last - t_first) > 0)
        printf "  GC cycles              %d total, %.1f/min\n",
               gc_last - gc_first, (gc_last - gc_first) * 60 / (t_last - t_first)
      print ""
      if (restarts + 0 == 0 && error_samples + 0 == 0)
        print "  VERDICT: no session restart and no reported error."
      else
        print "  VERDICT: session was not clean -- see restarts/errors above."
      print "  Upward RSS drift with flat throughput is the leak signature to watch."
    }
  ' "$csv"
}

if [[ "${1:-}" == "--report" ]]; then
  report_csv "${2:?--report needs a CSV path}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

DURATION_MIN="${1:-120}"
INTERVAL_SEC="${2:-30}"

DEVICE_ID="${IOS_DEVICE:-}"
if [[ -z "$DEVICE_ID" ]]; then
  # Identifier is the only UUID-shaped column; the State/Model columns each
  # contain spaces, so positional counting from the right is not reliable.
  DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone|iPad/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-/) { print $i; exit }
        }
      }')"
fi
if [[ -z "$DEVICE_ID" ]]; then
  echo "No iOS device found. Connect a device or set IOS_DEVICE=<udid>." >&2
  exit 1
fi

OUT_DIR="${SOAK_OUT:-$ROOT_DIR/build/soak}"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$OUT_DIR/soak-$STAMP.csv"
LOG="$OUT_DIR/soak-$STAMP.log"
WORK="$(mktemp -d)"

# An interrupted soak is still evidence, so always leave a report behind.
finish() {
  rm -rf "$WORK"
  echo "" | tee -a "$LOG"
  echo "--- soak summary ---" | tee -a "$LOG"
  report_csv "$CSV" | tee -a "$LOG"
}
trap finish EXIT

{
  echo "device=$DEVICE_ID duration=${DURATION_MIN}m interval=${INTERVAL_SEC}s"
  echo "csv=$CSV"
} | tee "$LOG"

echo "$CSV_COLUMNS" > "$CSV"

# Reads one key path out of the snapshot, printing nothing when it is absent.
# plutil reports a missing key on stdout and exits non-zero, so the value is
# only usable when the call actually succeeded -- otherwise the diagnostic text
# lands in the CSV and every sample looks like a tunnel error.
plist_value() {
  local keypath="$1"
  local out
  if out="$(plutil -extract "$keypath" raw -o - "$WORK/snapshot.plist" 2>/dev/null)"; then
    printf '%s' "$out"
  fi
}

read_metric() {
  plist_value "packet_tunnel_metrics_snapshot.$1"
}

deadline=$(( $(date +%s) + DURATION_MIN * 60 ))
prev_started_at=""

while [[ $(date +%s) -lt $deadline ]]; do
  if ! xcrun devicectl device copy from \
      --device "$DEVICE_ID" \
      --domain-type appGroupDataContainer \
      --domain-identifier "$GROUP_ID" \
      --source "$PLIST_PATH" \
      --destination "$WORK/snapshot.plist" >/dev/null 2>&1; then
    echo "$(date +%H:%M:%S) WARN snapshot pull failed" | tee -a "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  now_epoch=$(date +%s)
  started_at="$(plist_value packet_tunnel_started_at)"
  last_error="$(plist_value packet_tunnel_last_error)"
  rss="$(read_metric memoryBytes)"
  cpu="$(read_metric cpuPercent)"
  down="$(read_metric downloadBytesPerSecond)"
  up="$(read_metric uploadBytesPerSecond)"
  go_heap="$(read_metric goHeapInUseBytes)"
  go_idle="$(read_metric goHeapIdleBytes)"
  go_released="$(read_metric goHeapReleasedBytes)"
  go_sys="$(read_metric goSysBytes)"
  go_gc="$(read_metric goNumGC)"
  go_routines="$(read_metric goGoroutines)"

  uptime=""
  if [[ -n "$started_at" ]]; then
    uptime=$(( now_epoch - started_at ))
    if [[ -n "$prev_started_at" && "$started_at" != "$prev_started_at" ]]; then
      echo "$(date +%H:%M:%S) RESTART session $prev_started_at -> $started_at" | tee -a "$LOG"
    fi
    prev_started_at="$started_at"
  fi

  if [[ -n "$last_error" ]]; then
    echo "$(date +%H:%M:%S) ERROR $last_error" | tee -a "$LOG"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date +%H:%M:%S)" "$now_epoch" "$uptime" "$started_at" \
    "$rss" "$cpu" "$down" "$up" \
    "$go_heap" "$go_idle" "$go_released" "$go_sys" "$go_gc" "$go_routines" \
    "${last_error//,/;}" >> "$CSV"

  printf '%s rss=%sMB cpu=%s%% down=%sB/s up=%sB/s go_sys=%sMB gc=%s\n' \
    "$(date +%H:%M:%S)" \
    "$(( ${rss:-0} / 1048576 ))" "${cpu:-?}" "${down:-?}" "${up:-?}" \
    "$(( ${go_sys:-0} / 1048576 ))" "${go_gc:-?}"

  sleep "$INTERVAL_SEC"
done
