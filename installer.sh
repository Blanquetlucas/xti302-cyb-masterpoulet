#!/bin/bash
# installer.sh - reconstruit toute la configuration de srv-masterpoulet
# depuis une Debian 13 fraîchement installée. Relançable sans risque.
#
# Usage : sudo ./installer.sh [--secrets fichier]
#   --secrets : fichier au format chpasswd (login:motdepasse) pour les
#               administrateurs qui n'ont pas encore de mot de passe.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/config"
SECRETS=""
POINT_SAUV=/sauvegardes
PAQUETS=(sudo acl rsync nftables fail2ban python3-systemd unattended-upgrades
         apt-listchanges shellcheck libpam-tmpdir libpam-pwquality)

info()   { echo "==> $*"; }
erreur() { echo "installer: $*" >&2; }

usage() {
    echo "Usage : $0 [--secrets fichier]" >&2
    exit 1
}

lire_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --secrets)
                [[ $# -ge 2 && -f "$2" ]] || { erreur "--secrets : fichier introuvable"; exit 1; }
                SECRETS="$2"
                shift 2
                ;;
            -h|--help) usage ;;
            *) usage ;;
        esac
    done
}

paquets() {
    info "paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "${PAQUETS[@]}"
}

# --- C1, C2 ---
comptes() {
    info "comptes, groupes et ACL"
    bash "$DIR/creer_comptes.sh" "$DIR/comptes.csv"
}

admins_csv() {
    awk -F';' 'NR > 1 && $3 == "admins" { print $1 }' "$DIR/comptes.csv" | tr -d '\r'
}

# Un admin sans mot de passe ne pourrait ni faire sudo ni se connecter à
# la console : on ne verrouille root qu'une fois ce point réglé.
mots_de_passe_admins() {
    local a etat ligne ok=0
    for a in $(admins_csv); do
        etat="$(passwd -S "$a" | awk '{ print $2 }')"
        if [[ "$etat" != "P" ]]; then
            if [[ -n "$SECRETS" ]] && ligne="$(grep -m1 "^$a:" "$SECRETS")"; then
                echo "$ligne" | chpasswd
                info "mot de passe défini pour $a"
            elif [[ -t 0 ]]; then
                echo "Mot de passe pour l'administrateur $a :"
                passwd "$a"
            fi
        fi
        [[ "$(passwd -S "$a" | awk '{ print $2 }')" == "P" ]] && ok=$((ok + 1))
    done
    if [[ $ok -eq 0 ]]; then
        erreur "aucun administrateur n'a de mot de passe : root ne sera pas verrouillé."
        erreur "relancer avec --secrets <fichier> ou depuis un terminal."
        exit 1
    fi
}

# --- C3 ---
sudoers() {
    info "sudoers"
    local tmp
    tmp="$(mktemp)"
    cp "$CONF/sudoers.d/masterpoulet" "$tmp"
    if ! visudo -cqf "$tmp"; then
        rm -f "$tmp"
        erreur "config/sudoers.d/masterpoulet invalide, rien n'est installé"
        exit 1
    fi
    install -o root -g root -m 0440 "$tmp" /etc/sudoers.d/masterpoulet
    rm -f "$tmp"

    # Le compte créé à l'installation de Debian est dans le groupe sudo. Il
    # n'est pas dans comptes.csv : on lui retire sudo et on le verrouille.
    local u
    for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        gpasswd -d "$u" sudo >/dev/null
        info "$u retiré du groupe sudo"
    done
    u="$(getent passwd 1000 | cut -d: -f1 || true)"
    if [[ -n "$u" ]] && ! awk -F';' -v u="$u" 'NR > 1 && $1 == u { t = 1 } END { exit !t }' "$DIR/comptes.csv"; then
        usermod -L -e 1 -s /usr/sbin/nologin "$u"
        info "compte d'installation $u verrouillé"
    fi
}

# --- C4 ---
verrouiller() {
    info "verrouillage de root et des home"
    passwd -l root >/dev/null
    local h
    for h in /home/*/; do
        chmod 700 "$h"
    done
    chmod 700 /root
}

# --- S1 à S5 ---
ssh_durci() {
    info "SSH"
    install -o root -g root -m 0644 "$CONF/ssh/sshd_config.d/10-durcissement.conf" /etc/ssh/sshd_config.d/
    install -o root -g root -m 0644 "$CONF/profile.d/tmout.sh" /etc/profile.d/tmout.sh
    # S5 : on ne redémarre que si la config est valide, sinon on retire
    # notre fichier pour garder un sshd qui fonctionne
    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/10-durcissement.conf
        erreur "sshd -t a échoué, config SSH non appliquée"
        exit 1
    fi
    systemctl enable ssh >/dev/null 2>&1
    systemctl reload ssh
}

# --- J2 ---
parefeu() {
    info "nftables"
    nft -c -f "$CONF/nftables.conf"
    install -o root -g root -m 0755 "$CONF/nftables.conf" /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1
    if systemctl is-active -q nftables; then
        systemctl reload nftables
    else
        systemctl start nftables
    fi
}

# --- J1 ---
fail2ban() {
    info "fail2ban"
    install -o root -g root -m 0644 "$CONF/fail2ban/jail.d/sshd-masterpoulet.conf" /etc/fail2ban/jail.d/
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
}

# --- J3 ---
journal() {
    info "journal persistant"
    install -d -m 0755 /etc/systemd/journald.conf.d
    install -o root -g root -m 0644 "$CONF/journald.conf.d/persistant.conf" /etc/systemd/journald.conf.d/
    install -d /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
}

# --- D1 ---
mises_a_jour() {
    info "unattended-upgrades"
    install -o root -g root -m 0644 "$CONF/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
}

scripts() {
    info "scripts dans /usr/local/sbin"
    local s
    # root:root 0755 : support lance analyse_logs.sh en root, s'il pouvait
    # le modifier il deviendrait root
    for s in analyse_logs.sh sauvegarde.sh creer_comptes.sh verifier.sh; do
        install -o root -g root -m 0755 "$DIR/$s" /usr/local/sbin/
    done
    install -d -o root -g root -m 0755 /usr/local/share/masterpoulet
    install -o root -g root -m 0644 "$DIR/comptes.csv" "$CONF/suid_attendus.txt" /usr/local/share/masterpoulet/
}

# --- B1 : second disque ---
# On cherche un disque de 1 à 3 Gio, qui ne porte pas la racine et dont rien
# n'est monté. Il n'est formaté que s'il est entièrement vierge.
trouver_disque() {
    local racine nom taille type
    racine="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)"
    while read -r nom taille type; do
        [[ "$type" == disk && "$nom" != "$racine" ]] || continue
        (( taille >= 1073741824 && taille <= 3221225472 )) || continue
        lsblk -nro MOUNTPOINTS "/dev/$nom" | grep -q . && continue
        echo "/dev/$nom"
    done < <(lsblk -dnbo NAME,SIZE,TYPE)
}

disque() {
    info "disque de sauvegarde"
    local uuid dev candidats rep

    uuid="$(awk -v p="$POINT_SAUV" '$2 == p { sub("UUID=", "", $1); print $1 }' /etc/fstab)"
    if [[ -z "$uuid" ]]; then
        mapfile -t candidats < <(trouver_disque)
        if [[ ${#candidats[@]} -ne 1 ]]; then
            erreur "impossible d'identifier le disque de sauvegarde (${#candidats[@]} candidat(s))"
            exit 1
        fi
        dev="${candidats[0]}"
        if [[ -z "$(blkid -o value -s TYPE "$dev" || true)" ]]; then
            if [[ -n "$(wipefs -n "$dev")" ]]; then
                erreur "$dev contient des signatures (table de partitions ?), on n'y touche pas"
                exit 1
            fi
            if [[ -t 0 ]]; then
                read -r -p "Formater $dev ($(lsblk -dno SIZE "$dev")) en ext4 ? [o/N] " rep
                [[ "$rep" == o || "$rep" == O ]] || { erreur "abandon"; exit 1; }
            fi
            mkfs.ext4 -q -L sauvegardes "$dev"
            info "$dev formaté en ext4"
        fi
        uuid="$(blkid -o value -s UUID "$dev")"
        echo "UUID=$uuid $POINT_SAUV ext4 defaults,nofail,nodev,nosuid,noexec 0 2" >> /etc/fstab
        systemctl daemon-reload
    fi

    install -d "$POINT_SAUV"
    mountpoint -q "$POINT_SAUV" || mount "$POINT_SAUV"
    # B3 : root et le groupe admins seulement
    chown root:admins "$POINT_SAUV"
    chmod 0750 "$POINT_SAUV"
}

# --- B2 ---
planification() {
    info "timer de sauvegarde"
    install -o root -g root -m 0644 "$CONF/systemd/sauvegarde.service" "$CONF/systemd/sauvegarde.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer >/dev/null 2>&1
    if [[ ! -e "$POINT_SAUV/derniere" ]]; then
        systemctl start sauvegarde.service
    fi
}

# --- D3 ---
fichiers_ecrivables() {
    info "fichiers modifiables par tous"
    local fs
    for fs in $(findmnt -rn -t ext4,ext2,ext3,xfs,btrfs,vfat -o TARGET); do
        find "$fs" -xdev -type f -perm -0002 \
            -not -path '/tmp/*' -not -path '/var/tmp/*' -not -path '/dev/shm/*' \
            -print -exec chmod o-w {} +
    done
}

# --- Bonus : recommandations ANSSI et suggestions Lynis ---
ligne_login_defs() {
    if grep -qE "^\s*$1\s" /etc/login.defs; then
        sed -i -E "s/^\s*$1\s.*/$1\t$2/" /etc/login.defs
    else
        printf '%s\t%s\n' "$1" "$2" >> /etc/login.defs
    fi
}

# Avant ssh_durci : sshd lit /etc/issue.net (Banner)
bannieres() {
    info "bannières"
    install -o root -g root -m 0644 "$CONF/issue/issue" /etc/issue
    install -o root -g root -m 0644 "$CONF/issue/issue" /etc/issue.net
}

bonus() {
    info "bonus : ANSSI et Lynis"
    # R9, R11, R12, R14
    install -o root -g root -m 0644 "$CONF/sysctl.d/90-masterpoulet.conf" /etc/sysctl.d/
    sysctl -q -p /etc/sysctl.d/90-masterpoulet.conf

    # R28 : /tmp en noexec, apt doit alors extraire ses scripts ailleurs
    install -o root -g root -m 0644 "$CONF/apt/90templates-var-tmp" /etc/apt/apt.conf.d/
    install -d -m 0755 /etc/systemd/system/tmp.mount.d
    install -o root -g root -m 0644 "$CONF/systemd/tmp.mount.d/durcissement.conf" /etc/systemd/system/tmp.mount.d/
    systemctl daemon-reload
    if systemctl is-active -q tmp.mount; then
        mount -o remount,nosuid,nodev,noexec /tmp
    else
        systemctl start tmp.mount
    fi

    # R36 : shells en 077 ; Lynis AUTH-9328 lit login.defs
    install -o root -g root -m 0644 "$CONF/profile.d/umask.sh" /etc/profile.d/umask.sh
    ligne_login_defs UMASK 077

    # R29 : /boot réservé à root
    chmod 700 /boot

    # R50, Lynis FILE-7524 : la planification ne regarde que root
    chmod 600 /etc/crontab
    local d
    for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
        if [[ -d "$d" ]]; then
            chmod 700 "$d"
        fi
    done

    # Lynis NETW-3200, USB-1000, STRG-1846
    install -o root -g root -m 0644 "$CONF/modprobe.d/masterpoulet.conf" /etc/modprobe.d/
}

main() {
    lire_options "$@"
    if [[ $EUID -ne 0 ]]; then
        erreur "ce script doit être lancé en root"
        exit 1
    fi
    cd "$DIR"

    paquets
    comptes
    sudoers
    mots_de_passe_admins
    verrouiller
    bannieres
    ssh_durci
    parefeu
    fail2ban
    journal
    mises_a_jour
    scripts
    disque
    planification
    fichiers_ecrivables
    bonus
    info "installation terminée, lancer : sudo verifier.sh"
}

main "$@"
