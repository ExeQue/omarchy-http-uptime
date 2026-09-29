#!/usr/bin/env bash
# Custom header values live in the Secret Service keyring (gnome-keyring), one item per URL and
# header name. Values never appear in argv: they arrive on stdin and reach secret-tool through a pipe.
#
#   secrets.sh set URL NAME       value on the first line of stdin
#   secrets.sh unset URL NAME
#   secrets.sh clear URL          remove every header stored for URL
#   secrets.sh rename OLD NEW NAME...
source "$(dirname "$0")/history.sh"
service=exeque.omarchy-http-uptime

valid_name() { [[ $1 =~ ^[!#\$%\&\'*+.^_\`\|~0-9A-Za-z-]{1,64}$ ]]; }

store() { # url name, value on stdin
  secret-tool store --label="HTTP Uptime: $2 for $1" service "$service" url "$1" header "$2"
}

case $1 in
  set)
    valid_name "$3" || { echo "invalid header name" >&2; exit 1; }
    IFS= read -r value
    # No CR/LF (header injection); the length cap keeps curl's header file small.
    [[ $value != *$'\r'* && ${#value} -le $max_header_value ]] || { echo "invalid header value" >&2; exit 1; }
    printf '%s' "$value" | store "$2" "$3"
    ;;
  unset) secret-tool clear service "$service" url "$2" header "$3" ;;
  clear) secret-tool clear service "$service" url "$2" ;;
  rename)
    old=$2 new=$3; shift 3
    for name in "$@"; do
      valid_name "$name" || continue
      value=$(secret-tool lookup service "$service" url "$old" header "$name") || continue
      printf '%s' "$value" | store "$new" "$name" && secret-tool clear service "$service" url "$old" header "$name"
    done
    ;;
  *) echo "usage: secrets.sh set|unset|clear|rename ..." >&2; exit 2 ;;
esac
