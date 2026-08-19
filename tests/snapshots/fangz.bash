_fangz_completion() {
  local IFS=$'\n'
  COMPREPLY=($("$(COMP_WORDS[0])" __complete "${COMP_WORDS[@]:1}"))
}
complete -o default -F _fangz_completion fangz
