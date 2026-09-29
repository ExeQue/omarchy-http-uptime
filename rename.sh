#!/usr/bin/env bash
# Usage: rename.sh OLD_URL NEW_URL
# Moves OLD_URL's history to NEW_URL when an entry's URL is edited. If a check already wrote to
# NEW_URL's file, the two are merged in time order. The file is touched so check.sh's orphan
# cleanup (which only removes files untouched for 10 minutes) leaves it alone.
source "$(dirname "$0")/history.sh"
enter_history_dir || exit 1
old=$(history_file "$1") new=$(history_file "$2")
[[ -f $old && ! -L $old ]] || exit 0
# Reads use O_NOFOLLOW; mv -T renames over whatever is at $new (a symlink is replaced, not followed).
make_temp merged || exit 1
{ read_nofollow "$old"; read_nofollow "$new" 2>/dev/null; } | sort -n > "$merged" || exit 1
mv -T -- "$merged" "$new" && rm -f -- "$old"
touch -h -- "$new"
