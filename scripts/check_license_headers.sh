#!/bin/sh
# Copyright 2026 Filippo Rossi
# SPDX-License-Identifier: Apache-2.0

set -eu

copyright="Copyright 2026 Filippo Rossi"
spdx="SPDX-License-Identifier: Apache-2.0"
fix=0

if [ "${1:-}" = "--fix" ]; then
    fix=1
elif [ "${1:-}" != "" ]; then
    echo "usage: $0 [--fix]" >&2
    exit 2
fi

list_files() {
    git ls-files
}

line_at() {
    sed -n "${1}p" "$2"
}

has_shebang() {
    [ "$(line_at 1 "$1" | cut -c1-2)" = "#!" ]
}

header_style() {
    case "$1" in
        LICENSE)
            echo skip
            ;;
        *.zig | *.zon)
            echo slash
            ;;
        *.yml | *.yaml | .gitignore | *.sh)
            echo hash
            ;;
        *.md)
            echo markdown
            ;;
        *)
            echo unknown
            ;;
    esac
}

has_header() {
    file="$1"
    style="$2"

    case "$style" in
        slash)
            [ "$(line_at 1 "$file")" = "// $copyright" ] &&
                [ "$(line_at 2 "$file")" = "// $spdx" ]
            ;;
        hash)
            if has_shebang "$file"; then
                [ "$(line_at 2 "$file")" = "# $copyright" ] &&
                    [ "$(line_at 3 "$file")" = "# $spdx" ]
            else
                [ "$(line_at 1 "$file")" = "# $copyright" ] &&
                    [ "$(line_at 2 "$file")" = "# $spdx" ]
            fi
            ;;
        markdown)
            [ "$(line_at 1 "$file")" = "<!--" ] &&
                [ "$(line_at 2 "$file")" = "$copyright" ] &&
                [ "$(line_at 3 "$file")" = "$spdx" ] &&
                [ "$(line_at 4 "$file")" = "-->" ]
            ;;
        *)
            return 1
            ;;
    esac
}

add_header() {
    file="$1"
    style="$2"
    tmp="${file}.license-tmp"

    case "$style" in
        slash)
            {
                printf "// %s\n// %s\n\n" "$copyright" "$spdx"
                cat "$file"
            } > "$tmp"
            ;;
        hash)
            if has_shebang "$file"; then
                {
                    line_at 1 "$file"
                    printf "# %s\n# %s\n\n" "$copyright" "$spdx"
                    sed "1d" "$file"
                } > "$tmp"
            else
                {
                    printf "# %s\n# %s\n\n" "$copyright" "$spdx"
                    cat "$file"
                } > "$tmp"
            fi
            ;;
        markdown)
            {
                printf "<!--\n%s\n%s\n-->\n\n" "$copyright" "$spdx"
                cat "$file"
            } > "$tmp"
            ;;
        *)
            echo "unsupported file type: $file" >&2
            return 1
            ;;
    esac

    mv "$tmp" "$file"
}

missing=0

for file in $(list_files); do
    style="$(header_style "$file")"
    if [ "$style" = skip ]; then
        continue
    fi
    if [ "$style" = unknown ]; then
        echo "unsupported file type: $file" >&2
        missing=1
        continue
    fi

    if has_header "$file" "$style"; then
        continue
    fi

    if [ "$fix" -eq 1 ]; then
        add_header "$file" "$style"
    else
        echo "missing license header: $file" >&2
        missing=1
    fi
done

exit "$missing"
