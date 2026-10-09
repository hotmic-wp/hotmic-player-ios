#!/bin/sh
# Optional, ignored developer media. Always remove stale copies on rebuild.
set -eu
destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/LocalMedia"
rm -rf "$destination"
source_dir="${SRCROOT:?}/LocalMedia"
[ -d "$source_dir" ] || exit 0
for file in "$source_dir"/*; do
    [ -f "$file" ] || continue
    case "$file" in
        *.[mM][pP]4|*.jpg)
            mkdir -p "$destination"
            cp "$file" "$destination/"
            ;;
    esac
done
