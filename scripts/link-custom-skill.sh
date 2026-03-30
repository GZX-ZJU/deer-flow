#!/usr/bin/env sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <skill-folder-name>" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SKILL_NAME=$1
SOURCE_DIR=$HOME/.agents/skills/$SKILL_NAME
TARGET_DIR=$PROJECT_ROOT/skills/custom/$SKILL_NAME

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source skill directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if [ -L "$TARGET_DIR" ]; then
  CURRENT_TARGET=$(readlink "$TARGET_DIR" || true)
  if [ "$CURRENT_TARGET" = "$SOURCE_DIR" ]; then
    echo "Link already exists: $TARGET_DIR -> $SOURCE_DIR"
    exit 0
  fi

  echo "Target already exists as a different symlink: $TARGET_DIR -> $CURRENT_TARGET" >&2
  exit 1
fi

if [ -e "$TARGET_DIR" ]; then
  echo "Target already exists and is not a symlink: $TARGET_DIR" >&2
  exit 1
fi

ln -s "$SOURCE_DIR" "$TARGET_DIR"
echo "Linked: $TARGET_DIR -> $SOURCE_DIR"
