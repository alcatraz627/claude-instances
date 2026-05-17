#!/bin/bash
# Sessions plugin — reads ~/.claude/projects/ for transcripts.
# Each session is one .jsonl file; the parent directory encodes the project path.

set -euo pipefail
PROJECTS="${HOME}/.claude/projects"
source_id="${1:-summary}"

# Helper: list session files, newest first. Each line: "<mtime_unix>\t<size>\t<path>".
list_sessions() {
    [[ -d "${PROJECTS}" ]] || return 0
    find "${PROJECTS}" -name "*.jsonl" -type f 2>/dev/null |
        while read -r p; do
            stat -f '%m	%z	%N' "${p}" 2>/dev/null || true
        done | sort -rn | head -100
}

# Decode "-Users-alcatraz627--claude-widgets-claude-instances" -> readable
decode_project() {
    local raw="${1}"
    # Slashes were doubled to "--"; restore. Convention from Claude Code's storage.
    echo "${raw}" | sed 's|--|/|g' | sed 's|^-|/|'
}

case "${source_id}" in

  summary)
    total=0
    today=0
    week=0
    largest=0
    largest_path=""
    if [[ -d "${PROJECTS}" ]]; then
        total=$(find "${PROJECTS}" -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
        now=$(date +%s)
        cutoff_today=$((now - 86400))
        cutoff_week=$((now - 86400 * 7))
        while IFS=$'\t' read -r mtime size path; do
            [[ -z "${mtime}" ]] && continue
            (( mtime >= cutoff_today )) && today=$((today + 1)) || true
            (( mtime >= cutoff_week ))  && week=$((week + 1)) || true
            if (( size > largest )); then
                largest=${size}
                largest_path="${path}"
            fi
        done < <(list_sessions)
    fi
    largest_mb=$(awk "BEGIN { printf \"%.1f\", ${largest}/1024/1024 }")
    largest_name=$(basename "${largest_path}" .jsonl 2>/dev/null || echo "(none)")
    jq -n \
      --arg total "${total}" \
      --arg today "${today}" \
      --arg week "${week}" \
      --arg lmb "${largest_mb}" \
      --arg lname "${largest_name}" \
      '{
        kind: "summary",
        tiles: [
          { label: "Total transcripts", value: $total },
          { label: "Active today",      value: $today, tone: "ok"  },
          { label: "Active this week",  value: $week,  tone: "dim" },
          { label: "Largest transcript", value: ($lmb + " MB"), trend: $lname }
        ]
      }'
    ;;

  recent)
    # Build the rows safely with jq so quoting can't corrupt the JSON.
    tmpf=$(mktemp)
    trap "rm -f ${tmpf}" EXIT
    if [[ -d "${PROJECTS}" ]]; then
        # `head` closes the pipe early -> SIGPIPE upstream -> pipefail
        # would otherwise abort the script. Tolerate it.
        list_sessions 2>/dev/null | head -25 > "${tmpf}" || true
    fi
    rows="[]"
    if [[ -s "${tmpf}" ]]; then
        rows=$(while IFS=$'\t' read -r mtime size path; do
            [[ -z "${mtime}" ]] && continue
            session=$(basename "${path}" .jsonl)
            project_raw=$(basename "$(dirname "${path}")")
            when=$(date -r "${mtime}" "+%Y-%m-%d %H:%M")
            size_kb=$((size / 1024))
            project=$(echo "${project_raw}" | sed 's|--|/|g' | sed 's|^-|/|')
            jq -nc \
                --arg when "${when}" \
                --arg session "${session:0:8}" \
                --arg project "${project}" \
                --arg kb "${size_kb}" \
                '{when: $when, session: $session, project: $project, kb: $kb}'
        done < "${tmpf}" | jq -s '.')
    fi
    jq -n --argjson rows "${rows}" '{
      kind: "table",
      columns: [
        { id: "when",    label: "When",    width: 130 },
        { id: "session", label: "Session", width: 80 },
        { id: "project", label: "Project", width: "flex" },
        { id: "kb",      label: "KB",      width: 70, align: "trailing" }
      ],
      rows: $rows,
      empty: "No transcripts under ~/.claude/projects yet."
    }'
    ;;

  menubar)
    tmpf=$(mktemp); trap "rm -f ${tmpf}" EXIT
    if [[ -d "${PROJECTS}" ]]; then
        list_sessions 2>/dev/null | head -5 > "${tmpf}" || true
    fi
    rows="[]"
    if [[ -s "${tmpf}" ]]; then
        i=1
        rows=$(while IFS=$'\t' read -r mtime size path; do
            [[ -z "${mtime}" ]] && continue
            session=$(basename "${path}" .jsonl)
            project_raw=$(basename "$(dirname "${path}")")
            project=$(echo "${project_raw}" | sed 's|--|/|g' | sed 's|^-|/|')
            when=$(date -r "${mtime}" "+%H:%M")
            size_kb=$((size / 1024))
            jq -nc \
                --arg label "${project##*/}" \
                --arg sub "${session:0:8} · ${when} · ${size_kb} KB" \
                --arg key "${i}" \
                '{label: $label, subtitle: $sub, icon: "doc.text",
                  tone: "dim", key_equivalent: $key}'
            i=$((i + 1))
        done < "${tmpf}" | jq -s '.')
    fi
    jq -n --argjson rows "${rows}" '{rows: $rows}'
    ;;

  *)
    jq -n --arg s "${source_id}" '{
      kind: "summary",
      tiles: [{ label: "Error", value: ("unknown source: " + $s), tone: "error" }]
    }'
    ;;
esac
