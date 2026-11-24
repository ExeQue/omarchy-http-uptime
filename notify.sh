#!/usr/bin/env bash
# Sends a notification with a dot in the state's colour as its image. The shell renders no colour
# in the title or body, so the dot is an SVG written to the user's runtime dir, one file per colour.
#
#   notify.sh COLOR omarchy-notification-send-args...    COLOR is #rrggbb or #aarrggbb
color=${1,,}
shift
[[ $color =~ ^#([0-9a-f]{2})?[0-9a-f]{6}$ ]] || exec omarchy-notification-send "$@"

# Qt writes alpha first (#aarrggbb); SVG wants it last.
if (( ${#color} == 9 )); then
  fill="#${color:3:6}" opacity=$(awk "BEGIN { printf \"%.3f\", $((16#${color:1:2})) / 255 }")
else
  fill=$color opacity=1
fi

dir=${XDG_RUNTIME_DIR:-/run/user/$UID}/exeque.omarchy-http-uptime
mkdir -p -m 700 "$dir"
image=$dir/dot-${color:1}.svg
[[ -f $image ]] || printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><circle cx="20" cy="20" r="9" fill="%s" fill-opacity="%s"/></svg>\n' \
  "$fill" "$opacity" > "$image"

exec omarchy-notification-send --image "$image" "$@"
