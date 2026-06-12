#!/bin/sh
printf '\033c\033]0;%s\a' EXTRACT
base_path="$(dirname "$(realpath "$0")")"
"$base_path/ExtractSteamLinux15.x86_64" "$@"
