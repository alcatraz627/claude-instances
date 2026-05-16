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
    rows=$(jq -rs '
      sort_by(.ts) | reverse | .[0:20]
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

  *)
    jq -n --arg s "${source_id}" '{
      kind: "summary",
      tiles: [{ label: "Error", value: ("unknown source: " + $s), tone: "error" }]
    }'
    ;;
esac
