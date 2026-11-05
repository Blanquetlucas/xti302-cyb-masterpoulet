#!/bin/bash
# sauvegarde.sh - sauvegarde incrémentale de /srv et /etc (B1, B2)
#
# Chaque exécution crée /sauvegardes/AAAA-MM-JJ_HHMMSS. Grâce à --link-dest,
# un fichier inchangé depuis la version précédente n'est pas recopié : c'est
# un lien dur vers la même inode. Chaque version reste donc complète.
#
# Codes de sortie : 0 OK, 1 erreur d'usage, 2 disque absent, 3 échec rsync,
# 4 une sauvegarde tourne déjà.

set -euo pipefail

DEST=/sauvegardes
SOURCES=(/srv /etc)
GARDER=7
VERROU=/run/sauvegarde.lock

usage() {
    cat >&2 <<EOF
Usage : $0 [-g|--garder N]
  -g, --garder N   nombre de versions conservées (7 minimum, 7 par défaut)
EOF
    exit 1
}

log() {
    # sous systemd la sortie standard part déjà dans le journal ; logger
    # garde une trace aussi quand le script est lancé à la main
    echo "$*"
    logger -t sauvegarde -- "$*"
}

erreur() {
    echo "sauvegarde: $*" >&2
    logger -t sauvegarde -p user.err -- "$*"
}

lire_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -g|--garder)
                [[ $# -ge 2 && "$2" =~ ^[0-9]{1,3}$ && "$2" -ge 7 ]] || usage
                GARDER="$2"
                shift 2
                ;;
            -h|--help) usage ;;
            *) usage ;;
        esac
    done
}

rotation() {
    local anciennes
    # les noms datés se trient dans l'ordre chronologique
    mapfile -t anciennes < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}' \
        | sort | head -n -"$GARDER")
    for v in "${anciennes[@]}"; do
        rm -rf -- "$v"
        log "version supprimée : $v"
    done
}

sauvegarder() {
    local date cible precedente options=()
    date="$(date +%F_%H%M%S)"
    cible="$DEST/$date"

    if [[ -L "$DEST/derniere" && -d "$DEST/derniere" ]]; then
        precedente="$(readlink -f "$DEST/derniere")"
        options+=(--link-dest="$precedente")
    fi

    log "début de la sauvegarde vers $cible"
    # -A ACL, -X attributs étendus, -H liens durs ; --numeric-ids pour
    # restaurer les bons propriétaires même si les noms changent
    if ! rsync -aAXH --numeric-ids --delete "${options[@]}" \
            "${SOURCES[@]}" "$cible.encours/"; then
        rm -rf -- "$cible.encours"
        erreur "échec de rsync, version incomplète supprimée"
        exit 3
    fi
    # renommage à la fin : une version datée est toujours complète
    mv -- "$cible.encours" "$cible"
    ln -sfn "$date" "$DEST/derniere"
    log "sauvegarde terminée : $cible"
}

main() {
    lire_options "$@"
    if [[ $EUID -ne 0 ]]; then
        echo "sauvegarde: ce script doit être lancé en root" >&2
        exit 1
    fi
    # sans ce test on remplirait le disque système si le second disque manque
    if ! mountpoint -q "$DEST"; then
        erreur "$DEST n'est pas monté, sauvegarde annulée"
        exit 2
    fi

    exec 9>"$VERROU"
    if ! flock -n 9; then
        erreur "une sauvegarde est déjà en cours"
        exit 4
    fi

    # restes d'une exécution interrompue
    find "$DEST" -mindepth 1 -maxdepth 1 -name '*.encours' -exec rm -rf -- {} +

    sauvegarder
    rotation
}

main "$@"
