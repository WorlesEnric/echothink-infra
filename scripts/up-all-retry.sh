#!/usr/bin/env bash
set -euo pipefail

max_retries=3000
attempt=1

while true; do
  echo "Running make up-all (attempt ${attempt}/${max_retries})..."
  if make up-all; then
    echo "make up-all succeeded."
    exit 0
  fi

  echo "make up-all failed with exit code $?."
  if (( attempt >= max_retries )); then
    echo "Giving up after ${max_retries} attempts." >&2
    exit 1
  fi

  attempt=$((attempt + 1))
  echo "Retrying in 1 seconds..."
  sleep 1
done