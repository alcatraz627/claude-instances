#!/bin/bash
# Scheduled jobs plugin — unified cron + launchd view.
# launchd lives at ~/Library/LaunchAgents/*.plist (user agents).
# cron lives in `crontab -l`.

set -euo pipefail
source_id="${1:-summary}"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"

# Print zero or more JSON items (one per line) for launchd plists.
launchd_items() {
    [[ -d "${LAUNCH_AGENTS}" ]] || return 0
    for plist in "${LAUNCH_AGENTS}"/*.plist; do
        [[ -f "${plist}" ]] || continue
        local name; name=$(basename "${plist}" .plist)
        local label; label=$(plutil -extract Label raw -o - "${plist}" 2>/dev/null || echo "${name}")
        # Build the command from ProgramArguments (or Program if simpler).
        local cmd
        if cmd=$(plutil -extract ProgramArguments json -o - "${plist}" 2>/dev/null); then
            cmd=$(echo "${cmd}" | jq -r 'join(" ")' 2>/dev/null || echo "(unparseable)")
        else
            cmd=$(plutil -extract Program raw -o - "${plist}" 2>/dev/null || echo "(no program)")
        fi
        # Schedule description: pick a few common keys.
        local when="(on demand)"
        if plutil -extract StartCalendarInterval json -o - "${plist}" > /dev/null 2>&1; then
            when="calendar interval"
        elif plutil -extract StartInterval raw -o - "${plist}" > /dev/null 2>&1; then
            local secs; secs=$(plutil -extract StartInterval raw -o - "${plist}")
            when="every ${secs}s"
        elif plutil -extract RunAtLoad raw -o - "${plist}" > /dev/null 2>&1; then
            when="at launchd load"
        fi
        # Enabled = currently loaded?
        local enabled="true"
        if ! launchctl list 2>/dev/null | grep -q "${label}$"; then
            enabled="false"
        fi
        jq -nc \
            --arg id "${label}" --arg src "launchd" \
            --arg when "${when}" --arg cmd "${cmd}" \
            --argjson enabled "${enabled}" \
            '{id: $id, source: $src, when: $when, command: $cmd, enabled: $enabled}'
    done
}

# Print zero or more JSON items for cron lines.
cron_items() {
    local lines
    lines=$(crontab -l 2>/dev/null || true)
    [[ -z "${lines}" ]] && return 0
    local idx=0
    while IFS= read -r line; do
        # Skip blanks and comments
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        # Take first 5 fields = schedule; rest = command
        local sched cmd
        sched=$(echo "${line}" | awk '{ print $1 " " $2 " " $3 " " $4 " " $5 }')
        cmd=$(echo "${line}" | awk '{ for (i=6; i<=NF; i++) printf "%s ", $i; print "" }')
        idx=$((idx + 1))
        jq -nc \
            --arg id "cron-${idx}" --arg src "cron" \
            --arg when "${sched}" --arg cmd "${cmd}" \
            '{id: $id, source: $src, when: $when, command: $cmd, enabled: true}'
    done <<<"${lines}"
}

case "${source_id}" in

  summary)
    launchd_total=0
    launchd_loaded=0
    cron_total=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        launchd_total=$((launchd_total + 1))
        if echo "${line}" | jq -e '.enabled' > /dev/null 2>&1; then
            launchd_loaded=$((launchd_loaded + 1))
        fi
    done < <(launchd_items)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        cron_total=$((cron_total + 1))
    done < <(cron_items)

    jq -n \
        --arg lt "${launchd_total}" \
        --arg ll "${launchd_loaded}" \
        --arg ct "${cron_total}" \
        '{
          kind: "summary",
          tiles: [
            { label: "launchd agents", value: $lt },
            { label: "launchd loaded", value: $ll, tone: "ok" },
            { label: "cron entries",   value: $ct }
          ]
        }'
    ;;

  schedule)
    items="[]"
    {
        launchd_items
        cron_items
    } > /tmp/scheduled-items.jsonl 2>/dev/null
    items=$(jq -s '.' /tmp/scheduled-items.jsonl 2>/dev/null || echo "[]")
    rm -f /tmp/scheduled-items.jsonl
    jq -n --argjson items "${items}" '{
      kind: "schedule",
      items: $items
    }'
    ;;

  *)
    jq -n --arg s "${source_id}" '{
      kind: "summary",
      tiles: [{ label: "Error", value: ("unknown source: " + $s), tone: "error" }]
    }'
    ;;
esac
