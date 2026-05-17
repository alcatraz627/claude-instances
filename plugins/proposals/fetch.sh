#!/bin/bash
# Proposals plugin — reads ~/.claude/proposals.jsonl.
# Each line is a JSON object with id/ts/title/category/effort/status/tags.

set -euo pipefail

PROPOSALS="${HOME}/.claude/proposals.jsonl"
source_id="${1:-summary}"

case "${source_id}" in

  summary)
    if [[ ! -f "${PROPOSALS}" ]]; then
      jq -n '{kind:"summary", tiles:[
        {label:"No proposals.jsonl yet", value:"—", tone:"dim"}
      ]}'
      exit 0
    fi
    total=$(grep -c '^' "${PROPOSALS}" || echo 0)
    open=$(jq -rs 'map(select(.status == "open" or (.status == null))) | length' "${PROPOSALS}" 2>/dev/null || echo 0)
    done_n=$(jq -rs 'map(select(.status == "done")) | length' "${PROPOSALS}" 2>/dev/null || echo 0)
    top_cat=$(jq -r '.category // "uncategorized"' "${PROPOSALS}" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{$1=""; print $0}' | sed 's/^ //')
    [[ -z "${top_cat}" ]] && top_cat="(none)"
    latest=$(jq -rs 'sort_by(.ts) | reverse | .[0].title // "(none)"' "${PROPOSALS}" 2>/dev/null)
    jq -n \
      --arg total "${total}" --arg open "${open}" \
      --arg done_n "${done_n}" --arg cat "${top_cat}" \
      --arg latest "${latest}" \
      '{
        kind: "summary",
        tiles: [
          { label: "Total proposals", value: $total },
          { label: "Open",   value: $open,   tone: "warn" },
          { label: "Done",   value: $done_n, tone: "ok" },
          { label: "Top category", value: $cat, tone: "dim" },
          { label: "Latest", value: $latest, trend: " " }
        ]
      }'
    ;;

  open)
    if [[ ! -f "${PROPOSALS}" ]]; then
      echo '{"kind":"table","columns":[],"rows":[],"empty":"No proposals.jsonl yet."}'
      exit 0
    fi
    rows=$(jq -rs '
      map(select(.status == "open" or (.status == null)))
      | sort_by(.ts) | reverse | .[0:25]
      | map({
          ts:       (.ts // "" | sub("T.*"; "")),
          title:    (.title // "(untitled)"),
          category: (.category // "—"),
          effort:   (.effort // "—")
        })' "${PROPOSALS}")
    jq -n --argjson rows "${rows}" '{
      kind: "table",
      columns: [
        { id: "ts",       label: "Filed",    width: 110 },
        { id: "title",    label: "Title",    width: "flex" },
        { id: "category", label: "Category", width: 100 },
        { id: "effort",   label: "Effort",   width: 80, align: "trailing" }
      ],
      rows: $rows,
      empty: "No open proposals."
    }'
    ;;

  *)
    jq -n --arg s "${source_id}" '{
      kind: "summary",
      tiles: [{ label: "Error", value: ("unknown source: " + $s), tone: "error" }]
    }'
    ;;
esac
