# shellcheck shell=bash
# Optional card_time contract shared by fleet summaries and bearings rows.
# A record is {kind,value,precision,source}, optionally with an existing attempt
# (spawn_gen). Unknown is null. Values retain their original date or explicit
# offset/Z instant; precision is date or second. No observation clocks, file
# times, inferred queue entries, or invented event identities are used.
# Kinds: filed, queued, asked, updated, ready, done_report, delivered.
# Current producers export filed/asked/updated/done_report/delivered; ready and
# queued require separate authoritative transition evidence, never prose.
# Source fm-landed-lib.sh and fm-classify-lib.sh before the helpers.
# fm-classify-lib.sh owns status verbs and [at=epoch]; fm-landed-lib.sh owns
# accepted delivery semantics. The snapshot supplies captured home-owned ranges,
# excluding polling and control receipts without interpreting message prose.

# shellcheck disable=SC2034,SC2016 # Sourcing callers consume literal jq variables.
FM_CARD_TIME_JQ_DEFS='
  def card_time($kind; $value; $source):
    (if ($value | type) != "string" then null
     elif ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then
       if (try (($value + "T00:00:00Z" | fromdateiso8601 | strftime("%Y-%m-%d")) == $value) catch false)
       then "date" else null end
     elif ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$")) then
       ($value[:19] + "Z") as $utc
       | if (try (($utc | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $utc) catch false)
          and (($value | endswith("Z")) or
               (($value[20:22] | tonumber) <= 23 and ($value[23:25] | tonumber) <= 59))
         then "second" else null end
     else null end) as $precision
    | if $precision == null then null
      else {kind:$kind,value:$value,precision:$precision,source:$source} end;
  def backlog_card_time:
    if .hold_bucket != null then card_time("asked"; .hold_set; "backlog.hold_set")
    else card_time("filed"; .since; "backlog.since") end;
  def delivered_card_time:
    if landed_artifact != null then card_time("delivered"; .completion.date; ("backlog.completion." + (.completion.verb // "unknown")))
    else null end;
'

fm_card_time_latest_declaration() {  # <captured-status> <captured-home-ranges> [<start-byte>]
  local log=$1 ranges=$2 start_byte=${3:-0} line verb latest=''
  case "$start_byte" in ''|*[!0-9]*) return 0 ;; esac
  [ -f "$log" ] || return 0
  # Byte offsets refer to the captured full log, not a tail with a shifted origin.
  # Only the last 200 foreign lines are parsed; a later unstamped declaration
  # supersedes an earlier timestamp instead of borrowing it.
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    case "$verb" in
      working|needs-decision|blocked|done|failed|paused|resolved|captain-held|note) latest=$line ;;
    esac
  done < <(LC_ALL=C awk -v start_byte="$start_byte" '
    FILENAME == ARGV[1] { starts[++n]=$1; ends[n]=$2; next }
    { end=offset+length($0)+1; owned=0
      for (i=1; i<=n; i++) if (starts[i]<=offset && ends[i]>=end) { owned=1; break }
      if (!owned && offset>=start_byte) print
      offset=end
    }' "$ranges" "$log" | tail -n 200)
  printf '%s' "$latest"
}

fm_card_time_progress_json() {  # <captured-status> <captured-home-ranges> <spawn-gen> <spawned-at> [<start-byte>]
  local log=$1 ranges=$2 attempt=$3 spawned_at=$4 start_byte=${5:-0} verb latest epoch='' start_epoch=''
  if [ -n "$spawned_at" ]; then
    start_epoch=$(fm_utc_iso_to_epoch "$spawned_at") || { printf 'null\n'; return 0; }
  fi
  latest=$(fm_card_time_latest_declaration "$log" "$ranges" "$start_byte")
  epoch=$(status_line_at_epoch "$latest") || { printf 'null\n'; return 0; }
  if [ -n "$start_epoch" ] && [ "$epoch" -lt "$start_epoch" ]; then
    printf 'null\n'
    return 0
  fi
  status_line_verb "$latest" verb
  jq -n --argjson epoch "$epoch" --arg verb "$verb" --arg attempt "$attempt" \
    --arg boundary "$spawned_at" "${FM_LANDED_JQ_DEFS:-}$FM_CARD_TIME_JQ_DEFS"'
    (try ($epoch | strftime("%Y-%m-%dT%H:%M:%SZ")) catch null) as $value
    | card_time((if $verb == "done" then "done_report" else "updated" end); $value; "status.declaration.at")
    | if . == null then null
      else . + {original_value:$epoch,attempt_boundary:(if $boundary == "" then "unknown" else $boundary end)}
        + (if $attempt == "" then {}
           elif $boundary == "" then {current_attempt:$attempt}
           else {attempt:$attempt} end) end'
}
