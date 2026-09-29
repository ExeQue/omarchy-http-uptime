#!/usr/bin/env bash
# Usage: rename.sh OLD_URL NEW_URL
# Moves OLD_URL's history to NEW_URL when an entry's URL is edited. If a check already wrote to
# NEW_URL's file, the two are merged in time order. The file is touched so check.sh's orphan
# cleanup (which only removes files untouched for 10 minutes) leaves it alone.
source "$(dirname "$0")/history.sh"
old=$(history_file "$1") new=$(history_file "$2")
[[ -f $old && ! -L $old && ! -L $new ]] || exit 0
if [[ -f $new ]]; then
  merged=$(make_temp) && sort -n "$old" "$new" > "$merged" && mv -- "$merged" "$new" && rm -f -- "$old"
else
  mv -- "$old" "$new"
fi
touch -- "$new"
