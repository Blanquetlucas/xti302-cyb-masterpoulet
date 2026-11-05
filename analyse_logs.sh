#!/bin/bash
# analyse_logs.sh - rapport sur les connexions SSH (J4)
#
# Lancé en root via sudo par le compte support : les arguments sont donc
# vérifiés strictement et aucun pager n'est utilisé (less permet d'ouvrir un
# shell, ce qui donnerait un shell root).
#
# Codes de sortie :
#   0  rapport produit, aucun seuil dépassé
#   1  erreur d'usage ou d'exécution
#   2  alerte : une IP a atteint le seuil d'échecs

set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PAGER=cat SYSTEMD_PAGER=cat SYSTEMD_LESS=""
unset LESSOPEN LESSCLOSE

# 10 échecs : fail2ban bannit à 5 sur 10 min, donc une IP qui en cumule 10
# est revenue après un bannissement, ou attaque lentement sous le seuil
# de fail2ban.
SEUIL=10
DEPUIS="24 hours ago"

usage() {
    cat >&2 <<EOF
Usage : $0 [-s|--seuil N] [-d|--depuis PERIODE]
  -s, --seuil N        échecs par IP déclenchant l'alerte (0 à 9999, défaut $SEUIL)
  -d, --depuis PERIODE "N minutes|hours|days ago", "today", "yesterday"
                       ou une date AAAA-MM-JJ (défaut "$DEPUIS")
Codes de sortie : 0 normal, 1 erreur d'usage, 2 seuil dépassé
EOF
    exit 1
}

lire_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--seuil)
                [[ $# -ge 2 && "$2" =~ ^[0-9]{1,4}$ ]] || usage
                SEUIL=$((10#$2))
                shift 2
                ;;
            -d|--depuis)
                [[ $# -ge 2 ]] || usage
                # liste blanche : rien d'autre ne part vers journalctl
                if [[ "$2" =~ ^[0-9]{1,4}\ (minutes|hours|days)\ ago$ \
                   || "$2" =~ ^(today|yesterday)$ \
                   || "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                    DEPUIS="$2"
                else
                    usage
                fi
                shift 2
                ;;
            -h|--help) usage ;;
            *) usage ;;
        esac
    done
}

# Lignes réelles de sshd/sshd-session sous Debian 13 (OpenSSH 10) :
#   Accepted publickey for lucas from 192.168.65.1 port 52944 ssh2: ED25519 ...
#   Invalid user admin from 192.168.65.4 port 41532
#   Connection closed by authenticating user lucas 192.168.65.4 port 40686 [preauth]
#   User root from 192.168.65.4 not allowed because none of user's groups are listed in AllowGroups
#   Failed publickey for lucas from 192.168.65.4 port 40686 ssh2: ED25519 ...
# On compte un échec par tentative de connexion, pas par ligne.
analyser() {
    awk -v seuil="$SEUIL" '
    function compte(ip, user) {
        echecs[ip]++; vises[user]++; total++
    }
    / Accepted [a-z-]+ for / {
        for (i = 1; i <= NF; i++) if ($i == "for") { u = $(i+1); ip = $(i+3) }
        reussies[u " depuis " ip]++; nreussies++
        next
    }
    / Invalid user / {
        for (i = 1; i <= NF; i++) if ($i == "user") { u = $(i+1); ip = $(i+3) }
        compte(ip, u " (inexistant)")
        next
    }
    / not allowed because / {
        for (i = 1; i <= NF; i++) if ($i == "User") { u = $(i+1); ip = $(i+3) }
        compte(ip, u " (non autorisé)")
        next
    }
    / Connection closed by authenticating user .*\[preauth\]/ ||
    / Disconnected from authenticating user .*\[preauth\]/ {
        for (i = 1; i <= NF; i++) if ($i == "user") { u = $(i+1); ip = $(i+2) }
        compte(ip, u)
        next
    }
    / Failed password for / && !/invalid user/ {
        for (i = 1; i <= NF; i++) if ($i == "for") { u = $(i+1); ip = $(i+3) }
        compte(ip, u " (mot de passe)")
        next
    }
    END {
        printf "Échecs d'\''authentification : %d\n", total
        print "\n-- Échecs par IP --"
        for (ip in echecs) printf "%6d  %s%s\n", echecs[ip], ip, (echecs[ip] >= seuil ? "  <-- ALERTE" : "")
        print "\n-- Comptes visés --"
        for (u in vises) printf "%6d  %s\n", vises[u], u
        printf "\n-- Connexions réussies : %d --\n", nreussies
        for (r in reussies) printf "%6d  %s\n", reussies[r], r
        alerte = 0
        for (ip in echecs) if (echecs[ip] >= seuil) alerte = 1
        # seuil 0 : alerte systématique, pratique pour tester la supervision
        if (seuil == 0) alerte = 1
        exit alerte ? 2 : 0
    }'
}

main() {
    lire_options "$@"
    if [[ $EUID -ne 0 ]]; then
        echo "analyse_logs: ce script doit être lancé en root (sudo)" >&2
        exit 1
    fi

    local journal rapport code=0
    if ! journal="$(journalctl --no-pager -q -o short-iso \
            -t sshd -t sshd-session -S "$DEPUIS")"; then
        echo "analyse_logs: lecture du journal impossible" >&2
        exit 1
    fi

    echo "Rapport SSH de $(hostname) depuis \"$DEPUIS\" (seuil d'alerte : $SEUIL échecs par IP)"
    echo
    rapport="$(analyser <<< "$journal")" || code=$?
    echo "$rapport"
    if [[ "$code" -eq 2 ]]; then
        echo
        echo "ALERTE : seuil de $SEUIL échecs atteint"
    fi
    exit "$code"
}

main "$@"
