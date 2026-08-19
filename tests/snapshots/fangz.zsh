#fangz completion
_fangz_completion() {
  local -a reply
  reply=("${(@f)$(fangz __complete ${words[2,-1]})}")
  _describe 'values' reply
}
compdef _fangz_completion fangz
