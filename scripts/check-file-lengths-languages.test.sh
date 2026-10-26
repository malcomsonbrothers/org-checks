#!/usr/bin/env bash
# Tests that a file in a covered language cannot leave the file length check by its name or its
# line endings: shebang interpreters, upper-case and dot-file extensions, uncovered extensions,
# extension variants and lone carriage returns. Usage: scripts/check-file-lengths-languages.test.sh
set -euo pipefail
. "$(dirname "$0")/file-lengths-test-helpers.sh"
script() { mkdir -p "$(dirname "$3")"; { echo "#!$1"; body "$(($2 - 1))"; } > "$3"; } # script SHEBANG LINES PATH

# Extension-less files take the limit of whatever covered language their shebang runs.
repo interpreters
while IFS='|' read -r shebang max; do
  rm -f tool; script "$shebang" "$((max + 1))" tool
  check; expect "shebang $shebang" 1 "tool: $((max + 1)) lines, limit $max"
  script "$shebang" "$max" tool; check; expect "shebang $shebang at its limit" 0
done <<'CASES'
/usr/bin/python3 -I|600
/usr/bin/env python3.12|600
/usr/bin/env -S python3 -I -B|600
/usr/bin/env -S uv run --script|600
/usr/local/bin/pypy3|600
/usr/bin/env node|600
/usr/bin/env -S bun run|600
/usr/bin/env -S deno run --allow-all|600
/usr/bin/env -S npx tsx|600
/usr/bin/env ts-node|600
/usr/bin/env -S zx --quiet|600
/usr/bin/env swift|600
/usr/bin/env kotlin|600
/bin/dash|250
/bin/ksh -e|250
/usr/bin/env -i PATH=/bin mksh|250
/bin/ash|250
/usr/bin/env bats|250
CASES
rm -f tool; script '/usr/bin/env perl' 900 tool; script '/usr/bin/env ruby' 900 tool.rb; lines 900 notes
check; expect "uncovered interpreters and plain files are not limited" 0

# The same holds in the index, at a pushed commit and in --print-baseline.
repo modes; script '/usr/bin/python3 -I' 853 ansible/files/deploy-stage; git add -A
check --staged; expect "extension-less python, staged" 1 'deploy-stage: 853 lines, limit 600'
save; check --range "$(git rev-parse HEAD~1)" HEAD; expect "extension-less python, range" 1 'deploy-stage: 853'
check --print-baseline; expect "extension-less python, print-baseline" 0 '^baseline ansible/files/deploy-stage 853$'
scripts/check-file-lengths.sh --print-baseline >> .file-lengths; check; expect "its baseline row holds" 0

# A shebang beats an extension no org limit covers, including one a repository limits itself.
repo otherext; script '/usr/bin/env python3' 601 cgi-bin/form.cgi; script '/bin/bash' 251 templates/run.sh.j2
lines 1500 plain.cgi; lines 900 doc.md
check; expect "python behind .cgi" 1 'form.cgi: 601 lines, limit 600'
printf '%s\n' "$out" | grep -q 'run.sh.j2: 251 lines, limit 250' || expect "bash behind .j2" x
printf '%s\n' "$out" | grep -q -e plain.cgi -e doc.md && expect "files without a shebang keep no limit" x
cfg 'limit 2000 cgi j2'; check; expect "a repo limit cannot lift the shebang's limit" 1 'form.cgi: 601 lines, limit 600'
script '/bin/bash' 400 run.py; rm -rf cgi-bin templates; check; expect "an org extension beats the shebang" 0

# Extensions are matched without regard to case, also in limit lines.
repo case; lines 601 BIG.PY; lines 251 Run.Sh; lines 601 web/App.TSX
check; expect "upper-case .PY" 1 'BIG.PY: 601 lines, limit 600'
printf '%s\n' "$out" | grep -q 'Run.Sh: 251 lines, limit 250' || expect "mixed-case .Sh" x
printf '%s\n' "$out" | grep -q 'web/App.TSX: 601' || expect "upper-case .TSX" x
cfg 'limit 900 PY'; check; expect "an org limit cannot be changed in upper case" 1 'limit for .py is set org-wide'

# A dot-file with an extension counts by that extension; a bare dot-file has none.
repo dotfiles; lines 601 .eslintrc.js; lines 601 web/.storybook.config.ts; lines 900 .bashrc; lines 900 .env.example
check; expect "dot-file .eslintrc.js" 1 '\.eslintrc\.js: 601 lines, limit 600'
printf '%s\n' "$out" | grep -q 'web/.storybook.config.ts: 601' || expect "nested dot-file .ts" x
printf '%s\n' "$out" | grep -q -e bashrc -e env.example && expect "bare dot-files keep no limit" x
rm .eslintrc.js web/.storybook.config.ts; script /bin/bash 251 .profile.d; check; expect "a dot-file's shebang counts" 1 '\.profile\.d: 251'

# Variants of covered languages carry their language's limit.
repo variants; for f in stub.pyi app.pyw build.gradle.kts theme.sass; do lines 601 "$f"; done; lines 251 x.ksh; lines 251 t.bats
check; for f in stub.pyi app.pyw build.gradle.kts theme.sass; do
  printf '%s\n' "$out" | grep -q "$f: 601 lines, limit 600" || expect "variant $f is limited to 600" x
done
printf '%s\n' "$out" | grep -q 'x.ksh: 251 lines, limit 250' || expect "variant .ksh is limited to 250" x
printf '%s\n' "$out" | grep -q 't.bats: 251 lines, limit 250' || expect "variant .bats is limited to 250" x
cfg 'limit 900 pyi'; check; expect "a repo may not loosen a variant" 1 'limit for .pyi is set org-wide'

# Line endings: a lone carriage return ends a line; CRLF counts once; a tab in a name is kept.
repo endings; awk 'BEGIN { for (i = 1; i <= 601; i++) printf "x\r" }' > old-mac.rs
awk 'BEGIN { for (i = 1; i <= 600; i++) printf "x\r\n" }' > crlf.rs; printf 'x\rlast' > tail.rs
lines 601 "$(printf 'tab\tname.ts')"
check; expect "lone carriage returns end lines" 1 'old-mac.rs: 601 lines, limit 600'
printf '%s\n' "$out" | grep -q crlf.rs && expect "CRLF lines count once" x
printf '%s\n' "$out" | grep -q 'tail.rs' && expect "two short CR lines pass" x
printf '%s\n' "$out" | grep -q "$(printf 'tab\tname.ts: 601')" || expect "a tab in a file name is measured" x
git add old-mac.rs; check --staged; expect "lone carriage returns, staged" 1 'old-mac.rs: 601'

# Exempt globs still cover extension-less scripts.
repo exemptbin; script '/usr/bin/python3' 900 vendor/tool; cfg 'exempt vendor/**'
check; expect "an exempt extension-less script" 0

echo "file-lengths language tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
