#!/bin/bash
# Les tests s'écrivent "condition && ok ... || ko ...". ShellCheck prévient
# que ko serait lancé si ok échouait ; ok ne fait qu'un printf et renvoie
# toujours 0, donc la forme courte est sûre ici.
# shellcheck disable=SC2015
#
# verifier.sh - vérifie chaque exigence du cahier des charges sur le serveur
# Usage : sudo ./verifier.sh
# Code de sortie : 0 si tout est conforme, 1 sinon.
#
# Pas de set -e ici : le script passe son temps à lancer des commandes qui
# doivent échouer (accès refusés...), -e l'arrêterait au premier refus.
# Pas de pipefail non plus : avec "cmd | grep -q", grep peut sortir dès la
# première ligne trouvée, cmd reçoit SIGPIPE et le test serait faux à tort.
# On garde -u pour attraper les variables mal orthographiées.
#
# Le script ne modifie rien, sauf des fichiers de test dans /srv et un
# dossier temporaire, supprimés à la sortie (trap).

set -u
export LC_ALL=C

DIR="$(cd "$(dirname "$0")" && pwd)"
PARTAGE=/usr/local/share/masterpoulet
CSV="$DIR/comptes.csv"
[[ -f "$CSV" ]] || CSV="$PARTAGE/comptes.csv"
SUID_ATTENDUS="$DIR/config/suid_attendus.txt"
[[ -f "$SUID_ATTENDUS" ]] || SUID_ATTENDUS="$PARTAGE/suid_attendus.txt"
SAUV=/sauvegardes
SBIN=/usr/local/sbin

NB_OK=0
NB_TOTAL=0
TMPD=""
A_SUPPRIMER=()

ok() {
    NB_OK=$((NB_OK + 1)); NB_TOTAL=$((NB_TOTAL + 1))
    printf '[OK] %s %s\n' "$1" "$2"
}
ko() {
    NB_TOTAL=$((NB_TOTAL + 1))
    printf '[KO] %s %s\n' "$1" "$2"
}

nettoyer() {
    local f
    for f in "${A_SUPPRIMER[@]}"; do
        rm -f -- "$f"
    done
    [[ -n "$TMPD" ]] && rm -rf -- "$TMPD"
}

# ---------------------------------------------------------------- outils

# premier compte du CSV dont le groupe principal est $1
membre() {
    awk -F';' -v g="$1" 'NR > 1 && $3 == g { print $1; exit }' "$CSV" | tr -d '\r'
}
# n-ième membre (pour avoir deux stagiaires différents)
membre_n() {
    awk -F';' -v g="$1" -v n="$2" 'NR > 1 && $3 == g && ++i == n { print $1; exit }' "$CSV" | tr -d '\r'
}
comptes_csv() {
    awk -F';' 'NR > 1 && $1 != "" { print $1 }' "$CSV" | tr -d '\r'
}

# droits effectifs d'un utilisateur sur un répertoire, sous la forme "rwx"
droits_de() {
    local u="$1" d="$2" r="-" w="-" x="-"
    sudo -u "$u" test -r "$d" && r=r
    sudo -u "$u" test -w "$d" && w=w
    sudo -u "$u" test -x "$d" && x=x
    echo "$r$w$x"
}

verifier_droits() {
    local groupe="$1" rep="$2" attendu="$3" u obtenu
    u="$(membre "$groupe")"
    obtenu="$(droits_de "$u" "$rep")"
    if [[ "$obtenu" == "$attendu" ]]; then
        ok "C2" "$groupe ($u) a $attendu sur $rep"
    else
        ko "C2" "$groupe ($u) a $obtenu sur $rep (attendu : $attendu)"
    fi
}

sshd_valeur() {
    sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'
}

actif_et_active() {
    systemctl is-active -q "$1" && systemctl is-enabled -q "$1"
}

script_root_755() {
    [[ "$(stat -c '%U:%G %a' "$1" 2>/dev/null)" == "root:root 755" ]]
}

# fichier de test créé par $1 dans $2, retenu pour suppression
fichier_test() {
    local f="$2/.verif_$1_$$"
    A_SUPPRIMER+=("$f")
    sudo -u "$1" sh -c "echo test > '$f'" 2>/dev/null && echo "$f"
}

# ======================================================= S1 à S5

test_S1_mot_de_passe_refuse() {
    if [[ "$(sshd_valeur passwordauthentication)" == no && "$(sshd_valeur kbdinteractiveauthentication)" == no \
          && "$(sshd_valeur pubkeyauthentication)" == yes ]]; then
        ok "S1" "sshd -T : clé uniquement (password et kbdinteractive à no)"
    else
        ko "S1" "authentification par mot de passe encore possible dans sshd -T"
    fi
}

test_S1_tentative_mot_de_passe() {
    local u sortie
    u="$(membre admins)"
    sortie="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password,keyboard-interactive -o ConnectTimeout=5 \
        "$u@127.0.0.1" true 2>&1)"
    if [[ "$sortie" == *"Permission denied (publickey)"* ]]; then
        ok "S1" "vraie tentative : le serveur ne propose que publickey"
    else
        ko "S1" "tentative par mot de passe : $sortie"
    fi
}

test_S2_root() {
    if sshd -T | grep -qi '^permitrootlogin no$'; then
        ok "S2" "connexion root refusée (PermitRootLogin no)"
    else
        ko "S2" "PermitRootLogin n'est pas à 'no'"
    fi
}

test_S2_tentative_root() {
    local sortie
    sortie="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 root@127.0.0.1 true 2>&1)"
    if [[ "$sortie" == *"Permission denied"* ]]; then
        ok "S2" "vraie tentative de connexion root refusée"
    else
        ko "S2" "tentative root : $sortie"
    fi
}

test_S3_allowgroups() {
    [[ "$(sshd_valeur allowgroups)" == acces_ssh ]] && ok "S3" "AllowGroups acces_ssh" \
                                                    || ko "S3" "AllowGroups vaut '$(sshd_valeur allowgroups)'"
}

test_S3_pas_d_autre_filtre() {
    local v
    v="$(sshd_valeur allowusers)"
    [[ -z "$v" ]] && ok "S3" "pas d'AllowUsers qui contournerait AllowGroups" \
                  || ko "S3" "AllowUsers défini : $v"
}

test_S4_maxauthtries() {
    local v
    v="$(sshd_valeur maxauthtries)"
    [[ -n "$v" && "$v" -le 4 ]] && ok "S4" "MaxAuthTries $v (4 au plus)" \
                                || ko "S4" "MaxAuthTries vaut '$v' (attendu : 4 au plus)"
}

test_S4_inactivite() {
    local i c ct
    i="$(sshd_valeur clientaliveinterval)"; c="$(sshd_valeur clientalivecountmax)"
    ct="$(sshd_valeur channeltimeout)"
    if [[ "$i" -gt 0 && $((i * c)) -le 900 && "$ct" == *"session=10m"* ]]; then
        ok "S4" "inactivité : ChannelTimeout $ct, client muet coupé après $((i * c)) s"
    else
        ko "S4" "inactivité SSH mal réglée (ClientAlive $i x $c, ChannelTimeout '$ct')"
    fi
}

test_S4_tmout() {
    if bash -lc 'readonly -p | grep -q "TMOUT=\"600\""' 2>/dev/null; then
        ok "S4" "TMOUT=600 en lecture seule pour les shells de connexion"
    else
        ko "S4" "TMOUT absent ou modifiable"
    fi
}

test_S5_fichier_et_syntaxe() {
    local f=/etc/ssh/sshd_config.d/10-durcissement.conf
    if [[ -f "$f" && "$(stat -c '%U %a' "$f")" == "root 644" ]] && sshd -t 2>/dev/null; then
        ok "S5" "config dans sshd_config.d et sshd -t valide"
    else
        ko "S5" "$f absent, mal protégé ou sshd -t en erreur"
    fi
}

test_S5_pas_de_contradiction() {
    local c
    c="$(grep -lEis '^\s*(PasswordAuthentication|KbdInteractiveAuthentication|PermitRootLogin)\s+yes' \
        /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf)"
    [[ -z "$c" ]] && ok "S5" "aucun autre fichier ne réactive mot de passe ou root" \
                  || ko "S5" "directive contraire dans : $c"
}

test_S5_service_ssh() {
    actif_et_active ssh && ok "S5" "service ssh actif et activé" \
                        || ko "S5" "service ssh arrêté ou désactivé"
}

# ======================================================= J1 fail2ban

test_J1_fail2ban_actif() {
    actif_et_active fail2ban && ok "J1" "fail2ban actif et activé" \
                             || ko "J1" "fail2ban arrêté ou désactivé"
}

test_J1_jail_sshd() {
    local mr bt
    mr="$(fail2ban-client get sshd maxretry 2>/dev/null)"
    bt="$(fail2ban-client get sshd bantime 2>/dev/null)"
    if [[ -n "$mr" && "$mr" -le 5 && "$bt" -ge 600 ]]; then
        ok "J1" "jail sshd active (maxretry $mr, bantime $bt s)"
    else
        ko "J1" "jail sshd absente ou trop permissive (maxretry '$mr', bantime '$bt')"
    fi
}

test_J1_journald_nftables() {
    local a
    a="$(fail2ban-client get sshd actions 2>/dev/null)"
    if fail2ban-client get sshd journalmatch 2>/dev/null | grep -q '_SYSTEMD_UNIT\|sshd' \
       && [[ "$a" == *nftables* ]]; then
        ok "J1" "fail2ban lit journald et bannit via nftables"
    else
        ko "J1" "fail2ban : backend ou action incorrects ($a)"
    fi
}

test_J1_table_f2b() {
    nft list tables 2>/dev/null | grep -q 'f2b-table' && ok "J1" "table nftables de fail2ban présente" \
                                                       || ko "J1" "table f2b-table absente de nftables"
}

# ======================================================= J2 nftables

test_J2_nftables_actif() {
    actif_et_active nftables && ok "J2" "nftables actif et activé (règles rechargées au démarrage)" \
                             || ko "J2" "nftables arrêté ou désactivé"
}

test_J2_politique_drop() {
    local p
    p="$(nft list chain inet filtre input 2>/dev/null | grep -o 'policy [a-z]*' | awk '{ print $2 }')"
    [[ "$p" == drop ]] && ok "J2" "politique par défaut de la chaîne input : drop" \
                       || ko "J2" "politique par défaut du pare-feu : ${p:-absente} (attendu : drop)"
}

test_J2_regles() {
    local r manque=""
    r="$(nft list chain inet filtre input 2>/dev/null)"
    [[ "$r" == *'iif "lo" accept'* ]] || manque="$manque lo"
    [[ "$r" == *'ct state established,related accept'* ]] || manque="$manque established"
    [[ "$r" == *'ct state invalid drop'* ]] || manque="$manque invalid"
    [[ "$r" == *'tcp dport 22 ct state new accept'* ]] || manque="$manque ssh"
    [[ -z "$manque" ]] && ok "J2" "règles lo, invalid, established et SSH présentes" \
                       || ko "J2" "règles manquantes :$manque"
}

test_J2_seul_ssh_ouvert() {
    local autres
    autres="$(nft list chain inet filtre input 2>/dev/null | grep -E 'dport' | grep -v 'dport 22 ')"
    [[ -z "$autres" ]] && ok "J2" "aucun autre port ouvert que 22" \
                       || ko "J2" "autres ouvertures : $autres"
}

test_J2_pas_de_flush() {
    grep -qE '^\s*flush\s+ruleset' /etc/nftables.conf && ko "J2" "flush ruleset dans /etc/nftables.conf (efface fail2ban)" \
                                                      || ok "J2" "pas de flush ruleset : la table fail2ban survit au rechargement"
}

test_J2_forward_drop() {
    nft list chain inet filtre forward 2>/dev/null | grep -q 'policy drop' && ok "J2" "chaîne forward en drop" \
                                                                           || ko "J2" "chaîne forward absente ou en accept"
}

# ======================================================= J3 journal

test_J3_persistant() {
    local s
    s="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^\s*Storage=' | tail -n1)"
    if [[ "$s" == "Storage=persistent" && -d /var/log/journal/"$(cat /etc/machine-id)" ]]; then
        ok "J3" "journal persistant (Storage=persistent, /var/log/journal)"
    else
        ko "J3" "journal non persistant (${s:-Storage par défaut})"
    fi
}

test_J3_journal_sur_disque() {
    if journalctl --header 2>/dev/null | grep -q '/var/log/journal'; then
        ok "J3" "journald écrit bien dans /var/log/journal"
    else
        ko "J3" "journald écrit en mémoire (/run/log/journal)"
    fi
}

# ======================================================= J4 analyse_logs

test_J4_alerte_seuil_0() {
    "$SBIN/analyse_logs.sh" -s 0 >/dev/null 2>&1
    [[ $? -eq 2 ]] && ok "J4" "analyse_logs.sh renvoie 2 avec un seuil à 0" \
                   || ko "J4" "analyse_logs.sh ne signale pas l'alerte avec un seuil à 0"
}

test_J4_rapport() {
    local r
    r="$("$SBIN/analyse_logs.sh" -s 9999 2>&1)"
    if [[ $? -eq 0 && "$r" == *"par IP"* && "$r" == *"Comptes visés"* && "$r" == *"Connexions réussies"* ]]; then
        ok "J4" "rapport complet (échecs par IP, comptes visés, réussites), code 0 sous le seuil"
    else
        ko "J4" "rapport incomplet ou code de sortie anormal"
    fi
}

test_J4_arguments() {
    "$SBIN/analyse_logs.sh" -d '1 hours ago; id' >/dev/null 2>&1; local a=$?
    "$SBIN/analyse_logs.sh" -s abc >/dev/null 2>&1; local b=$?
    [[ $a -eq 1 && $b -eq 1 ]] && ok "J4" "arguments invalides refusés (code 1)" \
                               || ko "J4" "arguments invalides acceptés (codes $a / $b)"
}

test_J4_pas_de_pager() {
    grep -q -- '--no-pager' "$SBIN/analyse_logs.sh" && grep -q 'SYSTEMD_PAGER=cat' "$SBIN/analyse_logs.sh" \
        && ok "J4" "journalctl en --no-pager, pager neutralisé" \
        || ko "J4" "analyse_logs.sh peut lancer un pager (shell root possible)"
}

test_J4_support_peut_lancer() {
    sudo -u support sudo -n "$SBIN/analyse_logs.sh" -s 9999 >/dev/null 2>&1 && ok "J4" "support lance analyse_logs.sh via sudo sans mot de passe" \
                   || ko "J4" "support ne peut pas lancer analyse_logs.sh"
}

test_J4_support_rien_d_autre() {
    if ! sudo -u support sudo -n /bin/bash -c true >/dev/null 2>&1 \
       && ! sudo -u support sudo -n /usr/bin/journalctl -n1 >/dev/null 2>&1; then
        ok "J4" "support ne peut pas lancer bash ni journalctl en root"
    else
        ko "J4" "support peut lancer d'autres commandes en root"
    fi
}

# ======================================================= D1 à D3

test_D1_unattended() {
    if dpkg -s unattended-upgrades 2>/dev/null | grep -q 'Status: install ok installed' \
       && apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
       && apt-config dump | grep -q 'APT::Periodic::Update-Package-Lists "1"'; then
        ok "D1" "unattended-upgrades installé et activé (apt-config)"
    else
        ko "D1" "mises à jour automatiques non configurées"
    fi
}

test_D1_timers_apt() {
    actif_et_active apt-daily-upgrade.timer && actif_et_active apt-daily.timer \
        && ok "D1" "timers apt-daily et apt-daily-upgrade actifs" \
        || ko "D1" "timers apt désactivés"
}

test_D1_origine_securite() {
    apt-config dump | grep -A5 'Unattended-Upgrade::Origins-Pattern' | grep -q 'security' \
        && ok "D1" "les mises à jour de sécurité Debian sont incluses" \
        || ko "D1" "l'origine debian-security n'est pas dans Origins-Pattern"
}

test_D2_ecoutes() {
    local e
    # on ignore l'écoute locale et les clients DHCP (68) et DHCPv6 (546)
    e="$(ss -tulpnH | awk '{ print $1, $5, $7 }' \
        | grep -vE ' (127\.0\.0\.[0-9]+|\[::1\]):' \
        | grep -vE '^udp \S+:(68|546) ' | grep -vE '^tcp \S+:22 .*sshd')"
    [[ -z "$e" ]] && ok "D2" "seul sshd (22/tcp) écoute sur le réseau (+ client DHCP)" \
                  || ko "D2" "écoutes inattendues : $(echo "$e" | tr '\n' ';')"
}

test_D3_world_writable() {
    local fs trouves=""
    for fs in $(findmnt -rn -t ext4,ext3,ext2,xfs,btrfs,vfat -o TARGET); do
        trouves="$trouves$(find "$fs" -xdev -type f -perm -0002 \
            -not -path '/tmp/*' -not -path '/var/tmp/*' -not -path '/dev/shm/*' 2>/dev/null)"
    done
    [[ -z "$trouves" ]] && ok "D3" "aucun fichier modifiable par tous hors répertoires temporaires" \
                        || ko "D3" "fichiers modifiables par tous : $(echo "$trouves" | head -5 | tr '\n' ' ')"
}

test_D3_suid() {
    local fs trouves inattendus
    trouves="$(for fs in $(findmnt -rn -t ext4,ext3,ext2,xfs,btrfs,vfat -o TARGET); do
        find "$fs" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null; done | sort -u)"
    inattendus="$(comm -23 <(echo "$trouves") <(grep -v '^#' "$SUID_ATTENDUS" | sed '/^$/d' | sort -u))"
    [[ -z "$inattendus" ]] && ok "D3" "$(echo "$trouves" | wc -l) fichiers SUID/SGID, tous dans suid_attendus.txt" \
                           || ko "D3" "SUID/SGID inattendus : $(echo "$inattendus" | tr '\n' ' ')"
}

# ================================================================ main

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "verifier: ce script doit être lancé en root (sudo)" >&2
        exit 1
    fi
    if [[ ! -r "$CSV" ]]; then
        echo "verifier: comptes.csv introuvable" >&2
        exit 1
    fi
    trap nettoyer EXIT
    TMPD="$(mktemp -d)"

    local p f
    for p in C S J B D; do
        for f in $(declare -F | awk '{ print $3 }' | grep "^test_$p"); do
            "$f"
        done
    done

    echo "--- $NB_OK / $NB_TOTAL tests réussis"
    [[ $NB_OK -eq $NB_TOTAL ]]
}

main "$@"
