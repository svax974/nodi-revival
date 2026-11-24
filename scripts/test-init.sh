#!/bin/sh
# Tests of the pure parts of scripts/init.sh, scripts/cleanup-legacy-nodi.sh and
# the Bitcoin entrypoint guards. No root, no Docker, no disk: every test runs in a
# subshell against temporary files.
#
#   sh scripts/test-init.sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname "$here")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

NODI_INIT_LIB=1
export NODI_INIT_LIB
# shellcheck disable=SC1091
. "$here/init.sh"

total=0
failed=0

# check "description" function... : passes when the function succeeds in a subshell.
check() {
  description=$1
  shift
  total=$((total + 1))
  if ( "$@" ) >/dev/null 2>&1; then
    return 0
  fi
  printf 'FAIL: %s\n' "$description"
  failed=$((failed + 1))
}

# refuse "description" function... : passes when the function FAILS.
refuse() {
  description=$1
  shift
  total=$((total + 1))
  if ( "$@" ) >/dev/null 2>&1; then
    printf 'FAIL (should have been refused): %s\n' "$description"
    failed=$((failed + 1))
  fi
}

# ── Flags ───────────────────────────────────────────────────────────────────
t_defaults() {
  parse_args
  resolve_flags
  [ "$MODE" = archive ] && [ "$WANT_MINER" = 1 ] && [ "$WANT_DISPLAY" = 1 ] && [ "$DEFAULTED" = 1 ]
}
t_pruned_only() {
  parse_args --pruned
  resolve_flags
  [ "$MODE" = pruned ] && [ "$WANT_MINER" = 0 ] && [ "$WANT_DISPLAY" = 0 ] && [ "$DEFAULTED" = 0 ]
}
t_miner_only_defaults_to_archive() {
  parse_args --miner
  resolve_flags
  [ "$MODE" = archive ] && [ "$WANT_MINER" = 1 ] && [ "$WANT_DISPLAY" = 0 ]
}
t_display_pruned() {
  parse_args --display --pruned
  resolve_flags
  [ "$MODE" = pruned ] && [ "$WANT_MINER" = 0 ] && [ "$WANT_DISPLAY" = 1 ]
}
t_archive_miner_display_explicit() {
  parse_args --archive --miner --display
  resolve_flags
  [ "$MODE" = archive ] && [ "$WANT_MINER" = 1 ] && [ "$WANT_DISPLAY" = 1 ] && [ "$DEFAULTED" = 0 ]
}
t_both_modes() { parse_args --archive --pruned; }
t_both_modes_reversed() { parse_args --pruned --archive; }
t_unknown_flag() { parse_args --bogus; }
t_missing_value() { parse_args --prune-mib; }
t_valid_defaults() { parse_args; resolve_flags; validate_args; }
t_prune_too_small() { parse_args --pruned --prune-mib 100; resolve_flags; validate_args; }
t_prune_not_numeric() { parse_args --prune-mib abc; resolve_flags; validate_args; }
t_port_range() { parse_args --http-port 70000; resolve_flags; validate_args; }
t_datadir_relative() { parse_args --data-dir data; resolve_flags; validate_args; }
t_datadir_system() { parse_args --data-dir /etc; resolve_flags; validate_args; }
t_datadir_weird() { parse_args --data-dir '/mnt/a b'; resolve_flags; validate_args; }
t_ssd_junk() { parse_args --ssd junk; resolve_flags; validate_args; }
t_ssd_uuid() { parse_args --ssd 7f2e4359-ba1d-44c6-984d-0f396c8905f0; resolve_flags; validate_args; }
t_ssd_device() { parse_args --ssd /dev/nvme0n1p1; resolve_flags; validate_args; }
t_address_bad() { parse_args --miner --miner-address 'notanaddress'; resolve_flags; validate_args; }
t_address_ok() { parse_args --miner --miner-address bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq; resolve_flags; validate_args; }

check "no flag = archive + miner + display" t_defaults
check "--pruned alone: no miner, no display" t_pruned_only
check "--miner alone: archive mode, miner only" t_miner_only_defaults_to_archive
check "--display --pruned" t_display_pruned
check "explicit --archive --miner --display" t_archive_miner_display_explicit
refuse "--archive --pruned" t_both_modes
refuse "--pruned --archive" t_both_modes_reversed
refuse "unknown flag" t_unknown_flag
refuse "option without value" t_missing_value
check "default values validate" t_valid_defaults
refuse "--prune-mib below 550" t_prune_too_small
refuse "--prune-mib not numeric" t_prune_not_numeric
refuse "--http-port out of range" t_port_range
refuse "relative --data-dir" t_datadir_relative
refuse "--data-dir /etc" t_datadir_system
refuse "--data-dir with a space" t_datadir_weird
refuse "--ssd garbage" t_ssd_junk
check "--ssd UUID" t_ssd_uuid
check "--ssd device" t_ssd_device
refuse "bad payout address" t_address_bad
check "bech32 payout address" t_address_ok

# ── Paths ───────────────────────────────────────────────────────────────────
t_within_yes() { path_within /mnt/bitcoin /mnt; }
t_within_no() { path_within /srv/bitcoin /mnt; }
t_within_sibling() { path_within /mntx/bitcoin /mnt; }
check "datadir inside the mount point" t_within_yes
refuse "datadir outside the mount point" t_within_no
refuse "sibling directory with the same prefix" t_within_sibling

# ── fstab ───────────────────────────────────────────────────────────────────
uuid=7f2e4359-ba1d-44c6-984d-0f396c8905f0
cat > "$work/fstab" <<'EOF'
# a comment
proc            /proc           proc    defaults          0       0
PARTUUID=81c7a41e-01  /boot/firmware  vfat    defaults          0       2
PARTUUID=81c7a41e-02  /               ext4    defaults,noatime  0       1
UUID=a2018aa5-44ea-4dcd-afbb-8f3e320def15 /mnt ext4 defaults,noatime 0 2
UUID=1111 /mnt/other ext4 defaults 0 2
EOF

t_fstab_replaces_stale() {
  out=$(fstab_render "$work/fstab" "$uuid" /mnt)
  [ "$(printf '%s\n' "$out" | awk '$2 == "/mnt"' | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s\n' "$out" | grep -q "^UUID=$uuid /mnt ext4 defaults,noatime 0 2$" || return 1
  printf '%s\n' "$out" | grep -q 'a2018aa5' && return 1
  printf '%s\n' "$out" | grep -q '^# a comment$' || return 1
  printf '%s\n' "$out" | grep -q '/boot/firmware' || return 1
  printf '%s\n' "$out" | grep -q '^UUID=1111 /mnt/other ' || return 1
  return 0
}
t_fstab_idempotent() {
  fstab_render "$work/fstab" "$uuid" /mnt > "$work/fstab.1"
  fstab_render "$work/fstab.1" "$uuid" /mnt > "$work/fstab.2"
  cmp -s "$work/fstab.1" "$work/fstab.2"
}
t_fstab_appends() {
  printf 'proc /proc proc defaults 0 0\n' > "$work/fstab.min"
  out=$(fstab_render "$work/fstab.min" "$uuid" /mnt)
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "UUID=$uuid /mnt ext4 defaults,noatime 0 2" ]
}
check "fstab: stale line for the mount point is replaced, the rest kept" t_fstab_replaces_stale
check "fstab: rendering twice changes nothing" t_fstab_idempotent
check "fstab: line appended when absent" t_fstab_appends

# ── Docker daemon.json and screen config ────────────────────────────────────
t_daemon_adds_root() {
  printf '{"log-driver": "journald"}\n' > "$work/daemon.json"
  out=$(daemon_json_render "$work/daemon.json" /srv/docker)
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d == {"log-driver": "journald", "data-root": "/srv/docker"}, d'
}
t_daemon_drops_root() {
  printf '{"data-root": "/mnt/docker", "log-driver": "journald"}\n' > "$work/daemon.json"
  out=$(daemon_json_render "$work/daemon.json" "")
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d == {"log-driver": "journald"}, d'
}
t_daemon_no_file() {
  out=$(daemon_json_render "$work/absent.json" /srv/docker)
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d == {"data-root": "/srv/docker"}, d'
}
t_screen_keeps_pins() {
  cp "$repo/hardware/screen-agent/config.example.json" "$work/screen.json"
  out=$(screen_json_render "$work/screen.json" "$repo/hardware/screen-agent/config.example.json" http://127.0.0.1:9090/api/screen)
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["apiUrl"] == "http://127.0.0.1:9090/api/screen" and d["dcPin"] == 23 and d["width"] == 320, d'
}
check "daemon.json: data-root added, other keys kept" t_daemon_adds_root
check "daemon.json: data-root removed for the default root" t_daemon_drops_root
check "daemon.json: created when absent" t_daemon_no_file
check "screen.json: apiUrl updated, pins kept" t_screen_keeps_pins

# ── State and previous mode ─────────────────────────────────────────────────
t_state_roundtrip() {
  state_file="$work/state"
  DRY_RUN=0 MODE=pruned WANT_MINER=0 WANT_DISPLAY=1 DATA_DIR=/mnt/bitcoin MOUNT_POINT=/mnt SSD_UUID=$uuid DOCKER_ROOT=/var/lib/docker HTTP_PORT=8080
  state_write
  [ "$(state_get MODE)" = pruned ] && [ "$(state_get DISPLAY)" = 1 ] && [ "$(state_get SSD_UUID)" = "$uuid" ] || return 1
  first=$(state_get FIRST_RUN_AT)
  [ -n "$first" ] || return 1
  sleep 1
  MODE=archive
  state_write
  [ "$(state_get MODE)" = archive ] && [ "$(state_get FIRST_RUN_AT)" = "$first" ]
}
t_state_mode_0600() {
  state_file="$work/state2"
  DRY_RUN=0 MODE=archive WANT_MINER=1 WANT_DISPLAY=1 DATA_DIR=/mnt/bitcoin MOUNT_POINT=/mnt SSD_UUID=$uuid DOCKER_ROOT=/var/lib/docker HTTP_PORT=8080
  state_write
  [ "$(ls -l "$state_file" | cut -c1-10)" = "-rw-------" ]
}
t_prev_from_conf_archive() {
  state_file="$work/none"
  DATA_DIR="$work/dd1"
  mkdir -p "$DATA_DIR"
  printf 'server=1\nprune=0\ntxindex=1\n' > "$DATA_DIR/bitcoin.conf"
  [ "$(previous_mode)" = archive ]
}
t_prev_from_conf_pruned() {
  state_file="$work/none"
  DATA_DIR="$work/dd2"
  mkdir -p "$DATA_DIR"
  printf 'server=1\nprune=100000\ntxindex=0\n' > "$DATA_DIR/bitcoin.conf"
  [ "$(previous_mode)" = pruned ]
}
t_prev_unknown() {
  state_file="$work/none"
  DATA_DIR="$work/dd3"
  [ -z "$(previous_mode)" ]
}
check "state: round trip keeps the first run date" t_state_roundtrip
check "state: file is 0600" t_state_mode_0600
check "previous mode read from bitcoin.conf (archive)" t_prev_from_conf_archive
check "previous mode read from bitcoin.conf (pruned)" t_prev_from_conf_pruned
check "previous mode unknown without state nor conf" t_prev_unknown

# ── Bitcoin entrypoint guards (they fire before anything touches /data) ─────
entry="$repo/infrastructure/bitcoin/entrypoint.sh"
t_entry_txindex_with_prune() {
  out=$(BITCOIN_RPC_PASSWORD=abc BITCOIN_PRUNE_MIB=100000 BITCOIN_TXINDEX=1 sh "$entry" 2>&1) && return 1
  printf '%s' "$out" | grep -q 'needs BITCOIN_PRUNE_MIB=0'
}
t_entry_bad_txindex() {
  out=$(BITCOIN_RPC_PASSWORD=abc BITCOIN_PRUNE_MIB=0 BITCOIN_TXINDEX=2 sh "$entry" 2>&1) && return 1
  printf '%s' "$out" | grep -q 'BITCOIN_TXINDEX must be 0 or 1'
}
t_entry_writes_variable() {
  grep -q '^txindex=\$BITCOIN_TXINDEX$' "$entry" && ! grep -q '^txindex=0$' "$entry"
}
check "entrypoint refuses txindex with pruning" t_entry_txindex_with_prune
check "entrypoint refuses a txindex that is not 0 or 1" t_entry_bad_txindex
check "entrypoint writes txindex from the variable" t_entry_writes_variable

# ── Dockerfile pins ─────────────────────────────────────────────────────────
t_dockerfile_pins() {
  file="$repo/infrastructure/bitcoin/Dockerfile"
  grep -q '^ARG BITCOIN_VERSION=32.1$' "$file" &&
    grep -q '^ARG BITCOIN_SHA_ARM64=7ed37c7373eb6aa3e3f72842596a1afeba1b223717033cade9842b25773e1922$' "$file" &&
    grep -q '^ARG BITCOIN_SHA_AMD64=61545c17c3120fb7412f896d248b11993af04ec8817aad3649c55b2afb044963$' "$file"
}
check "Dockerfile pins Bitcoin Core 32.1 with its published sums" t_dockerfile_pins

# ── Legacy cleanup helpers ──────────────────────────────────────────────────
t_in_list() (
  # shellcheck disable=SC1091
  . "$here/cleanup-legacy-nodi.sh"
  in_list nodi-nvme "nodi-nvme nodi-mining" && ! in_list nodi-fan "nodi-nvme nodi-mining" && ! in_list nodi "nodi-nvme"
)
t_cleanup_parse() (
  # shellcheck disable=SC1091
  . "$here/cleanup-legacy-nodi.sh"
  parse_args --dry-run --purge-emmc-data --yes
  [ "$dry_run" = 1 ] && [ "$purge_emmc" = 1 ] && [ "$assume_yes" = 1 ]
)
t_cleanup_unknown() (
  # shellcheck disable=SC1091
  . "$here/cleanup-legacy-nodi.sh"
  parse_args --nope
)
check "cleanup: unit list matching is exact" t_in_list
check "cleanup: flags" t_cleanup_parse
refuse "cleanup: unknown flag" t_cleanup_unknown

printf '%s checks, %s failed\n' "$total" "$failed"
[ "$failed" = 0 ]
