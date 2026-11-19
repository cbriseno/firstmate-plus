#!/usr/bin/env bash
# Discover and recover unattended, home-owned Lavish boards.
# Usage: fm-lavish-watch.sh scan|needed|owned|in-use <task>
# needed is read-only: exit 0 for an owned open board, 1 for none, 2 on error.
# owned is read-only too: it prints one tab-separated line per open board
# (task, artifact, status, pending prompts) - task is - for a home board no task
# owns - and exits 0 even for none, so closing a delivered worker can tell that
# a live board still needs its owner; any error exits 2 with nothing printed.
# in-use <task> is read-only too: it prints each open board the task owns whose
# agent listener is live, so the captain may be using it. Exit 0 if any, 1 if
# none, 2 on error. Stopping, pausing, relaunching or closing that worker would
# strand the board (captain rule 27); fm-control.sh and fm-teardown.sh refuse.
#
# Called every fm-watch cycle, even when no process-event registry exists.
# Reads saved sessions, local server health, and this home's task metadata.
# Ownership is confined to FM_HOME/.lavish, FM_HOME/data, recorded task
# worktrees, and boards already registered in this home's process-event store.
# The private owners.json retains discovered task ownership after teardown;
# unknown boards elsewhere on the machine are never adopted.
#
# After 30 seconds without a supervised listener, enqueue a durable check wake,
# once per loss until coverage returns or the session ends with no queued feedback.
# An open worker round is covered by its immutable captured result, not another
# listener while its worker is provably working or parked; otherwise after the same grace,
# ask firstmate to verify it. Never acknowledge it or re-arm on its behalf.
# A listener claim is structural process-event evidence, not a Lavish CLI label.
# This deliberately also detects unmanaged polls without a verified wake path.
# Missing registrations are restored without acknowledging any captured round.
# Existing reconcile owns starting registered listeners. No session is reopened,
# no listener is displaced, and task ownership remains attached to the source.
# Restart-safe episodes and queue publication are serialized by one home lock;
# failed publication never advances a reminder checkpoint. This scan has no
# external network dependency and does not require a particular agent harness/backend.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "${1-}" in
  scan|needed|owned) [ "$#" -eq 1 ] || exit 2 ;;
  in-use) [ "$#" -eq 2 ] && [[ "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || exit 2 ;;
  *) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac

store="${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json"
# Without a store no board exists: needed and in-use report none, the rest succeed empty.
[ -e "$store" ] || case "$1" in needed|in-use) exit 1 ;; *) exit 0 ;; esac
watch_dir="$STATE/lavish-watch"
if [ "$1" = scan ]; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  (umask 077; mkdir -p "$watch_dir") || exit 1
  [ -d "$watch_dir" ] && [ ! -L "$watch_dir" ] || exit 1
  fm_lock_acquire_wait "$watch_dir/.lock" || exit 1
fi
rows=''
mode=$1
cleanup() {
  [ -z "$rows" ] || rm -f -- "$rows"
  [ "$mode" != scan ] || fm_lock_release "$watch_dir/.lock"
}
trap cleanup EXIT
rows=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-lavish-scan.XXXXXX") || exit 2

# Persist only ownership, never feedback. Session content is untrusted data;
# control-bearing paths are refused before the tab-separated internal channel.
perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=encode,decode -MFile::Glob=bsd_glob -e '
  use strict; use warnings;
  binmode STDOUT, ":encoding(UTF-8)";
  my ($store, $home, $state, $index, $mode) = @ARGV;
  sub load_json {
    my ($path) = @_;
    -f $path && !-l $path or die "unsafe Lavish supervision input: $path\n";
    my $f;
    if ($path eq $store) {
      # Feedback can dwarf session metadata. Project it with the existing jq
      # dependency before decoding; supervision never reads feedback content.
      open $f, "-|", "jq", "-c", q({sessions: (.sessions | with_entries(
        .value |= if type == "object" then {file,status,pending_prompts,url} else . end
      ))}), $path or die "$path: $!\n";
    } else {
      open $f, "<", $path or die "$path: $!\n";
    }
    local $/; my $saved = decode_json(<$f>);
    close $f or die "could not read Lavish supervision input: $path\n";
    return $saved;
  }
  sub clean { defined($_[0]) && !ref($_[0]) && $_[0] !~ /[\x00-\x1f\x7f]/ }
  sub within { $_[0] eq $_[1] || index($_[0], "$_[1]/") == 0 }
  $home = decode("UTF-8", realpath($home) // die "missing home\n");
  my $saved = load_json($store);
  ref($saved) eq "HASH" && ref($saved->{sessions}) eq "HASH" or die "invalid Lavish sessions\n";
  my $owners = -e $index || -l $index ? load_json($index) : {};
  ref($owners) eq "HASH" or die "invalid board ownership index\n";
  my @roots;
  for my $meta (bsd_glob("$state/*.meta")) {
    next unless -f $meta && !-l $meta;
    my ($task) = $meta =~ m{/([a-zA-Z0-9][a-zA-Z0-9_-]*)\.meta\z};
    next unless defined $task;
    push @roots, ["$home/data/$task", $task];
    open my $f, "<", $meta or die "$meta: $!\n";
    while (<$f>) {
      chomp;
      next unless /^worktree=(.+)$/ && clean($1);
      my $root = realpath($1);
      push @roots, [decode("UTF-8", $root), $task] if defined $root;
    }
  }
  # Longest root wins, so a nested task data path is not firstmate-owned.
  @roots = sort { length($b->[0]) <=> length($a->[0]) } @roots;
  my %registered;
  for my $source (bsd_glob("$state/procevent/lavish-*.source")) {
    next unless -f $source && !-l $source;
    open my $f, "<", $source or die "$source: $!\n";
    my @lines = <$f>; chomp @lines;
    next unless $lines[0] eq "adapter=lavish";
    my ($task) = map { /^owner_task=([a-zA-Z0-9][a-zA-Z0-9_-]*)$/ ? $1 : () } @lines;
    for my $i (0 .. $#lines - 3) {
      next unless $lines[$i] eq "argv:" && $lines[$i+2] eq "poll";
      $registered{decode("UTF-8", $lines[$i+3])} = $task // "-" if clean($lines[$i+3]);
    }
  }
  my %keep;
  for my $session (values %{$saved->{sessions}}) {
    next unless ref($session) eq "HASH" && clean($session->{file});
    my $file = $session->{file};
    # Saved paths are canonical; do not use a new symlink to claim another home.
    next unless $file =~ m{\A/} && $file !~ m{/(?:\.|\.\.)(?:/|\z)};
    my $real = realpath(encode("UTF-8", $file));
    next if defined($real) && decode("UTF-8", $real) ne $file;
    my $task = $registered{$file} // $owners->{$file};
    if (!defined($task)) {
      for my $root (@roots) { if (within($file, $root->[0])) { $task = $root->[1]; last } }
    }
    $task //= "-" if within($file, "$home/.lavish") || within($file, "$home/data");
    next unless defined($task) && $task =~ /\A(?:-|[a-zA-Z0-9][a-zA-Z0-9_-]*)\z/;
    $keep{$file} = $task;
    next if ($session->{status} // "") eq "ended" && !($session->{pending_prompts} // 0);
    my $id = "lavish-" . substr(sha256_hex(encode("UTF-8", $file)), 0, 16);
    my $pending = $session->{pending_prompts} // 0;
    $pending = 0 unless !ref($pending) && $pending =~ /\A[0-9]+\z/;
    my $url = $session->{url} // "";
    my ($port) = $url =~ m{\Ahttps?://[^/:]+:(\d+)/session/[a-f0-9]+\z};
    $port //= 0;
    my $status = ($session->{status} // "") eq "ended" ? "ended" : "open";
    print "$id\t$task\t$file\t$status\t$pending\t$port\n";
  }
  exit 0 if $mode ne "scan";
  my $tmp = "$index.$$";
  -e $tmp || -l $tmp and die "ownership staging collision\n";
  open my $out, ">", $tmp or die "$tmp: $!\n";
  chmod 0600, $tmp or die "$tmp: $!\n";
  print $out encode_json(\%keep);
  close $out or die "$tmp: $!\n";
  rename $tmp, $index or die "$index: $!\n";
' "$store" "$FM_HOME" "$STATE" "$watch_dir/owners.json" "$mode" > "$rows" || exit 2

if [ "$mode" = needed ]; then
  [ -s "$rows" ]
  exit $?
fi
if [ "$mode" = owned ]; then
  awk -F'\t' '{ print $2 "\t" $3 "\t" $4 "\t" $5 }' "$rows"
  exit 0
fi

if [ "$mode" = in-use ]; then
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required for Lavish listener discovery" >&2; exit 2; }
  found=1
  while IFS=$'\t' read -r id task artifact status _ port; do
    [ "$task" = "$2" ] && [ "$status" = open ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || continue
    health=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null) || continue
    printf '%s' "$health" | jq -e --arg dir "$(dirname "$store")" --arg key "${id#lavish-}" '
      .app == "lavish-axi" and .state_dir == $dir and (.listeners | type) == "array"
      and any(.listeners[]; .key == $key)' >/dev/null 2>&1 || continue
    printf '%s\n' "$artifact"
    found=0
  done < "$rows"
  exit "$found"
fi

sources=''
if [ -s "$rows" ]; then
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required for Lavish listener discovery" >&2; exit 1; }
  sources=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" list) || exit 1
fi
now=$(date +%s)
seen=' '
while IFS=$'\t' read -r id task artifact status pending port; do
  [ -n "$id" ] || continue
  seen="$seen$id "
  marker="$watch_dir/$id.unattended"
  [ ! -L "$marker" ] || exit 1
  owner=$(printf '%s\n' "$sources" | awk -v id="$id" '$1 == id { print $3; exit }')
  # The server reports its active listeners. Verify it owns this exact state
  # directory before using that answer; a stale URL is not evidence of absence.
  listener=unknown
  if [ "$port" -gt 0 ] && [ "$port" -le 65535 ]; then
    health_rc=0
    health=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null) || health_rc=$?
    if [ "$health_rc" -eq 7 ]; then
      listener=none
    elif [ "$health_rc" -eq 0 ]; then
      listener=$(printf '%s' "$health" | jq -r --arg dir "$(dirname "$store")" --arg key "${id#lavish-}" '
        if .app == "lavish-axi" and .state_dir == $dir and (.listeners | type) == "array"
        then if any(.listeners[]; .key == $key) then "live" else "none" end
        else "unknown" end' 2>/dev/null || printf unknown)
    fi
  fi
  pending_wake=0
  pending_marker="$watch_dir/$id.pending"
  [ ! -L "$pending_marker" ] || exit 1
  if [ "$listener" = none ] && [ "$pending" -gt 0 ]; then
    if [ ! -f "$pending_marker" ]; then
      nonce="$now-$RANDOM$RANDOM"
      fm_wake_append check "procevent:$id:unattended:$nonce:$now" \
        "check: unattended Lavish board: $artifact has queued feedback and no listener (recorded task: $task). Preserve its ownership and captured rounds." || exit 1
      : > "$pending_marker" || exit 1
      pending_wake=1
    fi
  elif [ "$listener" = live ] || [ "$pending" -eq 0 ]; then
    rm -f -- "$pending_marker"
  fi
  if [ "$listener" = none ] && [ "$status" = open ] && [ -z "$owner" ] && [ -e "$artifact" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" recover-lavish "$id" "$task" "$artifact" || {
      [ ! -e "$artifact" ] || exit 1
    }
  fi
  case "$owner" in
    live|task:*/listening) rm -f -- "$marker"; continue ;;
    task:*/round-open)
      owner_task=${owner#task:}; owner_task=${owner_task%/round-open}
      # A parked owner's round is already on its way: publication resumes it
      # or hands the round to firstmate.
      if crew_is_provably_working "$owner_task" || [ -f "$STATE/$owner_task.parked" ]; then
        rm -f -- "$marker"; continue
      fi ;;
  esac
  since=$now last=0 nonce="$now-$RANDOM$RANDOM"
  if [ -f "$marker" ]; then
    read -r since last nonce < "$marker" || exit 1
    [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$nonce" =~ ^[0-9]+-[0-9]+$ ]] || exit 1
  fi
  [ "$pending_wake" -eq 0 ] || last=$now
  if [ "$((now - since))" -ge 30 ] && [ "$last" -eq 0 ]; then
    case "$owner" in
      task:*/round-open)
        detail="Captured feedback is still held by $owner. Verify the worker is handling it; steer it to finish its reply and re-arm after the nonterminal round, or conclude a terminal round. Never acknowledge or re-arm on its behalf." ;;
      *)
        detail="No supervised listener is confirmed (source state: ${owner:-unregistered}; recorded task: $task). Check the recorded worker and reconciliation; preserve captured rounds and ownership, and do not reopen an ended session or take over another listener." ;;
    esac
    fm_wake_append check "procevent:$id:unattended:$nonce:$now" \
      "check: unattended Lavish board: $artifact. $detail" || exit 1
    last=$now
    printf 'unattended: %s\n' "$id"
  fi
  tmp=$(umask 077; mktemp "$watch_dir/.episode.XXXXXX") || exit 1
  printf '%s %s %s\n' "$since" "$last" "$nonce" > "$tmp" && mv -f -- "$tmp" "$marker" || exit 1
done < "$rows"

# Closing, removing, or restoring coverage ends an episode. A later loss has a
# new nonce, so the watcher never suppresses it as an already-surfaced wake.
for marker in "$watch_dir"/*.unattended "$watch_dir"/*.pending; do
  [ -f "$marker" ] && [ ! -L "$marker" ] || continue
  id=${marker##*/}; id=${id%.unattended}; id=${id%.pending}
  case "$seen" in *" $id "*) ;; *) rm -f -- "$marker" ;; esac
done
