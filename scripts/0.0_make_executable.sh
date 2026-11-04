#!/bin/zsh
# chmod every .sh in the repo (scripts/ and src/), not just this folder.
find "$(cd "$(dirname "$0")/.." && pwd)" -name "*.sh" -not -path "*/.venv/*" -exec chmod +x {} +

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
elif ! podman info >/dev/null 2>&1; then
  # The VM can report "running" while its API socket is dead (seen after a
  # host sleep: ssh port refuses, podman create fails with "failed to decode
  # message from stream: unexpected EOF"). Bounce it instead of failing later.
  echo "Podman machine reports running but its API is unreachable; restarting it..."
  podman machine stop >/dev/null 2>&1 || true
  podman machine start
fi

if ! podman info >/dev/null 2>&1; then
  echo "Podman API still unreachable after start; check 'podman machine list' / 'podman system connection list'." >&2
  exit 1
fi
