#!/bin/sh
# Remove what is left of the ORIGINAL NOD-I software stack so it cannot fight
# NOD-I Revival: services, containers, images, stale bind mounts.
#
# Launched by scripts/init.sh on its first run; safe to run again at any time
# (every step checks before acting and does nothing when there is nothing left).
#
# What it NEVER does: partition, format or wipe the data SSD, delete anything
# under the SSD, touch the fan / LED / timezone services, or delete the old
# NOD-I data kept on the eMMC unless --purge-emmc-data is given AND confirmed.
#
# Observed on a NOD-I v1 (Debian 12, CM4) on 2026-11-23:
#   containers  rpx-reverse_proxy, min-*, btc-*, wlt-*   (images hub.nod-i.com/*)
#   units       nodi-nvme (re-mounts the SSD and bind-mounts /var/lib/docker and
#               /swap from it in a loop), nodi-mining, nodi-feargreed, nodi-stats,
#               nodi-screen (symlinks /etc/systemd/system/*.service -> /etc/nodi/services/)
set -eu

registry=${NODI_LEGACY_REGISTRY:-hub.nod-i.com/}
units=${NODI_LEGACY_UNITS:-"nodi-nvme nodi-mining nodi-feargreed nodi-stats nodi-screen"}
# Units that nothing may restart. nodi-screen is NOT masked: the Revival screen
# agent installs a unit with the same name.
mask_units=${NODI_LEGACY_MASK_UNITS:-"nodi-nvme nodi-mining nodi-feargreed nodi-stats"}
emmc_data=${NODI_LEGACY_EMMC_DATA:-/mnt/hdd}

dry_run=0
purge_emmc=0
assume_yes=0

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/cleanup-legacy-nodi.sh [options]

Options:
  --dry-run          Print what would be done, change nothing
  --purge-emmc-data  Also delete the old NOD-I data hidden on the eMMC under
                     /mnt/hdd (asks for confirmation). Never touches the SSD.
  --yes              Do not ask for confirmation
  -h, --help         Show this help

Environment overrides: NODI_LEGACY_REGISTRY, NODI_LEGACY_UNITS,
NODI_LEGACY_MASK_UNITS, NODI_LEGACY_EMMC_DATA.
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

run() {
  if [ "$dry_run" = 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

confirm() {
  [ "$assume_yes" = 1 ] && return 0
  [ -t 0 ] || die "$1 -- not interactive, re-run with --yes" 1
  printf '%s [y/N] ' "$1"
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) say "Skipped."; return 1 ;; esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --purge-emmc-data) purge_emmc=1; shift ;;
      --yes) assume_yes=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" 64 ;;
    esac
  done
}

# ── Services ────────────────────────────────────────────────────────────────

in_list() { # word list
  for item in $2; do [ "$item" = "$1" ] && return 0; done
  return 1
}

cleanup_units() {
  command -v systemctl >/dev/null 2>&1 || { warn "systemctl not found, units skipped"; return 0; }
  changed=0
  for unit in $units; do
    link="/etc/systemd/system/$unit.service"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      continue
    fi
    say "Legacy unit $unit: stop, disable, unlink"
    run systemctl stop "$unit.service" || true
    run systemctl disable "$unit.service" 2>/dev/null || true
    # Only the LINK goes: the target under /etc/nodi/services/ stays on disk.
    # A regular file is not ours (the Revival agent's own unit): left alone.
    if [ -L "$link" ]; then
      run rm -f "$link"
    fi
    changed=1
  done
  [ "$changed" = 1 ] && run systemctl daemon-reload
  for unit in $mask_units; do
    in_list "$unit" "$units" || continue
    state=$(systemctl is-enabled "$unit.service" 2>/dev/null || true)
    [ "$state" = masked ] && continue
    # `systemctl mask` fails while /etc/systemd/system/<unit>.service exists:
    # the link was removed above.
    run systemctl mask "$unit.service" || warn "could not mask $unit.service"
  done
}

# ── Containers, images, anonymous volumes ───────────────────────────────────

docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

cleanup_docker() {
  if ! docker_ready; then
    warn "Docker is not running: legacy containers and images skipped"
    return 0
  fi

  ids=$(docker ps -a --format '{{.ID}} {{.Image}}' | awk -v prefix="$registry" 'index($2, prefix) == 1 { print $1 }')
  for id in $ids; do
    say "Legacy container $id"
    run docker rm -f "$id"
  done

  images=$(docker images --format '{{.ID}} {{.Repository}}' | awk -v prefix="$registry" 'index($2, prefix) == 1 { print $1 }' | sort -u)
  for image in $images; do
    say "Legacy image $image"
    run docker rmi -f "$image"
  done

  # Only anonymous volumes (64 hex characters) that no container references.
  # Named volumes of a stopped stack (nodi_store-data...) look "dangling" too and
  # must never be swept.
  volumes=$(docker volume ls -q -f dangling=true | grep -E '^[0-9a-f]{64}$' || true)
  for volume in $volumes; do
    say "Anonymous volume ${volume%"${volume#????????????}"}..."
    run docker volume rm "$volume"
  done
}

# ── Bind mounts created by nodi-nvme ────────────────────────────────────────

# `findmnt` shows a bind mount as /dev/nvme0n1p1[/hdd/docker].
legacy_bind() { # target
  source=$(findmnt -n -o SOURCE "$1" 2>/dev/null || true)
  case "$source" in
    *"[/hdd/"*) return 0 ;;
  esac
  return 1
}

release_binds() {
  command -v findmnt >/dev/null 2>&1 || return 0
  docker_bind=0
  legacy_bind /var/lib/docker && docker_bind=1
  swap_bind=0
  legacy_bind /swap && swap_bind=1
  [ "$docker_bind" = 0 ] && [ "$swap_bind" = 0 ] && return 0

  if [ "$docker_bind" = 1 ]; then
    say "/var/lib/docker is a bind mount from the SSD: stopping Docker to release it"
    run systemctl stop docker.service docker.socket containerd.service || true
  fi
  if [ "$swap_bind" = 1 ]; then
    for file in $(swapon --noheadings --show=NAME 2>/dev/null | grep '^/swap/' || true); do
      say "swapoff $file"
      run swapoff "$file"
    done
    say "Releasing /swap"
    run umount /swap
  fi
  if [ "$docker_bind" = 1 ]; then
    run umount /var/lib/docker
    say "Restarting Docker on its default root (eMMC)"
    run systemctl start docker.service
  fi
  say "The SSD content under hdd/ is left untouched: inspect it before deleting anything."
}

# ── Old data hidden on the eMMC ─────────────────────────────────────────────

purge_emmc_data() {
  [ "$purge_emmc" = 1 ] || return 0
  target=$(findmnt -n -o TARGET -T "$emmc_data" 2>/dev/null || true)
  if [ "$target" = / ]; then
    # Directly on the root filesystem: nothing masks it.
    say "Old NOD-I data found on the eMMC at $emmc_data"
    [ -d "$emmc_data" ] || { say "No $emmc_data to purge."; return 0; }
    run du -sh "$emmc_data" || true
    confirm "Delete $emmc_data (old NOD-I data on the eMMC)?" || return 0
    run rm -rf "$emmc_data"
    return 0
  fi
  # A mount (the SSD on /mnt) hides what the eMMC holds under it. A bind mount of
  # / shows the eMMC as it really is.
  view=/run/nodi-root-view
  run mkdir -p "$view"
  run mount --bind / "$view"
  if [ "$dry_run" = 1 ]; then
    say "[dry-run] would inspect $view$emmc_data and delete it after confirmation"
    run umount "$view" || true
    return 0
  fi
  if [ -d "$view$emmc_data" ]; then
    say "Old NOD-I data hidden on the eMMC at $emmc_data:"
    du -sh "$view$emmc_data" || true
    if confirm "Delete it from the eMMC?"; then
      rm -rf "${view:?}$emmc_data"
    fi
  else
    say "Nothing hidden on the eMMC under $emmc_data."
  fi
  umount "$view"
  rmdir "$view" 2>/dev/null || true
}

report_remaining() {
  command -v systemctl >/dev/null 2>&1 || return 0
  remaining=$(systemctl list-unit-files 'nodi-*' --no-legend 2>/dev/null | awk '{ print $1 " (" $2 ")" }' || true)
  [ -n "$remaining" ] || return 0
  say "Remaining nodi-* units (not touched on purpose: fan, LED, timezone, system check):"
  printf '%s\n' "$remaining" | sed 's/^/  /'
}

main() {
  parse_args "$@"
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "root is required" 77
    exec sudo -E sh "$0" "$@"
  fi
  cleanup_units
  # Containers first: while a legacy bind mount is still in place, Docker still
  # sees the old containers and images stored on it.
  cleanup_docker
  release_binds
  purge_emmc_data
  report_remaining
  say "Legacy NOD-I cleanup done."
}

[ "${NODI_INIT_LIB:-}" = 1 ] || main "$@"
