function __fangz_complete
  set -l tokens (commandline -opc)
  set -e tokens[1]
  fangz __complete $tokens
end
complete -f -c fangz -a "(__fangz_complete)"
