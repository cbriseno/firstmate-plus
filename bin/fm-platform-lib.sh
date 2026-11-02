#!/usr/bin/env bash
# Portable runtime boundary, sourced by startup, bootstrap, spawn and doctor.
# fm_platform_name prints linux, macos, wsl2, wsl1, windows-shell or unsupported.
# fm_platform_require refuses unsupported POSIX/process environments before any
# operational mutation. No installs, probes of agents, or platform overrides.

fm_platform_name() {
  local kernel release
  kernel=$(uname -s 2>/dev/null) || kernel=
  case "$kernel" in
    Darwin) printf '%s\n' macos ;;
    Linux)
      release=$(uname -r 2>/dev/null) || release=
      case "$release" in
        *[Mm]icrosoft*WSL2*|*[Mm]icrosoft*wsl2*) printf '%s\n' wsl2 ;;
        *[Mm]icrosoft*) printf '%s\n' wsl1 ;;
        *) printf '%s\n' linux ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) printf '%s\n' windows-shell ;;
    *) printf '%s\n' unsupported ;;
  esac
}

fm_platform_require() {
  local platform
  platform=$(fm_platform_name)
  case "$platform" in
    linux|macos|wsl2) return 0 ;;
    windows-shell|wsl1)
      printf 'PLATFORM_UNSUPPORTED: use WSL2 with Linux tools and a Linux filesystem; native Windows, Git Bash, Cygwin and WSL1 are not validated Firstmate runtimes. See docs/platforms.md.\n' >&2
      ;;
    *)
      printf 'PLATFORM_UNSUPPORTED: Firstmate requires Linux, macOS or WSL2; this kernel has no validated runtime route. See docs/platforms.md.\n' >&2
      ;;
  esac
  return 1
}
