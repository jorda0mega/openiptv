#!/bin/zsh
# The tree an app is built from: its short commit, and " with changes" when files differ from it.
cd "$(dirname "$0")"
print -r -- "$(git rev-parse --short HEAD)$(git diff --quiet HEAD 2>/dev/null || echo ' with changes')"
