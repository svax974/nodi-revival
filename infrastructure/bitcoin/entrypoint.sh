#!/bin/sh
set -eu

: "${BITCOIN_RPC_USER:=nodi}"
: "${BITCOIN_RPC_PASSWORD:?BITCOIN_RPC_PASSWORD is required}"
: "${BITCOIN_PRUNE_MIB:=100000}"
: "${BITCOIN_DBCACHE_MIB:=450}"
: "${BITCOIN_TXINDEX:=0}"

case "$BITCOIN_PRUNE_MIB" in *[!0-9]*|'') echo "BITCOIN_PRUNE_MIB must be numeric" >&2; exit 64 ;; esac
case "$BITCOIN_DBCACHE_MIB" in *[!0-9]*|'') echo "BITCOIN_DBCACHE_MIB must be numeric" >&2; exit 64 ;; esac
case "$BITCOIN_TXINDEX" in 0|1) ;; *) echo "BITCOIN_TXINDEX must be 0 or 1" >&2; exit 64 ;; esac
if [ "$BITCOIN_TXINDEX" = 1 ] && [ "$BITCOIN_PRUNE_MIB" != 0 ]; then
  echo "BITCOIN_TXINDEX=1 needs BITCOIN_PRUNE_MIB=0 (a pruned node cannot keep a full index)" >&2
  exit 64
fi
case "$BITCOIN_RPC_USER" in *[!A-Za-z0-9._-]*|'') echo "BITCOIN_RPC_USER contains unsupported characters" >&2; exit 64 ;; esac
case "$BITCOIN_RPC_PASSWORD" in *[!A-Za-z0-9]*|'') echo "BITCOIN_RPC_PASSWORD must be a non-empty alphanumeric secret" >&2; exit 64 ;; esac

owner_marker=/data/.nodi-owner-10001
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p /data
  if [ ! -e "$owner_marker" ]; then
    echo "Preparing Bitcoin data ownership; this one-time step can take a while."
    chown -R bitcoin:bitcoin /data
  fi
  exec gosu bitcoin "$0" "$@"
fi

touch "$owner_marker"
cat > /data/bitcoin.conf <<EOF
server=1
listen=1
rpcbind=0.0.0.0
rpcallowip=172.16.0.0/12
rpcuser=$BITCOIN_RPC_USER
rpcpassword=$BITCOIN_RPC_PASSWORD
prune=$BITCOIN_PRUNE_MIB
txindex=$BITCOIN_TXINDEX
dbcache=$BITCOIN_DBCACHE_MIB
disablewallet=1
EOF
chmod 0600 /data/bitcoin.conf

exec bitcoind \
  -datadir=/data \
  -printtoconsole=1
