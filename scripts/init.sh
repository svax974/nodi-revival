#!/bin/sh
# Initialise -- or re-adapt -- a NOD-I Revival box. Declarative and idempotent:
# the flags describe the WANTED state, running the script again with other flags
# moves the box to that state.
#
#   sudo ./scripts/init.sh                       # = --archive --miner --display
#   sudo ./scripts/init.sh --pruned              # pruned node, no miner, no screen
#   sudo ./scripts/init.sh --archive --display   # archive node + screen, no miner
#
# First run (no .nodi-init.state yet): runs scripts/cleanup-legacy-nodi.sh to clear
# the original NOD-I software before anything else.
#
# Storage (the data SSD is RESERVED for the Bitcoin datadir):
#   * the SSD partition must already be ext4 -- this script NEVER partitions or
#     formats (a disk formatted exFAT for Windows must be reformatted by hand:
#     mkfs.ext4 -L bitcoin-data /dev/nvme0n1p1);
#   * it is mounted by UUID through /etc/fstab (a stale line for the same mount
#     point is replaced, a backup of fstab is kept);
#   * the datadir is created on it, owned by UID 10001 (the container's bitcoin user);
#   * Docker (images, store and miner volumes) stays on the eMMC, not on the SSD.
set -eu
umask 022

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
self="$repo_dir/scripts/$(basename -- "$0")"
env_file="$repo_dir/.env"
state_file="$repo_dir/.nodi-init.state"

# ── Defaults ────────────────────────────────────────────────────────────────
MODE=""
WANT_MINER=0
WANT_DISPLAY=0
FEATURE_FLAGS=0
DEFAULTED=0
MINER_ADDRESS_ARG=""
PRUNE_MIB=100000
DBCACHE_MIB=450
DATA_DIR=/mnt/bitcoin
SSD_ARG=""
MOUNT_POINT=/mnt
DOCKER_ROOT=/var/lib/docker
HTTP_PORT=8080
SKIP_LEGACY=0
PURGE_LEGACY_DATA=0
RESET_CHAIN=0
DRY_RUN=0
ASSUME_YES=0
SSD_DEVICE=""
SSD_UUID=""

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/init.sh [mode and features] [options]

Mode and features (no flag at all = --archive --miner --display):
  --archive            Full archive node: prune=0, txindex=1
  --pruned             Pruned node: txindex=0, prune=<--prune-mib>
  --miner              Enable the lottery miner (needs --miner-address, or an
                       address already stored in .env)
  --display            Install and enable the built-in ST7789 screen agent
  With any of these flags, only the features named are enabled; the mode is
  archive unless --pruned is given.

Options:
  --miner-address ADDR   Bitcoin payout address for the miner
  --prune-mib N          Pruned node target in MiB (default 100000, minimum 550)
  --dbcache-mib N        Bitcoin Core dbcache in MiB (default 450)
  --ssd UUID|DEVICE      Data SSD partition (default: the partition labelled
                         "bitcoin-data", or the one saved by a previous run)
  --mount-point PATH     Where the SSD is mounted (default /mnt)
  --data-dir PATH        Bitcoin datadir, on the SSD (default /mnt/bitcoin)
  --docker-root PATH     Docker data root (default /var/lib/docker, on the eMMC)
  --http-port N          Cockpit port published on the host (default 8080)
  --skip-legacy          Do not run the legacy NOD-I cleanup on the first run
  --purge-legacy-data    Pass --purge-emmc-data to the legacy cleanup
  --reset-chain          Allow pruned -> archive by DELETING blocks, chainstate
                         and indexes (the whole chain is downloaded again)
  --dry-run              Print what would change, change nothing
  --yes                  Do not ask for confirmation
  -h, --help             Show this help

Re-running with different flags adapts the box. pruned -> archive needs
--reset-chain: Bitcoin Core cannot rebuild blocks it already deleted.
EOF
}

# ── Helpers ─────────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

# Every state-changing command goes through run(): --dry-run prints it instead.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

need_value() { # option remaining-argument-count
  [ "$2" -ge 2 ] || die "$1 requires a value" 64
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 0
  [ -t 0 ] || die "$1 -- not interactive, re-run with --yes" 1
  printf '%s [y/N] ' "$1"
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) die "Aborted." 1 ;; esac
}

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

safe_path() { # absolute, no exotic characters, not a broad system path
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9_./-]*) return 1 ;; esac
  case "$1" in
    /|/boot|/etc|/home|/mnt|/opt|/root|/srv|/usr|/var|/var/lib) return 1 ;;
  esac
  return 0
}

path_within() { # path directory
  case "$1/" in "$2"/*) return 0 ;; esac
  return 1
}

# ── Arguments ───────────────────────────────────────────────────────────────
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --archive)
        [ "$MODE" != pruned ] || die "--archive and --pruned are mutually exclusive" 64
        MODE=archive; FEATURE_FLAGS=1; shift ;;
      --pruned)
        [ "$MODE" != archive ] || die "--archive and --pruned are mutually exclusive" 64
        MODE=pruned; FEATURE_FLAGS=1; shift ;;
      --miner) WANT_MINER=1; FEATURE_FLAGS=1; shift ;;
      --display) WANT_DISPLAY=1; FEATURE_FLAGS=1; shift ;;
      --miner-address) need_value "$1" "$#"; MINER_ADDRESS_ARG=$2; shift 2 ;;
      --prune-mib) need_value "$1" "$#"; PRUNE_MIB=$2; shift 2 ;;
      --dbcache-mib) need_value "$1" "$#"; DBCACHE_MIB=$2; shift 2 ;;
      --ssd) need_value "$1" "$#"; SSD_ARG=$2; shift 2 ;;
      --mount-point) need_value "$1" "$#"; MOUNT_POINT=$2; shift 2 ;;
      --data-dir) need_value "$1" "$#"; DATA_DIR=$2; shift 2 ;;
      --docker-root) need_value "$1" "$#"; DOCKER_ROOT=$2; shift 2 ;;
      --http-port) need_value "$1" "$#"; HTTP_PORT=$2; shift 2 ;;
      --skip-legacy) SKIP_LEGACY=1; shift ;;
      --purge-legacy-data) PURGE_LEGACY_DATA=1; shift ;;
      --reset-chain) RESET_CHAIN=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" 64 ;;
    esac
  done
}

# No feature flag at all: --archive --miner --display. Any feature flag: only what
# was named is on, and the mode falls back to archive.
resolve_flags() {
  if [ "$FEATURE_FLAGS" = 0 ]; then
    MODE=archive
    WANT_MINER=1
    WANT_DISPLAY=1
    DEFAULTED=1
  else
    [ -n "$MODE" ] || MODE=archive
    DEFAULTED=0
  fi
}

validate_args() {
  is_number "$PRUNE_MIB" || die "--prune-mib must be numeric" 64
  [ "$PRUNE_MIB" -ge 550 ] || die "--prune-mib must be at least 550" 64
  is_number "$DBCACHE_MIB" || die "--dbcache-mib must be numeric" 64
  is_number "$HTTP_PORT" || die "--http-port must be numeric" 64
  [ "$HTTP_PORT" -ge 1 ] && [ "$HTTP_PORT" -le 65535 ] || die "--http-port out of range" 64
  safe_path "$DATA_DIR" || die "--data-dir must be an absolute, specific path (got: $DATA_DIR)" 64
  safe_path "$DOCKER_ROOT" || die "--docker-root must be an absolute, specific path (got: $DOCKER_ROOT)" 64
  case "$MOUNT_POINT" in
    /|/boot|/etc|/home|/opt|/root|/usr|/var) die "--mount-point refuses a system path: $MOUNT_POINT" 64 ;;
  esac
  case "$MOUNT_POINT" in /*) ;; *) die "--mount-point must be absolute" 64 ;; esac
  case "$MOUNT_POINT" in *[!A-Za-z0-9_./-]*) die "--mount-point contains unsupported characters" 64 ;; esac
  if [ -n "$SSD_ARG" ]; then
    case "$SSD_ARG" in
      /dev/*|[0-9a-fA-F]*-*-*-*-*) ;;
      *) die "--ssd takes a UUID or a /dev/... partition" 64 ;;
    esac
    case "$SSD_ARG" in *[!A-Za-z0-9_./-]*) die "--ssd contains unsupported characters" 64 ;; esac
  fi
  if [ -n "$MINER_ADDRESS_ARG" ]; then
    valid_miner_address "$MINER_ADDRESS_ARG" || die "Invalid Bitcoin mainnet payout address" 64
  fi
}

valid_miner_address() {
  case "$1" in bc1*|1*|3*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9]*) return 1 ;; esac
  return 0
}

# ── State (what the previous run left) ──────────────────────────────────────
state_get() { # key
  [ -f "$state_file" ] || return 0
  sed -n "s/^$1=//p" "$state_file" | tail -n 1
}

state_write() {
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  first=$(state_get FIRST_RUN_AT)
  [ -n "$first" ] || first=$now
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] would write $state_file"
    return 0
  fi
  tmp="$state_file.$$.tmp"
  {
    echo "MODE=$MODE"
    echo "MINER=$WANT_MINER"
    echo "DISPLAY=$WANT_DISPLAY"
    echo "DATA_DIR=$DATA_DIR"
    echo "MOUNT_POINT=$MOUNT_POINT"
    echo "SSD_UUID=$SSD_UUID"
    echo "DOCKER_ROOT=$DOCKER_ROOT"
    echo "HTTP_PORT=$HTTP_PORT"
    echo "FIRST_RUN_AT=$first"
    echo "LAST_RUN_AT=$now"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$state_file"
}

# The mode of the data on disk: the saved state, else what bitcoin.conf says (a box
# installed by hand before this script existed has no state file).
previous_mode() {
  saved=$(state_get MODE)
  if [ -n "$saved" ]; then
    echo "$saved"
    return 0
  fi
  conf="$DATA_DIR/bitcoin.conf"
  [ -r "$conf" ] || return 0
  value=$(sed -n 's/^prune=//p' "$conf" | tail -n 1)
  case "$value" in
    0) echo archive ;;
    ''|*[!0-9]*) ;;
    *) echo pruned ;;
  esac
}

print_plan() {
  say "Plan:"
  say "  mode          $MODE$([ "$MODE" = pruned ] && echo " (prune=${PRUNE_MIB} MiB)")"
  say "  miner         $([ "$WANT_MINER" = 1 ] && echo on || echo off)"
  say "  display       $([ "$WANT_DISPLAY" = 1 ] && echo on || echo off)"
  say "  datadir       $DATA_DIR  (SSD mounted on $MOUNT_POINT)"
  say "  docker root   $DOCKER_ROOT"
  say "  cockpit port  $HTTP_PORT"
  [ "$DEFAULTED" = 1 ] && say "  (no flag given: defaults --archive --miner --display)"
  return 0
}

print_changes() { # compares the saved state to the wanted one
  changed=0
  for pair in "MODE:$MODE" "MINER:$WANT_MINER" "DISPLAY:$WANT_DISPLAY" "DATA_DIR:$DATA_DIR" \
              "DOCKER_ROOT:$DOCKER_ROOT" "HTTP_PORT:$HTTP_PORT" "MOUNT_POINT:$MOUNT_POINT"; do
    key=${pair%%:*}
    want=${pair#*:}
    have=$(state_get "$key")
    if [ -n "$have" ] && [ "$have" != "$want" ]; then
      say "  change: $key $have -> $want"
      changed=1
    fi
  done
  [ "$changed" = 1 ]
}

# ── Preconditions ───────────────────────────────────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required$2" 69; }

check_prereqs() {
  case "$(uname -m)" in aarch64|arm64|x86_64|amd64) ;; *) die "Unsupported architecture: $(uname -m)" 69 ;; esac
  need_cmd docker " (install Docker Engine from your distribution packages first)"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (the 'docker compose' command)" 69
  for cmd in findmnt blkid mountpoint awk sed df cmp mktemp python3; do need_cmd "$cmd" ""; done
}

ensure_packages() { # package...
  missing=""
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
  done
  [ -n "$missing" ] || return 0
  command -v apt-get >/dev/null 2>&1 || die "Missing packages:$missing (apt-get not found, install them yourself)" 69
  say "Installing:$missing"
  run apt-get update -qq
  # shellcheck disable=SC2086
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
}

dc() { docker compose "$@"; }

# ── Storage: the SSD is reserved for the Bitcoin datadir ────────────────────
device_of() { # path -> block device, bind-mount suffix removed
  findmnt -n -o SOURCE -T "$1" 2>/dev/null | sed 's/\[.*//' | head -n 1
}

# Free KiB on the filesystem that holds (or WILL hold) a path: climbs to the first
# ancestor that exists, so it also works before the directory is created.
avail_kib() {
  probe=$1
  while [ ! -e "$probe" ] && [ "$probe" != / ]; do
    probe=$(dirname "$probe")
  done
  df -Pk "$probe" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# New fstab content: any line for the mount point is replaced by ours (a stale UUID
# left by an earlier attempt), comments are kept, nothing else moves.
fstab_render() { # file uuid mount-point
  awk -v uuid="$2" -v mp="$3" '
    BEGIN { done = 0 }
    /^[[:space:]]*#/ || NF == 0 { print; next }
    $2 == mp {
      if (!done) { printf "UUID=%s %s ext4 defaults,noatime 0 2\n", uuid, mp; done = 1 }
      next
    }
    { print }
    END { if (!done) printf "UUID=%s %s ext4 defaults,noatime 0 2\n", uuid, mp }
  ' "$1"
}

resolve_ssd() {
  want=$SSD_ARG
  [ -n "$want" ] || want=$(state_get SSD_UUID)
  if [ -z "$want" ]; then
    labelled=$(blkid -L bitcoin-data 2>/dev/null || true)
    [ -z "$labelled" ] || want=$labelled
  fi
  if [ -z "$want" ]; then
    # No SSD named: acceptable only when the datadir already lives on its own filesystem.
    target=$(findmnt -n -o TARGET -T "$(dirname "$DATA_DIR")" 2>/dev/null || true)
    if [ "$target" != / ] && [ -n "$target" ]; then
      say "Datadir parent already on its own filesystem ($target): no SSD mount to manage."
      return 0
    fi
    die "No data SSD found. Pass --ssd <UUID|/dev/partition>, or label an ext4 partition 'bitcoin-data' (e2label). This script never formats a disk."
  fi
  case "$want" in
    /dev/*)
      SSD_DEVICE=$want
      SSD_UUID=$(blkid -s UUID -o value "$SSD_DEVICE" 2>/dev/null || true)
      ;;
    *)
      SSD_UUID=$want
      SSD_DEVICE=$(blkid -U "$SSD_UUID" 2>/dev/null || true)
      ;;
  esac
  [ -b "$SSD_DEVICE" ] && [ -n "$SSD_UUID" ] || die "SSD not found ($want). An NVMe namespace can vanish after a warm reboot: power the box off completely for about 60 seconds, then retry."
  fstype=$(blkid -s TYPE -o value "$SSD_DEVICE" 2>/dev/null || true)
  [ "$fstype" = ext4 ] || die "$SSD_DEVICE is '$fstype', not ext4. This script never formats: reformat it yourself once (mkfs.ext4 -L bitcoin-data $SSD_DEVICE) after checking it holds nothing you need."
}

setup_ssd_mount() {
  [ -n "$SSD_DEVICE" ] || return 0
  path_within "$DATA_DIR" "$MOUNT_POINT" || die "--data-dir $DATA_DIR must be inside --mount-point $MOUNT_POINT"

  rendered=$(mktemp)
  fstab_render /etc/fstab "$SSD_UUID" "$MOUNT_POINT" > "$rendered"
  fstab_changed=0
  if ! cmp -s "$rendered" /etc/fstab; then
    fstab_changed=1
    say "fstab: UUID=$SSD_UUID on $MOUNT_POINT (backup kept)"
    if [ "$DRY_RUN" = 1 ]; then
      diff /etc/fstab "$rendered" || true
    else
      cp -p /etc/fstab "/etc/fstab.nodi-init.$(date +%Y%m%d%H%M%S)"
      cat "$rendered" > /etc/fstab
      systemctl daemon-reload
    fi
  fi
  rm -f "$rendered"

  if mountpoint -q "$MOUNT_POINT"; then
    mounted_dev=$(device_of "$MOUNT_POINT")
    [ "$mounted_dev" = "$SSD_DEVICE" ] || die "$MOUNT_POINT is mounted from $mounted_dev, not from $SSD_DEVICE. Unmount it first (an old NOD-I service may re-mount it: run scripts/cleanup-legacy-nodi.sh)."
    if [ "$fstab_changed" = 1 ]; then
      run mount -o remount "$MOUNT_POINT"
    fi
  else
    run mkdir -p "$MOUNT_POINT"
    run mount "$MOUNT_POINT"
  fi
  if [ "$DRY_RUN" = 0 ]; then
    mountpoint -q "$MOUNT_POINT" || die "$MOUNT_POINT is not mounted"
    [ "$(findmnt -n -o FSTYPE "$MOUNT_POINT")" = ext4 ] || die "$MOUNT_POINT is not ext4"
  fi
}

setup_datadir() {
  run mkdir -p "$DATA_DIR"
  # UID/GID of the unprivileged bitcoin user inside the image; the entrypoint then
  # takes ownership of the content once (marker .nodi-owner-10001).
  run chown 10001:10001 "$DATA_DIR"
  run chmod 0750 "$DATA_DIR"

  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi
  # Reserved SSD: tell what else lives on it, delete nothing.
  if [ "$DATA_DIR" != "$MOUNT_POINT" ]; then
    top=${DATA_DIR#"$MOUNT_POINT"/}
    top=${top%%/*}
    for entry in "$MOUNT_POINT"/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = "$top" ] && continue
      [ "$name" = lost+found ] && continue
      warn "SSD is not exclusively the Bitcoin datadir: $entry exists (left untouched)."
    done
  fi

  have=$(avail_kib "$DATA_DIR")
  if [ "$CHAIN_RESET_PENDING" = 0 ] && [ -d "$DATA_DIR/blocks" ] && [ -d "$DATA_DIR/chainstate" ]; then
    need_kib=$((20 * 1024 * 1024))
  elif [ "$MODE" = archive ]; then
    need_kib=$((800 * 1024 * 1024))
  else
    need_kib=$((PRUNE_MIB * 1024 + 15 * 1024 * 1024))
  fi
  if [ -n "$have" ] && [ "$have" -lt "$need_kib" ]; then
    die "Not enough free space on $DATA_DIR for a $MODE node ($((have / 1024 / 1024)) GiB free, $((need_kib / 1024 / 1024)) GiB needed)."
  fi
  if [ "$MODE" = archive ]; then
    say "Archive node: the chain plus txindex grows by roughly 9 GB a month, plan a larger SSD in time."
  fi
}

# Docker stays on the eMMC: the SSD holds the Bitcoin data and nothing else.
docker_root_now() { docker info --format '{{.DockerRootDir}}' 2>/dev/null; }

daemon_json_render() { # file root ('' removes the key)
  python3 - "$1" "$2" <<'PY'
import json, os, sys
path, root = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as handle:
        data = json.load(handle)
if root:
    data["data-root"] = root
else:
    data.pop("data-root", None)
print(json.dumps(data, indent=2, sort_keys=True))
PY
}

store_volume=nodi_store-data
STORE_BACKUP=""

# The store (votes, audit) is the one irreplaceable piece of data: Docker's named
# volume lives inside the Docker root, so it is saved before the root moves and
# restored after. Images are simply rebuilt, miner state is disposable.
backup_store_volume() {
  docker volume inspect "$store_volume" >/dev/null 2>&1 || return 0
  name="store-data-$(date +%Y%m%d%H%M%S).tar.gz"
  STORE_BACKUP="$repo_dir/backups/$name"
  say "Backing up the store volume to $STORE_BACKUP"
  run mkdir -p "$repo_dir/backups"
  run chmod 0700 "$repo_dir/backups"
  run docker run --rm --volume "$store_volume":/source:ro --volume "$repo_dir/backups":/backup \
    alpine:3.23.3 tar -czf "/backup/$name" -C /source .
}

restore_store_volume() {
  [ -n "$STORE_BACKUP" ] || return 0
  say "Restoring the store volume from $STORE_BACKUP"
  run docker volume create --label com.docker.compose.project=nodi \
    --label com.docker.compose.volume=store-data "$store_volume"
  run docker run --rm --volume "$store_volume":/target --volume "$repo_dir/backups":/backup:ro \
    alpine:3.23.3 sh -c "cd /target && tar -xzf /backup/$(basename "$STORE_BACKUP")"
}

setup_docker_root() {
  systemctl is-active --quiet docker || run systemctl start docker
  current=$(docker_root_now || true)
  if [ -z "$current" ]; then
    [ "$DRY_RUN" = 1 ] && return 0
    die "Cannot read Docker's root directory"
  fi

  if [ -n "$SSD_DEVICE" ] && [ "$(device_of "$DOCKER_ROOT")" = "$SSD_DEVICE" ]; then
    warn "Docker root $DOCKER_ROOT is on the SSD: it is no longer reserved for the Bitcoin data."
  fi

  if [ "$current" != "$DOCKER_ROOT" ]; then
    say "Docker root: $current -> $DOCKER_ROOT"
    run mkdir -p "$DOCKER_ROOT"
    backup_store_volume
    run systemctl stop docker.service docker.socket containerd.service
    json=$(mktemp)
    if [ "$DOCKER_ROOT" = /var/lib/docker ]; then
      daemon_json_render /etc/docker/daemon.json "" > "$json"
    else
      daemon_json_render /etc/docker/daemon.json "$DOCKER_ROOT" > "$json"
    fi
    if [ "$DRY_RUN" = 1 ]; then
      say "[dry-run] /etc/docker/daemon.json would become:"
      cat "$json"
    else
      mkdir -p /etc/docker
      cat "$json" > /etc/docker/daemon.json
      chmod 0644 /etc/docker/daemon.json
    fi
    rm -f "$json"
    run systemctl start docker.service
    if [ "$DRY_RUN" = 0 ]; then
      [ "$(docker_root_now)" = "$DOCKER_ROOT" ] || die "Docker did not come back on $DOCKER_ROOT"
    fi
    restore_store_volume
    say "Docker now runs on $DOCKER_ROOT. The old root $current is left in place: delete it yourself once everything works."
  fi

  # Free room for the builds (Node.js images and cpuminer are compiled on the box).
  if [ "$DRY_RUN" = 0 ]; then
    free_kib=$(avail_kib "$DOCKER_ROOT")
    is_number "${free_kib:-}" || die "Cannot read the free space under $DOCKER_ROOT"
    free_mib=$((free_kib / 1024))
    if [ "$free_mib" -lt 3072 ]; then
      die "Only ${free_mib} MiB free for Docker on $DOCKER_ROOT, at least 3072 are needed to build the images. Free some space (scripts/cleanup-legacy-nodi.sh --purge-emmc-data)."
    fi
  fi
}

check_swap() {
  [ -n "$SSD_DEVICE" ] || return 0
  total=$(swapon --noheadings --show=NAME 2>/dev/null | wc -l | tr -d ' ')
  if [ "$total" = 0 ]; then
    ram_mib=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
    [ "$ram_mib" -lt 6000 ] && warn "No swap and ${ram_mib} MiB of RAM: building the images may be killed for lack of memory."
    return 0
  fi
  for file in $(swapon --noheadings --show=NAME 2>/dev/null); do
    [ "$(device_of "$file")" = "$SSD_DEVICE" ] && warn "Swap $file is on the SSD, which is meant to hold only the Bitcoin data."
  done
  return 0
}

# ── Bitcoin configuration ───────────────────────────────────────────────────
set_env() { # key value
  [ "$DRY_RUN" = 1 ] && { say "[dry-run] .env: $1 updated"; return 0; }
  tmp="$env_file.$$.tmp"
  awk -v key="$1" -v value="$2" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$env_file" > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$env_file"
}

env_get() { # key (never printed by this script: used for comparisons only)
  [ -f "$env_file" ] || return 0
  sed -n "s/^$1=//p" "$env_file" | tail -n 1
}

# pruned -> archive cannot work in place: Bitcoin Core deleted blocks it would need.
# The decision is taken FIRST (before any mount or Docker change), the deletion LAST.
CHAIN_RESET_PENDING=0

check_mode_switch() {
  prev=$(previous_mode)
  [ -n "$prev" ] && [ "$prev" != "$MODE" ] || return 0
  if [ "$prev" = pruned ] && [ "$MODE" = archive ]; then
    [ "$RESET_CHAIN" = 1 ] || die "pruned -> archive is impossible in place (the old blocks are gone). Re-run with --reset-chain to DELETE blocks, chainstate and indexes in $DATA_DIR and download the whole chain again."
    CHAIN_RESET_PENDING=1
  fi
}

apply_mode_switch() {
  prev=$(previous_mode)
  [ -n "$prev" ] && [ "$prev" != "$MODE" ] || return 0
  if [ "$CHAIN_RESET_PENDING" = 1 ]; then
    confirm "DELETE blocks, chainstate and indexes in $DATA_DIR (full re-download)?"
    run dc stop bitcoin
    for sub in blocks chainstate indexes; do
      run rm -rf "${DATA_DIR:?}/$sub"
    done
  elif [ "$prev" = archive ] && [ "$MODE" = pruned ]; then
    # With txindex=0 Bitcoin Core keeps the old index on disk, unused.
    if [ -d "$DATA_DIR/indexes/txindex" ]; then
      say "archive -> pruned: removing the unused txindex ($DATA_DIR/indexes/txindex)"
      run dc stop bitcoin
      run rm -rf "${DATA_DIR:?}/indexes/txindex"
    fi
  fi
}

write_env() {
  [ -f "$env_file" ] || run "$repo_dir/scripts/bootstrap.sh"
  [ "$DRY_RUN" = 1 ] && [ ! -f "$env_file" ] && { say "[dry-run] .env would be created and filled"; return 0; }

  set_env NODI_HTTP_PORT "$HTTP_PORT"
  set_env BITCOIN_DATA_PATH "$DATA_DIR"
  set_env BITCOIN_DBCACHE_MIB "$DBCACHE_MIB"
  if [ "$MODE" = archive ]; then
    set_env BITCOIN_PRUNE_MIB 0
    set_env BITCOIN_TXINDEX 1
  else
    set_env BITCOIN_PRUNE_MIB "$PRUNE_MIB"
    set_env BITCOIN_TXINDEX 0
  fi

  # The miner starts only with an explicit address; an address already in .env is kept.
  address=$MINER_ADDRESS_ARG
  [ -n "$address" ] || address=$(env_get MINER_ADDRESS)
  if [ "$WANT_MINER" = 1 ] && [ -n "$address" ]; then
    set_env MINER_ADDRESS "$address"
    set_env MINER_ENABLED true
    MINER_ACTIVE=1
  else
    set_env MINER_ENABLED false
    MINER_ACTIVE=0
    if [ "$WANT_MINER" = 1 ]; then
      warn "Miner requested but no payout address known: it stays off. Re-run with --miner-address <addr>."
    fi
  fi
}

start_stack() {
  cd "$repo_dir"
  run dc config --quiet
  run dc up -d --build
  if [ "$MINER_ACTIVE" = 1 ]; then
    run dc --profile miner up -d --build --no-deps lottery-miner
  elif [ "$DRY_RUN" = 1 ] || [ -n "$(dc --profile miner ps -aq lottery-miner 2>/dev/null || true)" ]; then
    run dc --profile miner rm -sf lottery-miner
  fi
  if [ "$DRY_RUN" = 0 ]; then
    tries=0
    until dc exec -T control-ui wget -qO- http://127.0.0.1:8080/api/health >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ "$tries" -lt 60 ] || die "The cockpit did not answer in 5 minutes: docker compose logs --tail=100 api control-ui"
      sleep 5
    done
  fi
}

# ── Built-in screen (ST7789) ────────────────────────────────────────────────
screen_json_render() { # file base-file url
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
path, base, url = sys.argv[1], sys.argv[2], sys.argv[3]
source = path if os.path.exists(path) else base
with open(source) as handle:
    data = json.load(handle)
data["apiUrl"] = url
print(json.dumps(data, indent=2))
PY
}

setup_display() {
  agent_dir="$repo_dir/hardware/screen-agent"
  unit=/etc/systemd/system/nodi-screen.service
  if [ "$WANT_DISPLAY" = 0 ]; then
    if [ -f "$unit" ] && grep -q '/opt/nodi-screen' "$unit" 2>/dev/null; then
      say "Display off: disabling nodi-screen.service"
      run systemctl disable --now nodi-screen.service
    fi
    return 0
  fi
  if [ ! -e /dev/spidev0.0 ]; then
    warn "Display skipped: /dev/spidev0.0 is missing. Enable SPI (dtparam=spi=on in /boot/firmware/config.txt), reboot, run this script again."
    DISPLAY_SKIPPED=1
    return 0
  fi
  # pip compiles spidev and RPi.GPIO from source on aarch64.
  ensure_packages python3-venv python3-dev build-essential fonts-dejavu-core
  # The original NOD-I unit of the same name is a symlink into /etc/nodi/services/.
  if [ -L "$unit" ]; then
    say "Replacing the legacy nodi-screen.service link"
    run systemctl disable --now nodi-screen.service || true
    run rm -f "$unit"
  fi
  run sh "$agent_dir/install.sh"
  # The agent reads the cockpit through the published port.
  config=/etc/nodi/screen.json
  url="http://127.0.0.1:$HTTP_PORT/api/screen"
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] $config apiUrl would be $url"
    return 0
  fi
  json=$(mktemp)
  screen_json_render "$config" "$agent_dir/config.example.json" "$url" > "$json"
  if ! cmp -s "$json" "$config"; then
    cat "$json" > "$config"
    chmod 0644 "$config"
    systemctl restart nodi-screen.service
  fi
  rm -f "$json"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  MINER_ACTIVE=0
  DISPLAY_SKIPPED=0
  parse_args "$@"
  resolve_flags
  validate_args

  if [ "$WANT_MINER" = 1 ] && [ "$DEFAULTED" = 0 ] && [ -z "$MINER_ADDRESS_ARG" ]; then
    stored=$(env_get MINER_ADDRESS)
    [ -n "$stored" ] || die "--miner needs --miner-address <addr> (or an address already stored in .env)" 64
  fi

  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "root is required (mounts, fstab, Docker)" 77
    exec sudo -E sh "$self" "$@"
  fi

  first_run=0
  [ -f "$state_file" ] || first_run=1

  print_plan
  if [ "$first_run" = 1 ]; then
    if [ "$SKIP_LEGACY" = 0 ]; then
      say "First run: the original NOD-I stack will be removed (scripts/cleanup-legacy-nodi.sh)."
    fi
    confirm "Apply this plan?"
  elif print_changes; then
    confirm "Apply these changes?"
  fi

  check_prereqs
  check_mode_switch

  if [ "$first_run" = 1 ] && [ "$SKIP_LEGACY" = 0 ]; then
    legacy_args=""
    [ "$DRY_RUN" = 1 ] && legacy_args="$legacy_args --dry-run"
    [ "$PURGE_LEGACY_DATA" = 1 ] && legacy_args="$legacy_args --purge-emmc-data"
    [ "$ASSUME_YES" = 1 ] && legacy_args="$legacy_args --yes"
    # shellcheck disable=SC2086
    sh "$repo_dir/scripts/cleanup-legacy-nodi.sh" $legacy_args
  fi

  resolve_ssd
  setup_ssd_mount
  setup_datadir
  setup_docker_root
  check_swap

  cd "$repo_dir"
  apply_mode_switch
  write_env
  start_stack
  setup_display
  state_write

  say ""
  say "NOD-I Revival is configured: $MODE node, miner $([ "$MINER_ACTIVE" = 1 ] && echo on || echo off), display $([ "$WANT_DISPLAY" = 1 ] && [ "$DISPLAY_SKIPPED" = 0 ] && echo on || echo off)."
  say "Cockpit: http://<box address>:$HTTP_PORT (no authentication: LAN, VPN or an authenticating reverse proxy only)."
  say "Bitcoin P2P 8333 is published; the RPC 8332 stays on the private Docker network."
  say "Check: docker compose ps ; docker compose logs -f --tail=100 bitcoin"
}

[ "${NODI_INIT_LIB:-}" = 1 ] || main "$@"
