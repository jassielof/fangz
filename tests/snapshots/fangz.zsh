#fangz completion
_fangz_completion() {
  local -a reply
  local line value
  for line in "${(@f)$(fangz __complete "${(@)words[2,-1]}")}"; do
    [[ -n $line ]] || continue
    value=${line%%$'\t'*}
    if [[ $line == *$'\t'* ]]; then
      reply+=("${value//:/\\:}:${line#*$'\t'}")
    else
      reply+=("${value//:/\\:}")
    fi
  done
  _describe 'values' reply
}
compdef _fangz_completion fangz
