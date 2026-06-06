#!/usr/bin/env bash
#
# lib/completion.sh — `vminv completion bash|zsh|fish`
#
# Emits a shell completion script to stdout. Completes commands, global flags,
# and (dynamically) profile names, --target, and --format values.
#
# Install (examples):
#   vminv completion bash | sudo tee /etc/bash_completion.d/vminv
#   vminv completion bash >> ~/.bashrc            # or source it
#   vminv completion zsh  > "${fpath[1]}/_vminv"
#   vminv completion fish > ~/.config/fish/completions/vminv.fish

cmd_completion() {
  case "${1:-}" in
    bash) _completion_bash ;;
    zsh)  _completion_zsh ;;
    fish) _completion_fish ;;
    "" )  usage_error "completion needs a shell: bash|zsh|fish" ;;
    *)    usage_error "unsupported shell '${1}' (bash|zsh|fish)" ;;
  esac
}

_completion_bash() {
cat <<'BASH'
# vminv bash completion
_vminv() {
  local cur prev cmds gflags pdir
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmds="scan configure config doctor demo profiles upload schedule upgrade completion version help"
  gflags="--profile --dry-run --no-perf --target --datacenter --cluster --folder --vm \
          --perf-days --output --dest --format --insecure --fixtures --quiet --verbose \
          --no-color --no-progress --config --cron --preset --repo --check --help --version"
  pdir="${XDG_CONFIG_HOME:-$HOME/.config}/vminv/profiles"
  case "$prev" in
    -p|--profile) COMPREPLY=( $(compgen -W "$(ls "$pdir" 2>/dev/null | sed 's/\.env$//')" -- "$cur") ); return;;
    --target)     COMPREPLY=( $(compgen -W "aws azure gcp" -- "$cur") ); return;;
    --format)     COMPREPLY=( $(compgen -W "table json" -- "$cur") ); return;;
    completion)   COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") ); return;;
    schedule)     COMPREPLY=( $(compgen -W "add list remove run" -- "$cur") ); return;;
    profiles)     COMPREPLY=( $(compgen -W "show" -- "$cur") ); return;;
  esac
  if [ "$COMP_CWORD" -eq 1 ]; then COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ); return; fi
  case "$cur" in -*) COMPREPLY=( $(compgen -W "$gflags" -- "$cur") );; esac
}
complete -F _vminv vminv
BASH
}

_completion_zsh() {
cat <<'ZSH'
#compdef vminv
_vminv() {
  local -a cmds
  cmds=(scan configure config doctor demo profiles upload schedule upgrade completion version help)
  if (( CURRENT == 2 )); then
    _describe 'command' cmds
    return
  fi
  case "$words[2]" in
    schedule) _values 'subcommand' add list remove run ;;
    completion) _values 'shell' bash zsh fish ;;
  esac
  _arguments \
    '(-p --profile)'{-p,--profile}'[profile]:profile:_files -W "${XDG_CONFIG_HOME:-$HOME/.config}/vminv/profiles"' \
    '--target[cloud target]:target:(aws azure gcp)' \
    '--format[output format]:format:(table json)' \
    '(-n --dry-run)'{-n,--dry-run}'[read-only connectivity check]' \
    '(-q --quiet)'{-q,--quiet}'[errors only]' \
    '(-v --verbose)'{-v,--verbose}'[debug to stderr]' \
    '--no-perf[skip utilization]' '--no-color[disable color]'
}
_vminv "$@"
ZSH
}

_completion_fish() {
cat <<'FISH'
# vminv fish completion
complete -c vminv -f
complete -c vminv -n '__fish_use_subcommand' -a 'scan configure config doctor demo profiles upload schedule upgrade completion version help'
complete -c vminv -n '__fish_seen_subcommand_from schedule' -a 'add list remove run'
complete -c vminv -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
complete -c vminv -s p -l profile -d 'Profile' -x -a '(ls (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo $HOME/.config)/vminv/profiles 2>/dev/null | sed "s/.env\$//")'
complete -c vminv -l target -x -a 'aws azure gcp' -d 'Cloud target'
complete -c vminv -l format -x -a 'table json' -d 'Output format'
complete -c vminv -s n -l dry-run -d 'Read-only connectivity check'
complete -c vminv -s q -l quiet -d 'Errors only'
complete -c vminv -s v -l verbose -d 'Debug to stderr'
complete -c vminv -l no-perf -d 'Skip utilization'
FISH
}
