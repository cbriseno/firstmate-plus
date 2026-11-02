#!/usr/bin/env bash
# Discover unattended, home-owned Lavish boards without consuming feedback.
# Usage: fm-lavish-watch.sh scan|needed
# needed is read-only: exit 0 for an owned open board, 1 for none, 2 on error.
#
# Called every fm-watch cycle, even when no process-event registry exists.
# Reads Lavish's saved sessions and this home's direct task metadata only.
# Ownership is confined to FM_HOME/.lavish, FM_HOME/data, recorded task
# worktrees, and boards already registered in this home's process-event store.
# The private owners.json retains discovered task ownership after teardown;
# unknown boards elsewhere on the machine are never adopted.
#
# After 30 seconds without a supervised listener, enqueue a durable check wake,
# with a reminder every 300 seconds until coverage returns or the session ends
# with no queued feedback. Bounds are observation times plus the watcher cadence.
# An open worker round is covered by its immutable captured result, not another
# listener: after the same grace, ask firstmate to verify the worker is handling
# it and re-arms when finished. Never acknowledge it or re-arm on its behalf.
# A listener claim is structural process-event evidence, not a Lavish CLI label.
# This deliberately also detects unmanaged polls without a verified wake path.
# No poll, reply, open, end, takeover, answer intake or task lifecycle operation
# occurs here. Existing reconcile owns repairing registered dead listeners.
# Restart-safe episodes and queue publication are serialized by one home lock;
# failed publication never advances a reminder checkpoint. This scan has no
# network dependency and does not require a particular agent harness/backend.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "${1-}" in
  scan|needed) [ "$#" -eq 1 ] || exit 2 ;;
  *) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac

store="${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json"
[ -e "$store" ] || { [ "$1" = scan ]; exit $?; }
watch_dir="$STATE/lavish-watch"
if [ "$1" = scan ]; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
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
    open my $f, "<", $path or die "$path: $!\n";
    local $/; return decode_json(<$f>);
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
    print "$id\t$task\t$file\n";
  }
  exit 0 if $mode eq "needed";
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

sources=''
if [ -s "$rows" ]; then
  sources=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" list) || exit 1
fi
now=$(date +%s)
seen=' '
while IFS=$'\t' read -r id task artifact; do
  [ -n "$id" ] || continue
  seen="$seen$id "
  marker="$watch_dir/$id.unattended"
  [ ! -L "$marker" ] || exit 1
  owner=$(printf '%s\n' "$sources" | awk -v id="$id" '$1 == id { print $3; exit }')
  case "$owner" in
    live|task:*/listening) rm -f -- "$marker"; continue ;;
  esac
  since=$now last=0 nonce="$now-$RANDOM$RANDOM"
  if [ -f "$marker" ]; then
    read -r since last nonce < "$marker" || exit 1
    [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$nonce" =~ ^[0-9]+-[0-9]+$ ]] || exit 1
  fi
  if [ "$((now - since))" -ge 30 ] && { [ "$last" -eq 0 ] || [ "$((now - last))" -ge 300 ]; }; then
    case "$owner" in
      task:*/round-open)
        detail="Captured feedback is still held by $owner. Verify the worker is handling it; steer it to finish its reply and re-arm after the nonterminal round, or conclude a terminal round. Never acknowledge or re-arm on its behalf." ;;
      *)
        detail="No supervised listener is confirmed (source state: ${owner:-unregistered}; recorded task: $task). Recover the recorded worker before arming a task-owned board; for a firstmate-owned board, arm through the Lavish adapter. Preserve existing captured rounds and ownership; do not reopen an ended session or take over another listener." ;;
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
for marker in "$watch_dir"/*.unattended; do
  [ -f "$marker" ] && [ ! -L "$marker" ] || continue
  id=${marker##*/}; id=${id%.unattended}
  case "$seen" in *" $id "*) ;; *) rm -f -- "$marker" ;; esac
done
