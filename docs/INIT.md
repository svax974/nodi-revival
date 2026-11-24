# Initialisation d'un boîtier : `scripts/init.sh`

Ce guide décrit les ajouts du fork `svax974/nodi-revival` au-dessus du projet
amont : un script d'initialisation **déclaratif et rejouable**, et un script de
ménage de l'ancien dispositif NOD-I. Le reste du dépôt suit l'amont.

## Utilisation

```bash
sudo ./scripts/init.sh [mode et fonctions] [options]
```

| Option | Effet |
| --- | --- |
| `--archive` | Nœud d'archive complet : `prune=0`, `txindex=1` |
| `--pruned` | Nœud pruned : `txindex=0`, `prune=<--prune-mib>` (100000 par défaut) |
| `--miner` | Active le mineur loterie ; exige `--miner-address` (ou une adresse déjà dans `.env`) |
| `--display` | Installe et active l'agent d'écran ST7789 intégré |

**Sans aucune de ces quatre options : `--archive --miner --display`.** Dès qu'une
option est donnée, seules les fonctions nommées sont actives, et le mode est
`archive` si `--pruned` n'est pas passé.

Autres options : `--miner-address`, `--prune-mib`, `--dbcache-mib` (450),
`--ssd UUID|/dev/…`, `--mount-point` (`/mnt`), `--data-dir` (`/mnt/bitcoin`),
`--docker-root` (`/var/lib/docker`), `--http-port` (8080), `--skip-legacy`,
`--purge-legacy-data`, `--reset-chain`, `--dry-run`, `--yes`.

Le mineur ne démarre jamais sans adresse de paiement. Par défaut (aucune option),
sans adresse connue, le script le signale et le laisse éteint.

## Rejouer le script

Les options décrivent l'**état voulu** : relancer avec d'autres options amène le
boîtier à cet état (mineur ou écran retirés, port changé, racine Docker déplacée…).
L'état précédent est lu dans `.nodi-init.state` (ignoré par Git) ; quand le plan
diffère, le script liste les changements et demande confirmation (`--yes` pour
passer). `--dry-run` affiche ce qui changerait sans rien modifier.

| Passage | Comportement |
| --- | --- |
| `archive` → `pruned` | Autorisé. Le `txindex` devenu inutile (`indexes/txindex`) est supprimé |
| `pruned` → `archive` | **Refusé** : Bitcoin Core ne reconstruit pas des blocs déjà supprimés. `--reset-chain` supprime `blocks`, `chainstate` et `indexes` (après confirmation) et retélécharge toute la chaîne |

## Stockage : le SSD est réservé aux données Bitcoin

- Le SSD doit **déjà être en ext4**. Le script ne partitionne ni ne formate
  jamais (limite du projet amont). Un disque en exFAT ou vfat est refusé avec la
  commande à lancer à la main : `mkfs.ext4 -L bitcoin-data /dev/nvme0n1p1`.
- Le SSD se désigne par `--ssd` (UUID ou `/dev/…`), sinon par l'étiquette
  `bitcoin-data`, sinon par l'UUID enregistré au passage précédent.
- Montage par UUID dans `/etc/fstab` (`defaults,noatime`). Une ligne périmée pour
  le même point de montage est remplacée ; une sauvegarde `/etc/fstab.nodi-init.*`
  est conservée.
- Le datadir (`--data-dir`, dans le point de montage) est créé avec le propriétaire
  `10001:10001` (l'utilisateur `bitcoin` de l'image) et le mode `0750`.
- **Docker reste sur l'eMMC** : images et volumes `store-data` / `miner-data` ne
  vont pas sur le SSD. Si la racine de Docker est ailleurs, le script la déplace
  vers `--docker-root`, après avoir **sauvegardé le volume `nodi_store-data`**
  (votes et audit du store, seule donnée irremplaçable) dans `backups/`, puis
  l'avoir restauré. Les images sont reconstruites. L'ancienne racine n'est pas
  supprimée.
- Le script avertit, sans rien supprimer, si le SSD porte autre chose que le
  datadir, si un fichier de swap s'y trouve, ou si Docker y est placé.
- Contrôles avant d'agir : place libre (nœud d'archive : 800 Gio, pruned :
  cible + 15 Gio), au moins 3 Gio libres pour construire les images.

Le nœud d'archive grossit d'environ 9 Go par mois (chaîne et `txindex`) : prévoir
un SSD plus grand à terme.

## Bitcoin Core

Le Dockerfile du fork fixe **Bitcoin Core 32.1** avec ses sommes SHA-256
officielles (<https://bitcoincore.org/bin/bitcoin-core-32.1/SHA256SUMS>). L'entrypoint
lit `BITCOIN_TXINDEX` (`0` ou `1`) et refuse `txindex=1` avec un nœud pruned.
`.env` reçoit `BITCOIN_DATA_PATH`, `BITCOIN_PRUNE_MIB`, `BITCOIN_TXINDEX`,
`BITCOIN_DBCACHE_MIB`, `NODI_HTTP_PORT` et l'état du mineur ; le secret RPC
généré à la première fois est conservé aux passages suivants.

## Nettoyage de l'ancien dispositif : `scripts/cleanup-legacy-nodi.sh`

Lancé automatiquement au **premier** passage de `init.sh` (pas d'état enregistré),
jamais ensuite ; relançable à la main, il ne fait rien quand il n'y a plus rien à
retirer. `init.sh --skip-legacy` l'évite.

- **Unités** `nodi-nvme`, `nodi-mining`, `nodi-feargreed`, `nodi-stats`,
  `nodi-screen` : arrêtées, désactivées, lien `/etc/systemd/system/*.service`
  retiré (la cible `/etc/nodi/services/` reste). Les quatre premières sont
  masquées ; `nodi-screen` ne l'est pas, car l'agent d'écran du projet reprend
  son nom. `nodi-nvme` remontait le SSD et ses liaisons (`/var/lib/docker`,
  `/swap`) en boucle.
- **Conteneurs et images** issus de `hub.nod-i.com/` ; volumes anonymes
  orphelins (64 caractères hexadécimaux) seulement — jamais un volume nommé.
- **Liaisons** `/var/lib/docker` et `/swap` montées depuis le SSD (`[/hdd/…]`) :
  Docker arrêté, swap désactivé, démontage, Docker relancé sur l'eMMC. Le contenu
  du SSD n'est jamais supprimé.
- `--purge-emmc-data` : supprime aussi les anciennes données NOD-I **cachées sur
  l'eMMC** sous `/mnt/hdd` par le montage du SSD (6,7 Go constatés), après
  confirmation. Utile : l'eMMC de 14 Go est le seul stockage de Docker.
- **Non touchés, volontairement** : `nodi-fan`, `nodi-rgb`, `nodi-timezone`,
  `nodi-check-system` (matériel ou sans effet sur la pile Docker). Le script les
  liste en fin d'exécution.

Surcharges : `NODI_LEGACY_REGISTRY`, `NODI_LEGACY_UNITS`,
`NODI_LEGACY_MASK_UNITS`, `NODI_LEGACY_EMMC_DATA`.

## Écran intégré

`--display` installe les paquets de compilation (`python3-venv`, `python3-dev`,
`build-essential`, `fonts-dejavu-core`), exécute `hardware/screen-agent/install.sh`
puis aligne `apiUrl` de `/etc/nodi/screen.json` sur `--http-port`. Sans
`/dev/spidev0.0`, l'écran est sauté avec un avertissement (activer
`dtparam=spi=on` dans `/boot/firmware/config.txt`, redémarrer, relancer). Sans
`--display` lors d'un passage suivant, `nodi-screen.service` est désactivé.

## Vérifications

```bash
sh scripts/test-init.sh      # 43 contrôles, sans root ni Docker (inclus dans npm run check)
sudo ./scripts/init.sh --dry-run --yes
```

Les tests couvrent la résolution des options, la réécriture de `fstab`, la
fusion de `daemon.json` et de `screen.json`, l'état, la détection du mode
précédent et les garde-fous de l'entrypoint. Le script a aussi été joué dans un
conteneur Debian arm64 avec un vrai périphérique loop ext4 (montage, `fstab`,
datadir, refus d'un disque vfat sans le formater, bascule de racine Docker) et un
`docker` factice.

**Non validé sur un boîtier réel** : le build des images, le démarrage de
`bitcoind`, l'agent d'écran sur le ST7789 et le nettoyage avec les vrais
conteneurs `hub.nod-i.com`.
