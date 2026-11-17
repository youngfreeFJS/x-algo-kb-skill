#!/usr/bin/env bash
# Fetch xai-org/x-algorithm at the commit this knowledge base cites.
# Usage: bash fetch-source.sh [target-dir]
# Default target: /tmp/x-algorithm

set -euo pipefail

REPO_URL="https://github.com/xai-org/x-algorithm.git"
PINNED_SHA="a284320b66a9dce35e6f5d6b052ee308eeb12326"
TARGET="${1:-/tmp/x-algorithm}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git not found on PATH"

if [ -d "$TARGET/.git" ]; then
  HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ "$HEAD_SHA" = "$PINNED_SHA" ]; then
    say "OK: already at pinned commit"
    say "path: $TARGET"
    say "commit: $PINNED_SHA"
    exit 0
  fi
  # Existing checkout at a different commit: fetch and detach, never discard work.
  if [ -n "$(git -C "$TARGET" status --porcelain 2>/dev/null)" ]; then
    die "$TARGET has uncommitted changes; commit or move them aside, then re-run"
  fi
  say "existing checkout at $HEAD_SHA, fetching pinned commit..."
  git -C "$TARGET" fetch --quiet origin "$PINNED_SHA" 2>/dev/null \
    || git -C "$TARGET" fetch --quiet origin \
    || die "fetch failed (network or auth)"
  git -C "$TARGET" checkout --quiet --detach "$PINNED_SHA" \
    || die "checkout of $PINNED_SHA failed"
else
  say "cloning into $TARGET ..."
  git clone --quiet "$REPO_URL" "$TARGET" || die "clone failed (network or auth)"
  git -C "$TARGET" checkout --quiet --detach "$PINNED_SHA" \
    || die "checkout of $PINNED_SHA failed"
fi

HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD)"
[ "$HEAD_SHA" = "$PINNED_SHA" ] || die "expected $PINNED_SHA but got $HEAD_SHA"

say "OK: source ready at pinned commit"
say "path: $TARGET"
say "commit: $PINNED_SHA"
say ""
say "Citations in this KB are relative to that path, e.g."
say "  home-mixer/params/param.rs:451  ->  $TARGET/home-mixer/params/param.rs line 451"