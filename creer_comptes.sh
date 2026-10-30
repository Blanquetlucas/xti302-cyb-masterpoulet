#!/bin/bash
# creer_comptes.sh - comptes, groupes, répertoires de /srv et ACL (C1, C2)
# Usage : sudo ./creer_comptes.sh [fichier.csv]
# Relançable autant de fois qu'on veut : rien n'est recréé s'il existe déjà.

set -euo pipefail

DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
CSV="${1:-$DIR_SCRIPT/comptes.csv}"
DIR_CLES="$DIR_SCRIPT/config/cles"
GROUPES_METIER="comptables rh direction stagiaire"

erreur() { echo "creer_comptes: $*" >&2; }

usage() {
    echo "Usage : $0 [fichier.csv]" >&2
    exit 1
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        erreur "ce script doit être lancé en root"
        exit 1
    fi
    if [[ ! -r "$CSV" ]]; then
        erreur "fichier introuvable : $CSV"
        exit 1
    fi
    command -v setfacl >/dev/null || { erreur "paquet acl manquant"; exit 1; }
}

creer_groupe() {
    getent group "$1" >/dev/null || groupadd "$1"
}

# --- C1 : comptes et groupes ---
installer_cle() {
    local login="$1" home cle
    cle="$DIR_CLES/$login.pub"
    [[ -f "$cle" ]] || return 0
    home="$(getent passwd "$login" | cut -d: -f6)"
    install -d -m 700 -o "$login" -g "$(id -gn "$login")" "$home/.ssh"
    install -m 600 -o "$login" -g "$(id -gn "$login")" "$cle" "$home/.ssh/authorized_keys"
}

traiter_ligne() {
    local login="$1" nom="$2" principal="$3" secondaires="$4" g

    if [[ ! "$login" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        erreur "ligne $5 : login invalide '$login', ignorée"
        return 0
    fi
    for g in $principal ${secondaires//,/ }; do
        if [[ ! "$g" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            erreur "ligne $5 : groupe invalide '$g', ligne ignorée"
            return 0
        fi
    done

    creer_groupe "$principal"
    for g in ${secondaires//,/ }; do
        creer_groupe "$g"
    done

    if ! id "$login" >/dev/null 2>&1; then
        # pas de mot de passe : compte verrouillé tant que personne n'en définit un
        useradd -m -s /bin/bash -g "$principal" -c "$nom" "$login"
        echo "compte créé : $login"
    fi
    # -a : on ajoute sans retirer les groupes déjà présents
    if [[ -n "$secondaires" ]]; then
        usermod -a -G "$secondaires" "$login"
    fi

    chmod 700 "$(getent passwd "$login" | cut -d: -f6)"
    installer_cle "$login"
}

lire_csv() {
    local n=0 login nom principal secondaires
    while IFS=';' read -r login nom principal secondaires || [[ -n "$login" ]]; do
        n=$((n + 1))
        [[ $n -eq 1 ]] && continue
        login="${login//$'\r'/}"
        principal="${principal//$'\r'/}"
        secondaires="${secondaires//$'\r'/}"
        secondaires="${secondaires// /}"
        [[ -z "$login" ]] && continue
        if [[ -z "$principal" ]]; then
            erreur "ligne $n : groupe principal manquant, ignorée"
            continue
        fi
        traiter_ligne "$login" "$nom" "$principal" "$secondaires" "$n"
    done < "$CSV"
}

# HOME_MODE pour les comptes créés plus tard (C4)
regler_login_defs() {
    if grep -qE '^\s*HOME_MODE' /etc/login.defs; then
        sed -i -E 's/^\s*HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
}

# --- C2 : répertoires de /srv ---
# $1 = répertoire, $2 = liste "groupe:droits" ; les mêmes entrées servent
# d'ACL d'accès et d'ACL par défaut.
appliquer_acl() {
    local rep="$1" entrees="$2" acl e
    install -d -o root -g root -m 0770 "$rep"
    acl="u::rwx,g::---,o::---"
    for e in $entrees; do
        acl="$acl,g:$e"
    done
    # on repart de zéro pour retirer une ACL ajoutée à la main
    setfacl -b "$rep"
    setfacl -m "$acl" "$rep"
    setfacl -d -m "$acl" "$rep"
}

creer_repertoires() {
    local g
    for g in $GROUPES_METIER; do
        creer_groupe "$g"
    done
    chmod 755 /srv

    appliquer_acl /srv/dossiers_clients "comptables:rwx direction:r-x"
    appliquer_acl /srv/rh               "rh:rwx direction:r-x"
    appliquer_acl /srv/commun           "comptables:rwx rh:rwx direction:rwx stagiaire:r-x"

    # depot : stagiaire en -wx (dépose sans lister). L'ACL par défaut ne
    # donne rien à stagiaire ni au groupe propriétaire (qui sera stagiaire
    # pour un fichier déposé par un stagiaire), donc un stagiaire ne lit
    # pas le fichier d'un autre.
    install -d -o root -g root -m 0770 /srv/commun/depot
    setfacl -b /srv/commun/depot
    setfacl -m "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:-wx" /srv/commun/depot
    setfacl -d -m "u::rwx,g::---,o::---,g:comptables:rwx,g:rh:rwx,g:direction:rwx" /srv/commun/depot
    # sticky bit : personne ne supprime ni ne renomme le fichier d'un autre
    chmod +t /srv/commun/depot
}

main() {
    [[ $# -le 1 ]] || usage
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
    verifier_prerequis
    lire_csv
    regler_login_defs
    creer_repertoires
    echo "creer_comptes: terminé"
}

main "$@"
