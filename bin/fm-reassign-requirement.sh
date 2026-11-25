#!/usr/bin/env bash
# Usage: fm-reassign-requirement.sh <source-task> <requirement-number> <destination-task> [scope [destination-brief]]
# Mark a requirement or an exact portion as reassigned after the destination
# brief carries that scope. For partial scope, acceptance evidence covers the
# remainder. Both briefs live under FM_DATA_OVERRIDE
# (or FM_HOME/data). An optional destination brief retains a copy beside the
# source brief for a destination on another machine; it never edits the destination.
set -eu
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# *//'
  exit 0
fi
[ "$#" = 3 ] || [ "$#" = 4 ] || [ "$#" = 5 ] || { echo 'usage: fm-reassign-requirement.sh <source-task> <requirement-number> <destination-task> [scope [destination-brief]]' >&2; exit 2; }
script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
data=${FM_DATA_OVERRIDE:-${FM_HOME:-.}/data}
python3 - "$data" "$1" "$2" "$3" "$script_dir" "${4:-}" "${5:-}" <<'PY'
from pathlib import Path
import re, subprocess, sys

data, source, number, target, scripts, scope, destination_file = sys.argv[1:]
if not all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', x) for x in (source, target)) or source == target or not re.fullmatch(r'[1-9][0-9]*', number):
    sys.exit('invalid source, requirement number, or destination')
source_brief, target_brief = (Path(data) / x / 'brief.md' for x in (source, target))
if destination_file:
    target_brief = Path(destination_file)
def requirements(brief):
    result = subprocess.run(['bash', str(Path(scripts) / 'fm-brief.sh'), '--requirements', str(brief)], text=True, capture_output=True, check=True)
    return [line.split('. ', 1)[1] for line in result.stdout.splitlines() if '. ' in line]
try:
    original = requirements(source_brief)
    index = int(number) - 1
    if index >= len(original):
        sys.exit('requirement number is out of range')
    scope = scope or original[index]
    if '\n' in scope or scope not in original[index] or scope not in target_brief.read_text(encoding='utf-8'):
        sys.exit('scope must occur in the original requirement and destination brief')
    text = source_brief.read_text(encoding='utf-8')
    heading = '## Reassigned requirements\n'
    if heading in text:
        start = text.index(heading) + len(heading)
        end = text.find('\n## ', start)
        if end < 0:
            end = text.find('\n# ', start)
        if end < 0:
            end = len(text)
        entries = [line for line in text[start:end].splitlines() if line.strip()]
        entry = number + '. ' + target + ' ' + scope
        if entry in entries:
            sys.exit('scope already reassigned')
        entries.append(entry)
        text = text[:start] + '\n'.join(entries) + '\n' + text[end:]
    else:
        marker = '\n## Captain\'s requirements\n'
        if text.count(marker) != 1:
            sys.exit('source brief must have one requirements heading')
        text = text.replace(marker, '\n' + heading + number + '. ' + target + ' ' + scope + '\n' + marker, 1)
    if destination_file:
        retained = source_brief.parent / ('reassignment-destination-' + target + '.md')
        retained.write_text(target_brief.read_text(encoding='utf-8'), encoding='utf-8')
    source_brief.write_text(text, encoding='utf-8')
except (OSError, subprocess.SubprocessError, UnicodeError) as error:
    sys.exit(str(error))
PY
