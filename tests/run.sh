#!/usr/bin/env bash
# Run label.sh against recorded herdr output (a shell pane, a Claude pane, a pane inside ssh)
# through a fake herdr binary, and check the labels it sets.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

cat > "$work/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane list")         cat "\${PANE_LIST:-$here/fixtures/pane-list.json}" ;;
  "agent list")        cat "$here/fixtures/agent-list.json" ;;
  "pane process-info") cat "$here/fixtures/process-info-\${4//:/_}.json" ;;
  "pane rename")       printf '%s\t%s\n' "\$3" "\$4" >> "$work/renames" ;;
esac
STUB
printf '#!/bin/sh\necho laptop\n' > "$work/hostname"
chmod +x "$work/herdr" "$work/hostname"

run() { : > "$work/renames"; PATH="$work:$PATH" HERDR_BIN_PATH="$work/herdr" HOME=/home/alice USER=alice bash "$here/../label.sh"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; fail=1; fi; }

run
check "shell pane shows cwd"            "• ~"                             "$(awk -F'\t' '$1=="w7:p1"{print $2}' "$work/renames")"
check "agent pane shows title and cwd"  "• Claude Code · ~/projects/src/webapp" "$(awk -F'\t' '$1=="w7:pA"{print $2}' "$work/renames")"
check "ssh pane shows host while connecting" "⇄ ssh mono"                 "$(awk -F'\t' '$1=="w7:pB"{print $2}' "$work/renames")"

# Labels already correct: nothing is renamed.
jq --rawfile r "$work/renames" '
  ($r | split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add) as $m
  | .result.panes |= map(.label = $m[.pane_id])' "$here/fixtures/pane-list.json" > "$work/labelled.json"
PANE_LIST="$work/labelled.json" run
check "second run renames nothing" "0" "$(wc -l < "$work/renames" | tr -d ' ')"

# Remote shell has set its own title: show it instead of the ssh target.
jq '.result.panes |= map(if .pane_id == "w7:pB" then .terminal_title_stripped = "bob@server: /srv/app" else . end)' \
  "$here/fixtures/pane-list.json" > "$work/remote.json"
PANE_LIST="$work/remote.json" run
check "ssh pane shows remote title" "⇄ bob@server: /srv/app" "$(awk -F'\t' '$1=="w7:pB"{print $2}' "$work/renames")"

exit $fail
