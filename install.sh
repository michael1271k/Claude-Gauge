#!/bin/zsh
# Builds and installs the Claude Gauge Mac app into ~/Applications and opens it.
# The in-chat usage bar is a Claude Code plugin; install it from Claude Code (see README).
set -euo pipefail
cd "${0:A:h}"
if ! command -v swiftc >/dev/null; then
  echo "Swift is missing. Install the Xcode Command Line Tools first:  xcode-select --install"
  exit 1
fi
mkdir -p ~/.claude/gauge/sessions
./app/build.sh
echo "Claude Gauge is installed in ~/Applications and running in your menu bar."
