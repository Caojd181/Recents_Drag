#!/bin/zsh
set -eu
cd "${0:A:h}"
if [[ ! -x .build/RecentsDragDemo.app/Contents/MacOS/RecentsDragDemo ]]; then
  /bin/zsh build.sh
fi
/usr/bin/open "$PWD/.build/RecentsDragDemo.app"
