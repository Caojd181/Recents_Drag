#!/bin/zsh
set -eu
cd "${0:A:h}"
.build/RecentsDragDemo.app/Contents/MacOS/RecentsDragDemo --stop
sleep 1
./run-demo.command
