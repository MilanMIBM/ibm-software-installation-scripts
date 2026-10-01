#!/bin/zsh
find "$(dirname "$0")" -name "*.sh" -exec chmod +x {} +

# Prefer any podman already on PATH; otherwise look in common install locations.
if ! command -v podman >/dev/null 2>&1; then
  for _pd in /opt/podman/bin /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$_pd/podman" ]; then
      export PATH="$_pd:$PATH"
      break
    fi
  done
  unset _pd
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "podman not found on PATH or in standard install locations." >&2
  exit 1
fi

state=$(podman machine inspect --format '{{.State}}' 2>/dev/null)
echo "Podman machine state: ${state:-unknown}"

# Initialize a machine if none exists yet.
if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
  echo "No podman machine found; initializing..."
  podman machine init
fi

if [ "$state" != "running" ]; then
  podman machine start
fi
