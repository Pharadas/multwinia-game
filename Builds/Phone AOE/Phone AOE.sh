#!/bin/sh
printf '\033c\033]0;%s\a' Phone AOE
base_path="$(dirname "$(realpath "$0")")"
"$base_path/Phone AOE" "$@"
