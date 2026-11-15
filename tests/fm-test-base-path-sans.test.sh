#!/usr/bin/env bash
# Curated PATH preserves tool resolution and avoids per-entry link processes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-base-path-sans)
shopt -u dotglob
first="$TMP_ROOT/first"
second="$TMP_ROOT/second"
shim="$TMP_ROOT/shim"
mkdir -p "$first/dir-tool" "$second" "$shim"
printf 'sentinel\n' > "$first/dir-tool/sentinel"
printf 'second directory-name candidate\n' > "$second/dir-tool"
for dir in "$first" "$second"; do
  printf '#!/bin/sh\nprintf "omitted\\n"\n' > "$dir/fm-omitted"
  chmod +x "$dir/fm-omitted"
done
printf '#!/bin/sh\nprintf "first\\n"\n' > "$first/fm-kept"
printf '#!/bin/sh\nprintf "second\\n"\n' > "$second/fm-kept"
printf '#!/bin/sh\nprintf "secondary\\n"\n' > "$second/fm-secondary"
chmod +x "$first/fm-kept" "$second/fm-kept" "$second/fm-secondary"
printf 'space and glob name\n' > "$first/space [name]"
printf 'hidden\n' > "$first/.hidden"
ln -s "$first/missing-target" "$first/dangling"
for ((i=0; i<130; i++)); do printf 'fixture\n' > "$first/bulk-$i"; done
real_ln=$(command -v ln) || fail "ln is unavailable"
cat > "$shim/ln" <<'SH'
#!/usr/bin/env bash
printf 'link call\n' >> "$FM_TEST_LINK_LOG"
exec "$FM_TEST_REAL_LN" "$@"
SH
chmod +x "$shim/ln"
log="$TMP_ROOT/link-calls"
: > "$log"
curated=$(FM_TEST_LINK_LOG="$log" FM_TEST_REAL_LN="$real_ln" PATH="$shim:$PATH" \
  fm_test_base_path_sans "$first:$second" fm-omitted) || fail "PATH curation failed"
[ ! -e "$curated/fm-omitted" ] && [ ! -L "$curated/fm-omitted" ] \
  || fail "an excluded tool survived curation"
! PATH="$curated" command -v fm-omitted >/dev/null 2>&1 \
  || fail "the excluded tool still resolves"
[ "$(PATH="$curated" fm-kept)" = first ] || fail "source PATH precedence changed"
[ "$(PATH="$curated" fm-secondary)" = secondary ] || fail "an unrelated tool was lost"
[ "$(readlink "$curated/space [name]")" = "$first/space [name]" ] \
  || fail "a space/glob filename was changed"
[ -L "$curated/dangling" ] && [ ! -e "$curated/dangling" ] \
  || fail "a dangling source link was not preserved"
[ "$(readlink "$curated/dir-tool")" = "$first/dir-tool" ] \
  || fail "a directory link lost first-path precedence"
[ "$(ls -A "$first/dir-tool")" = sentinel ] \
  || fail "curation traversed a source directory link"
[ ! -e "$curated/.hidden" ] || fail "default glob filtering changed"
for ((i=0; i<130; i++)); do
  [ "$(readlink "$curated/bulk-$i")" = "$first/bulk-$i" ] \
    || fail "a batched entry was lost"
done
calls=$(wc -l < "$log")
[ "$calls" -lt 10 ] || fail "PATH curation still launches per-entry link processes ($calls)"
pass "curated PATH keeps omission, precedence and link types with $calls link-tool calls for 130 entries"
