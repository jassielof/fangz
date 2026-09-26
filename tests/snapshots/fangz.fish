function __fangz_complete
  set -l tokens (commandline -opc)
  set -l current (commandline -ct)
  set -e tokens[1]
  fangz __complete $tokens "$current"
end
complete -f -c fangz -a "(__fangz_complete)"
