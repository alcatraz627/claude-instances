#!/bin/bash
# Atone plugin — fetch script.
#
# First argv token is the source identifier (matches the manifest's
# panes[].source after the "fetch:" prefix). Prints JSON to stdout that
# the host validates against the relevant pane schema.
#
# Dependencies: jq.

set -euo pipefail

ATONE_DIR="${HOME}/.claude/atone"
EVENTS="${ATONE_DIR}/events.jsonl"
META="${ATONE_DIR}/derived/_meta.json"

source_id="${1:-summary}"

# Per-plugin settings: the host passes a JSON object in
# CLAUDE_PLUGIN_SETTINGS. Keys match settings.schema.json properties.
# Fall back to schema defaults if user hasn't set anything yet.
# (Note: avoid `${VAR:-{}}` default — bash's brace handling is finicky
#  inside default values; an explicit if-block is safer.)
SETTINGS_JSON='{}'
if [[ -n "${CLAUDE_PLUGIN_SETTINGS:-}" ]]; then
    SETTINGS_JSON="${CLAUDE_PLUGIN_SETTINGS}"
fi
max_events=$(echo "${SETTINGS_JSON}" | jq -r '.max_events // 20' 2>/dev/null)
[[ -z "${max_events}" ]] && max_events=20
show_s3_only=$(echo "${SETTINGS_JSON}" | jq -r '.show_s3_only // false' 2>/dev/null)
[[ -z "${show_s3_only}" ]] && show_s3_only=false

case "${source_id}" in

  summary)
    total=0
    s3=0
    s2=0
    s1=0
    top_slug="(none)"
    top_count=0
    if [[ -f "${EVENTS}" ]]; then
      total=$(grep -c '^' "${EVENTS}" || echo 0)
      s3=$(jq -rs 'map(select(.severity == "S3")) | length' "${EVENTS}" 2>/dev/null || echo 0)
      s2=$(jq -rs 'map(select(.severity == "S2")) | length' "${EVENTS}" 2>/dev/null || echo 0)
      s1=$(jq -rs 'map(select(.severity == "S1")) | length' "${EVENTS}" 2>/dev/null || echo 0)
      # Most-common slug
      if [[ "${total}" -gt 0 ]]; then
        top_line=$(jq -r '.slug' "${EVENTS}" 2>/dev/null | sort | uniq -c | sort -rn | head -1 || true)
        top_count=$(awk '{print $1}' <<<"${top_line}")
        top_slug=$(awk '{$1=""; print $0}' <<<"${top_line}" | sed 's/^ //')
        [[ -z "${top_slug}" ]] && top_slug="(none)"
      fi
    fi

    last_consolidate="(never)"
    slug_count=0
    if [[ -f "${META}" ]]; then
      last_consolidate=$(jq -r '.generated_at // "(never)"' "${META}" 2>/dev/null || echo "(error)")
      slug_count=$(jq -r '.slug_count // 0' "${META}" 2>/dev/null || echo 0)
    fi

    jq -n \
      --arg total "${total}" \
      --arg s3 "${s3}" --arg s2 "${s2}" --arg s1 "${s1}" \
      --arg top "${top_slug}" --arg top_n "${top_count}" \
      --arg slugs "${slug_count}" \
      --arg last "${last_consolidate}" \
      '{
        kind: "summary",
        tiles: [
          { label: "Total events", value: $total },
          { label: "Distinct patterns", value: $slugs, tone: "dim" },
          { label: "S3 events", value: $s3, tone: "error" },
          { label: "S2 events", value: $s2, tone: "warn" },
          { label: "S1 events", value: $s1 },
          { label: "Top pattern", value: $top, trend: ("x" + $top_n + " occurrences") },
          { label: "Last consolidate", value: $last, tone: "ok" }
        ]
      }'
    ;;

  events)
    if [[ ! -f "${EVENTS}" ]]; then
      echo '{"kind":"table","columns":[],"rows":[],"empty":"No events.jsonl yet."}'
      exit 0
    fi
    # Honor user settings: max_events caps row count; show_s3_only filters
    # to severity S3 if true.
    rows=$(jq -rs \
      --argjson max "${max_events}" \
      --argjson s3only "${show_s3_only}" \
      '
      sort_by(.ts) | reverse
      | (if $s3only then map(select(.severity == "S3")) else . end)
      | .[0:$max]
      | map({
          ts:   (.ts | sub("T"; " ") | sub("Z"; "")),
          slug: (.slug // "(no slug)"),
          sev:  (.severity // "—")
        })' "${EVENTS}")
    jq -n --argjson rows "${rows}" '{
      kind: "table",
      columns: [
        { id: "ts",   label: "When",    width: 160 },
        { id: "slug", label: "Pattern", width: "flex" },
        { id: "sev",  label: "Sev",     width: 50, align: "trailing" }
      ],
      rows: $rows,
      empty: "No events."
    }'
    ;;

  badge)
    s3=0
    if [[ -f "${EVENTS}" ]]; then
      s3=$(jq -rs 'map(select(.severity == "S3")) | length' "${EVENTS}" 2>/dev/null || echo 0)
    fi
    tone="dim"
    [[ "${s3}" -gt 0 ]] && tone="warn"
    [[ "${s3}" -gt 5 ]] && tone="error"
    jq -n --arg text "S3:${s3}" --arg tone "${tone}" '{text: $text, tone: $tone}'
    ;;

  menubar)
    if [[ ! -f "${EVENTS}" ]]; then
      jq -n '{rows:[{label:"No events recorded", tone:"dim"}]}'
      exit 0
    fi
    rows=$(jq -rs '
      sort_by(.ts) | reverse | .[0:5]
      | map({
          label:    (.slug // "(no slug)"),
          subtitle: ((.ts // "" | sub("T"; " ") | sub("Z"; "")) + " · " + (.severity // "?")),
          icon:     "exclamationmark.bubble",
          tone:     (if .severity == "S3" then "error"
                     elif .severity == "S2" then "warn"
                     else "dim" end)
        })' "${EVENTS}")
    jq -n --argjson rows "${rows}" '{rows: $rows}'
    ;;

  *)
    jq -n --arg s "${source_id}" '{
      kind: "summary",
      tiles: [{ label: "Error", value: ("unknown source: " + $s), tone: "error" }]
    }'
    ;;
esac
