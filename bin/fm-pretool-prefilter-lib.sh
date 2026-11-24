#!/usr/bin/env bash
# Shared strict-superset prefilters for the PreToolUse seatbelts.
# Sourced by bin/fm-arm-pretool-check.sh, bin/fm-cd-pretool-check.sh,
# bin/fm-primary-write-pretool-check.sh and bin/fm-pretool-check.sh; sourcing
# has no side effects. Each function takes the decoded shell command and returns
# 0 when the owning classifier MUST see it and 1 when it can never be a
# deniable command. They own zero classification semantics: the classifiers
# (bin/fm-arm-command-policy.mjs, bin/fm-cd-command-policy.mjs,
# bin/fm-primary-write-policy.mjs) remain the sole owners of every decision.
#
# Quotes, backslashes and line breaks are stripped first, so quoted or escaped
# fragments still reach the classifier. An ANSI-C ($'...') or locale ($"...")
# quote delegates outright because the classifiers decode those and can rebuild
# a word from bytes a byte strip cannot see. That marker set is COUPLED to the
# classifier decoder set in bin/fm-arm-command-policy.mjs: adding any quote or
# expansion form the classifier decodes REQUIRES extending it here in the same
# change, or every prefilter stops being a strict superset.

# Return 0 when the command carries a quoting-decoder marker.
fm_prefilter_decoder_marker() {  # <command>
  case "$1" in
    *"\$'"*|*'$"'*) return 0 ;;
  esac
  return 1
}

# Sets FM_PREFILTER_TEXT: the command without backslashes, quotes, and line
# breaks joined ($2 = join text; "" for the arm and cd classifiers).
fm_prefilter_strip() {  # <command> [newline-replacement]
  local text=$1 join=${2-}
  text=${text//\\/}
  text=${text//\"/}
  text=${text//\'/}
  text=${text//$'\n'/$join}
  text=${text//$'\r'/$join}
  FM_PREFILTER_TEXT=$text
}

# Watcher-arm seatbelt: only an fm-watch byte sequence can be deniable.
fm_prefilter_arm_may_match() {  # <command>
  fm_prefilter_decoder_marker "$1" && return 0
  fm_prefilter_strip "$1"
  case "$FM_PREFILTER_TEXT" in *fm-watch*) return 0 ;; esac
  return 1
}

# cd-guard seatbelt: only cd, pushd or popd can be a deniable cwd change.
fm_prefilter_cd_may_match() {  # <command>
  fm_prefilter_decoder_marker "$1" && return 0
  fm_prefilter_strip "$1"
  case "$FM_PREFILTER_TEXT" in *cd*|*pushd*|*popd*) return 0 ;; esac
  return 1
}

# Primary write guard: a command with no redirection and no write-shaped command
# word cannot produce a target. The stem list is COUPLED to the command classes
# in bin/fm-primary-write-policy.mjs: adding a command there REQUIRES adding its
# name here in the same change.
fm_prefilter_write_may_match() {  # <command>
  local stems='sudo|doas|su|pkexec|cat|head|tail|less|more|awk|grep|rg|bat|base64|strings|tee|cp|mv|install|ln|rsync|rm|rmdir|unlink|shred|touch|mkdir|truncate|chmod|chown|chgrp|sed|dd|curl|wget|git|apply_patch|eval|xargs|find|bash|sh|zsh|dash|ksh|python[0-9.]*|node|nodejs|bun|deno|perl|ruby'
  fm_prefilter_decoder_marker "$1" && return 0
  case "$1" in *'>'*) return 0 ;; esac
  fm_prefilter_strip "$1" ' '
  [[ " $FM_PREFILTER_TEXT " =~ (^|[^A-Za-z0-9_.-])($stems)([^A-Za-z0-9_-]|$) ]]
}
