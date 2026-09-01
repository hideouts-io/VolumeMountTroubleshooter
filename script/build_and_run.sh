#!/bin/zsh

set -euo pipefail

mode="${1:-run}"
app_name="VolumeMountTroubleshooter"
bundle_id="io.hideouts.VolumeMountTroubleshooter"
project_dir="${0:A:h:h}"
app_bundle="$project_dir/build/Volume Mount Troubleshooter.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"

/usr/bin/pkill -x "$app_name" >/dev/null 2>&1 || true
"$project_dir/build.sh"

launch_app() {
    /usr/bin/open -n "$app_bundle"
}

case "$mode" in
    run)
        launch_app
        ;;
    --debug|debug)
        /usr/bin/lldb -- "$app_binary"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
        ;;
    --verify|verify)
        launch_app
        /bin/sleep 1
        /usr/bin/pgrep -x "$app_name" >/dev/null
        ;;
    *)
        print -u2 "usage: $0 [run|--debug|--logs|--telemetry|--verify]"
        exit 2
        ;;
esac
