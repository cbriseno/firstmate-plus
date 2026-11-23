#!/usr/bin/env bash
# Primary Stop registration and existing Codex notify entry point.
# Usage: fm-primary-final.sh claude|codex [<Codex notify JSON>]
# With no JSON argument, read the hook payload from stdin.
set -u
case "${1:-}" in claude|codex) ;; *) exit 2 ;; esac
exec "${BASH_SOURCE[0]%/*}/fm-host-mirror.sh" final "$@"
