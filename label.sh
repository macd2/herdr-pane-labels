#!/usr/bin/env bash
# Set every pane's border label: "• <agent session title> · <cwd>" locally, "⇄ <remote title>" inside ssh.
# Herdr prints labels as plain text (colour codes are stripped), so local vs ssh is told apart by shape.
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"

panes=$("$herdr" pane list | jq -c '.result.panes')
agents=$("$herdr" agent list | jq -c '.result.agents')

# Foreground process per pane: {"w1:p1": {"name": "ssh", "argv": [...]}}.
fg=$(jq -r '.[].pane_id' <<<"$panes" | while read -r id; do
  "$herdr" pane process-info --pane "$id" \
    | jq -c --arg id "$id" '{($id): (.result.process_info.foreground_processes[0] // {})}'
done | jq -s 'add // {}')

# A shell title like "user@host: dir" is not an agent session title. While ssh is still
# connecting the pane keeps the local shell's title, so that one falls back to "ssh <host>".
jq -r --argjson agents "$agents" --argjson fg "$fg" --arg home "$HOME" --arg localhost "${USER:-}@$(hostname -s):" '
  .[] | .pane_id as $id
  | ($fg[$id].name // "" | IN("ssh", "mosh-client", "autossh")) as $remote
  | ([$agents[] | select(.pane_id == $id)] | first) as $a
  | (.foreground_cwd // .cwd // "" | sub("^" + $home; "~")) as $cwd
  | (if $a then ($a.terminal_title_stripped // "" | if . == "" or test("^[^ @]+@[^ :]+:") then $a.agent else . end) else "" end) as $s
  | (if $remote then "⇄ " + (.terminal_title_stripped // "" | if . == "" or startswith($localhost) then "ssh " + ($fg[$id].argv[-1] // "") else . end)
     elif $s != "" then "• \($s) · \($cwd)" else "• \($cwd)" end) as $want
  | select($want != "" and $want != (.label // ""))
  | [$id, $want] | @tsv
' <<<"$panes" | while IFS=$'\t' read -r pane label; do
  "$herdr" pane rename "$pane" "$label" >/dev/null
done
