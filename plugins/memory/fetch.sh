#!/bin/bash
# Memory plugin — walks ~/.claude/memory/ for markdown files with
# frontmatter (name / description / type). Type is one of:
# user, feedback, project, reference.

set -euo pipefail

MEMORY_DIR="${HOME}/.claude/memory"
source_id="${1:-summary}"

# Helper: print "type\tname\tdescription\tpath" for each memory file
list_memories() {
    [[ -d "${MEMORY_DIR}" ]] || return 0
    find "${MEMORY_DIR}" -name "*.md" -not -name "MEMORY.md" -not -name "README.md" 2>/dev/null | while read -r f; do
        # Parse YAML frontmatter via awk: lines between first two --- markers
        type=$(awk '/^---/{n++; next} n==1 && /^type:/{sub(/^type:[ \t]*/,""); print; exit}' "${f}")
        name=$(awk '/^---/{n++; next} n==1 && /^name:/{sub(/^name:[ \t]*/,""); print; exit}' "${f}")
        desc=$(awk '/^---/{n++; next} n==1 && /^description:/{sub(/^description:[ \t]*/,""); print; exit}' "${f}")
        # Defaults from filename when frontmatter is missing
        [[ -z "${name}" ]] && name=$(basename "${f}" .md)
        [[ -z "${type}" ]] && type="(no-type)"
        [[ -z "${desc}" ]] && desc="(no description)"
        # Trim quotes
        type=$(echo "${type}" | sed 's/^["'"'"']//; s/["'"'"']$//')
        printf "%s\t%s\t%s\t%s\n" "${type}" "${name}" "${desc}" "${f}"
    done
}

case "${source_id}" in

  summary)
    if [[ ! -d "${MEMORY_DIR}" ]]; then
      jq -n '{kind:"summary", tiles:[
        {label:"No ~/.claude/memory/", value:"—", tone:"dim"}
      ]}'
      exit 0
    fi
    total=0
    user=0; feedback=0; project=0; reference=0; other=0
    tmpf=$(mktemp); trap "rm -f ${tmpf}" EXIT
    list_memories > "${tmpf}"
    while IFS=$'\t' read -r type name desc path; do
        [[ -z "${type}" ]] && continue
        total=$((total + 1))
        case "${type}" in
            user)      user=$((user + 1)) ;;
            feedback)  feedback=$((feedback + 1)) ;;
            project)   project=$((project + 1)) ;;
            reference) reference=$((reference + 1)) ;;
            *)         other=$((other + 1)) ;;
        esac
    done < "${tmpf}"
    jq -n \
      --arg total "${total}" \
      --arg user "${user}" --arg feedback "${feedback}" \
      --arg project "${project}" --arg reference "${reference}" \
      --arg other "${other}" \
      '{
        kind: "summary",
        tiles: [
          { label: "Total memories", value: $total },
          { label: "user",      value: $user },
          { label: "feedback",  value: $feedback,  tone: "warn" },
          { label: "project",   value: $project,   tone: "ok" },
          { label: "reference", value: $reference, tone: "dim" }
        ]
      }'
    ;;

  list)
    if [[ ! -d "${MEMORY_DIR}" ]]; then
      echo '{"kind":"table","columns":[],"rows":[],"empty":"No ~/.claude/memory/"}'
      exit 0
    fi
    tmpf=$(mktemp); trap "rm -f ${tmpf}" EXIT
    list_memories | sort > "${tmpf}"
    rows="[]"
    if [[ -s "${tmpf}" ]]; then
        rows=$(while IFS=$'\t' read -r type name desc path; do
            [[ -z "${name}" ]] && continue
            # Trim description to one-line preview
            desc_short=$(echo "${desc}" | head -c 100)
            jq -nc \
              --arg type "${type}" --arg name "${name}" \
              --arg desc "${desc_short}" \
              '{type: $type, name: $name, desc: $desc}'
        done < "${tmpf}" | jq -s '.')
    fi
    jq -n --argjson rows "${rows}" '{
      kind: "table",
      columns: [
        { id: "type", label: "Type", width: 90 },
        { id: "name", label: "Name", width: 220 },
        { id: "desc", label: "Description", width: "flex" }
      ],
      rows: $rows,
      empty: "No memory files."
    }'
    ;;

  *)
    jq -n --arg s "${source_id}" '{
      kind: "summary",
      tiles: [{ label: "Error", value: ("unknown source: " + $s), tone: "error" }]
    }'
    ;;
esac
