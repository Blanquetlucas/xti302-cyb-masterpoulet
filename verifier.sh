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

# ======================================================= C1 comptes

test_C1_comptes_csv() {
    local l login principal secondaires g manque=""
    while IFS=';' read -r login _ principal secondaires; do
        login="${login//$'\r'/}"; principal="${principal//$'\r'/}"
        secondaires="${secondaires//$'\r'/}"
        [[ -z "$login" || "$login" == login ]] && continue
        if ! id "$login" >/dev/null 2>&1; then
            manque="$manque $login(absent)"; continue
        fi
        [[ "$(id -gn "$login")" == "$principal" ]] || manque="$manque $login(groupe principal)"
        for g in ${secondaires//,/ }; do
            id -nG "$login" | tr ' ' '\n' | grep -qx "$g" || manque="$manque $login($g)"
        done
    done < "$CSV"
    l="$(comptes_csv | wc -l)"
    if [[ -z "$manque" ]]; then
        ok "C1" "les $l comptes de comptes.csv existent avec les bons groupes"
    else
        ko "C1" "écarts avec comptes.csv :$manque"
    fi
}

test_C1_groupes() {
    local g manque=""
    for g in admins support acces_ssh comptables rh direction stagiaire; do
        getent group "$g" >/dev/null || manque="$manque $g"
    done
    [[ -z "$manque" ]] && ok "C1" "groupes admins, support, acces_ssh et métier présents" \
                       || ko "C1" "groupes absents :$manque"
}

test_C1_deux_par_groupe() {
    local g n faible=""
    for g in comptables rh direction stagiaire; do
        n="$(awk -F';' -v g="$g" 'NR > 1 && $3 == g' "$CSV" | wc -l)"
        [[ $n -ge 2 ]] || faible="$faible $g($n)"
    done
    [[ -z "$faible" ]] && ok "C1" "au moins 2 utilisateurs par groupe métier" \
                       || ko "C1" "groupes métier avec moins de 2 comptes :$faible"
}

test_C1_pas_de_doublon() {
    local d
    d="$(cut -d: -f1 /etc/passwd | sort | uniq -d; cut -d: -f1 /etc/group | sort | uniq -d; cut -d: -f3 /etc/passwd | sort | uniq -d)"
    [[ -z "$d" ]] && ok "C1" "aucun doublon de compte, de groupe ou d'UID" \
                  || ko "C1" "doublons : $(echo "$d" | tr '\n' ' ')"
}

test_C1_acces_ssh() {
    local attendus reels
    attendus="$(awk -F';' 'NR > 1 && $4 ~ /(^|,)acces_ssh(,|\r?$)/ { print $1 }' "$CSV" | tr -d '\r' | sort)"
    reels="$(getent group acces_ssh | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort)"
    # membres dont c'est le groupe principal
    if [[ "$attendus" == "$reels" ]]; then
        ok "C1" "acces_ssh contient exactement : $(echo "$reels" | tr '\n' ' ')"
    else
        ko "C1" "acces_ssh contient : $(echo "$reels" | tr '\n' ' ')(attendu : $(echo "$attendus" | tr '\n' ' '))"
    fi
}

test_C1_cles_ssh() {
    local u h mauvais=""
    for u in $(getent group acces_ssh | cut -d: -f4 | tr ',' ' '); do
        h="$(getent passwd "$u" | cut -d: -f6)"
        [[ "$(stat -c '%U %a' "$h/.ssh" 2>/dev/null)" == "$u 700" && \
           "$(stat -c '%U %a' "$h/.ssh/authorized_keys" 2>/dev/null)" == "$u 600" ]] \
            || mauvais="$mauvais $u"
    done
    [[ -z "$mauvais" ]] && ok "C1" "authorized_keys installés (700/600, propriétaire l'utilisateur)" \
                        || ko "C1" "clés absentes ou mauvais droits :$mauvais"
}

# ======================================================= C2 droits /srv

test_C2_dossiers_clients_comptables() { verifier_droits comptables /srv/dossiers_clients rwx; }
test_C2_dossiers_clients_rh()         { verifier_droits rh /srv/dossiers_clients ---; }
test_C2_dossiers_clients_direction()  { verifier_droits direction /srv/dossiers_clients r-x; }
test_C2_dossiers_clients_stagiaire()  { verifier_droits stagiaire /srv/dossiers_clients ---; }
test_C2_rh_comptables()               { verifier_droits comptables /srv/rh ---; }
test_C2_rh_rh()                       { verifier_droits rh /srv/rh rwx; }
test_C2_rh_direction()                { verifier_droits direction /srv/rh r-x; }
test_C2_rh_stagiaire()                { verifier_droits stagiaire /srv/rh ---; }
test_C2_commun_comptables()           { verifier_droits comptables /srv/commun rwx; }
test_C2_commun_rh()                   { verifier_droits rh /srv/commun rwx; }
test_C2_commun_direction()            { verifier_droits direction /srv/commun rwx; }
test_C2_commun_stagiaire()            { verifier_droits stagiaire /srv/commun r-x; }
test_C2_depot_comptables()            { verifier_droits comptables /srv/commun/depot rwx; }
test_C2_depot_rh()                    { verifier_droits rh /srv/commun/depot rwx; }
test_C2_depot_direction()             { verifier_droits direction /srv/commun/depot rwx; }
test_C2_depot_stagiaire()             { verifier_droits stagiaire /srv/commun/depot -wx; }

test_C2_autres_aucun_acces() {
    local d mauvais=""
    for d in /srv/dossiers_clients /srv/rh /srv/commun /srv/commun/depot; do
        getfacl -p "$d" 2>/dev/null | grep -qx 'other::---' || mauvais="$mauvais $d"
        getfacl -p "$d" 2>/dev/null | grep -qx 'default:other::---' || mauvais="$mauvais $d(défaut)"
    done
    [[ -z "$mauvais" ]] && ok "C2" "o::--- (accès et défaut) sur les 4 répertoires" \
                        || ko "C2" "les autres ont des droits sur :$mauvais"
}

test_C2_acl_defaut_dossiers_clients() {
    local f c d r s
    c="$(membre comptables)"; d="$(membre direction)"; r="$(membre rh)"; s="$(membre stagiaire)"
    f="$(fichier_test "$c" /srv/dossiers_clients)"
    if [[ -n "$f" ]] && sudo -u "$d" test -r "$f" && ! sudo -u "$d" test -w "$f" \
       && ! sudo -u "$r" test -r "$f" && ! sudo -u "$s" test -r "$f"; then
        ok "C2" "nouveau fichier de dossiers_clients : direction lit, rh et stagiaire non"
    else
        ko "C2" "ACL par défaut de dossiers_clients non appliquées au nouveau fichier"
    fi
}

test_C2_acl_defaut_rh() {
    local f r d c
    r="$(membre rh)"; d="$(membre direction)"; c="$(membre comptables)"
    f="$(fichier_test "$r" /srv/rh)"
    if [[ -n "$f" ]] && sudo -u "$d" test -r "$f" && ! sudo -u "$d" test -w "$f" \
       && ! sudo -u "$c" test -r "$f"; then
        ok "C2" "nouveau fichier de rh : direction lit, comptables non"
    else
        ko "C2" "ACL par défaut de /srv/rh non appliquées au nouveau fichier"
    fi
}

test_C2_acl_defaut_commun() {
    local f r c s
    r="$(membre rh)"; c="$(membre comptables)"; s="$(membre stagiaire)"
    f="$(fichier_test "$r" /srv/commun)"
    if [[ -n "$f" ]] && sudo -u "$c" test -w "$f" && sudo -u "$s" test -r "$f" \
       && ! sudo -u "$s" test -w "$f"; then
        ok "C2" "nouveau fichier de commun : comptables écrit, stagiaire lit seulement"
    else
        ko "C2" "ACL par défaut de /srv/commun non appliquées au nouveau fichier"
    fi
}

test_C2_depot_stagiaire_depose() {
    local s1 f
    s1="$(membre_n stagiaire 1)"
    f="$(fichier_test "$s1" /srv/commun/depot)"
    if [[ -n "$f" ]] && sudo -u "$s1" test -r "$f"; then
        ok "C2" "un stagiaire ($s1) peut déposer un fichier dans depot et relire le sien"
    else
        ko "C2" "le stagiaire $s1 ne peut pas déposer dans depot"
    fi
}

test_C2_depot_stagiaire_ne_lit_pas_autre() {
    local s1 s2 f
    s1="$(membre_n stagiaire 1)"; s2="$(membre_n stagiaire 2)"
    f="/srv/commun/depot/.verif_${s1}_$$"
    [[ -f "$f" ]] || f="$(fichier_test "$s1" /srv/commun/depot)"
    if [[ -n "$f" ]] && ! sudo -u "$s2" test -r "$f" && ! sudo -u "$s2" test -w "$f"; then
        ok "C2" "un stagiaire ($s2) ne lit ni n'écrit le dépôt d'un autre ($s1)"
    else
        ko "C2" "$s2 a accès au fichier déposé par $s1"
    fi
}

test_C2_depot_stagiaire_ne_liste_pas() {
    local s
    s="$(membre stagiaire)"
    if ! sudo -u "$s" ls /srv/commun/depot >/dev/null 2>&1; then
        ok "C2" "un stagiaire ne peut pas lister depot"
    else
        ko "C2" "un stagiaire peut lister /srv/commun/depot"
    fi
}

test_C2_depot_sticky() {
    local s1 s2 f
    s1="$(membre_n stagiaire 1)"; s2="$(membre_n stagiaire 2)"
    f="/srv/commun/depot/.verif_${s1}_$$"
    [[ -f "$f" ]] || f="$(fichier_test "$s1" /srv/commun/depot)"
    # sudo rm échoue normalement ; s'il réussit, le fichier de test disparaît,
    # ce qui ne touche que nos propres fichiers de test
    if [[ -k /srv/commun/depot ]] \
       && ! sudo -u "$s2" rm -f "$f" 2>/dev/null && [[ -f "$f" ]]; then
        ok "C2" "sticky bit sur depot : $s2 ne peut pas supprimer le fichier de $s1"
    else
        ko "C2" "pas de sticky bit sur depot ou suppression possible par un autre stagiaire"
    fi
}

test_C2_depot_comptable_lit_depot() {
    local s c f
    s="$(membre stagiaire)"; c="$(membre comptables)"
    f="/srv/commun/depot/.verif_${s}_$$"
    [[ -f "$f" ]] || f="$(fichier_test "$s" /srv/commun/depot)"
    if [[ -n "$f" ]] && sudo -u "$c" test -r "$f"; then
        ok "C2" "les comptables lisent les fichiers déposés par les stagiaires"
    else
        ko "C2" "les comptables ne lisent pas les dépôts des stagiaires"
    fi
}

# ======================================================= C3 sudo

test_C3_admins_sudo() {
    local a manque=""
    for a in $(awk -F';' 'NR > 1 && $3 == "admins" { print $1 }' "$CSV" | tr -d '\r'); do
        sudo -l -U "$a" 2>/dev/null | grep -q '(ALL : ALL) ALL' || manque="$manque $a"
    done
    [[ -z "$manque" ]] && ok "C3" "les administrateurs ont sudo" \
                       || ko "C3" "administrateurs sans sudo :$manque"
}

test_C3_admins_avec_mot_de_passe() {
    # on ignore les commentaires
    if grep -rhsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ | grep -vq '^support[[:space:]]'; then
        ko "C3" "NOPASSWD présent pour un autre compte que support"
    else
        ok "C3" "pas de NOPASSWD pour les administrateurs"
    fi
}

test_C3_support() {
    local cmds
    cmds="$(sudo -l -U support 2>/dev/null | sed -n '/may run the following/,$p' | tail -n +2 | sed 's/^ *//')"
    if [[ "$cmds" == "(root) NOPASSWD: $SBIN/analyse_logs.sh" ]]; then
        ok "C3" "le compte support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "droits sudo de support : $(echo "$cmds" | tr '\n' ' ')"
    fi
}

test_C3_aucun_autre_sudo() {
    local u admins mauvais=""
    admins=" $(awk -F';' 'NR > 1 && $3 == "admins" { printf "%s ", $1 }' "$CSV" | tr -d '\r')"
    while read -r u; do
        [[ "$u" == root || "$u" == support || "$admins" == *" $u "* ]] && continue
        sudo -l -U "$u" </dev/null 2>/dev/null | grep -q 'is not allowed to run sudo' || mauvais="$mauvais $u"
    done < <(awk -F: '$3 == 0 || $3 >= 1000 && $1 != "nobody" { print $1 }' /etc/passwd)
    [[ -z "$mauvais" ]] && ok "C3" "aucun autre compte n'a sudo (compte d'installation compris)" \
                        || ko "C3" "comptes avec sudo non prévus :$mauvais"
}

test_C3_groupe_sudo_vide() {
    local m
    m="$(getent group sudo | cut -d: -f4)"
    [[ -z "$m" ]] && ok "C3" "le groupe sudo est vide" \
                  || ko "C3" "membres du groupe sudo : $m"
}

test_C3_fichiers_sudoers() {
    local f mauvais=""
    for f in /etc/sudoers /etc/sudoers.d/*; do
        [[ "$(stat -c '%U:%G %a' "$f")" == "root:root 440" ]] || mauvais="$mauvais $f"
    done
    if [[ -z "$mauvais" ]] && visudo -cq; then
        ok "C3" "fichiers sudoers en 0440 root et syntaxe valide (visudo -c)"
    else
        ko "C3" "sudoers invalide ou mauvais droits :$mauvais"
    fi
}

test_C3_sudoers_d_attendu() {
    local f inconnus=""
    for f in /etc/sudoers.d/*; do
        case "$(basename "$f")" in README|masterpoulet) ;; *) inconnus="$inconnus $f" ;; esac
    done
    [[ -z "$inconnus" ]] && ok "C3" "aucun fichier inattendu dans /etc/sudoers.d" \
                         || ko "C3" "fichiers inattendus :$inconnus"
}

test_C3_scripts_root() {
    local s mauvais=""
    for s in analyse_logs.sh sauvegarde.sh creer_comptes.sh verifier.sh; do
        script_root_755 "$SBIN/$s" || mauvais="$mauvais $s"
    done
    [[ "$(stat -c '%U %a' "$SBIN")" == "root 755" ]] || mauvais="$mauvais $SBIN"
    [[ -z "$mauvais" ]] && ok "C3" "scripts de $SBIN en root:root 755 (support ne peut pas modifier analyse_logs.sh)" \
                        || ko "C3" "mauvais propriétaire/droits :$mauvais"
}

# ======================================================= C4

test_C4_root_verrouille() {
    [[ "$(passwd -S root | awk '{ print $2 }')" == "L" ]] && ok "C4" "root est verrouillé" \
                                                          || ko "C4" "root n'est pas verrouillé"
}

test_C4_home_prives() {
    local h mauvais=""
    for h in /home/*/ /root/; do
        [[ "$(stat -c %a "$h")" == 700 ]] || mauvais="$mauvais $h"
    done
    [[ -z "$mauvais" ]] && ok "C4" "répertoires personnels en 700" \
                        || ko "C4" "home lisibles par d'autres :$mauvais"
}

test_C4_home_illisible_autre() {
    local a b
    a="$(membre comptables)"; b="$(membre rh)"
    if ! sudo -u "$b" ls "$(getent passwd "$a" | cut -d: -f6)" >/dev/null 2>&1; then
        ok "C4" "$b ne peut pas lister le home de $a"
    else
        ko "C4" "$b peut lister le home de $a"
    fi
}

test_C4_home_mode() {
    grep -qE '^\s*HOME_MODE\s+0?700\s*$' /etc/login.defs && ok "C4" "HOME_MODE 0700 dans login.defs" \
                                                          || ko "C4" "HOME_MODE absent ou différent de 0700"
}

test_C4_admin_mot_de_passe() {
    local a n=0
    for a in $(awk -F';' 'NR > 1 && $3 == "admins" { print $1 }' "$CSV" | tr -d '\r'); do
        [[ "$(passwd -S "$a" | awk '{ print $2 }')" == "P" ]] && n=$((n + 1))
    done
    [[ $n -ge 1 ]] && ok "C4" "$n administrateur(s) avec mot de passe (accès console de secours)" \
                   || ko "C4" "aucun administrateur n'a de mot de passe : plus d'accès console"
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

# ======================================================= B1 à B4

versions() {
    find "$SAUV" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}' 2>/dev/null | sort
}

test_B1_disque_monte() {
    local src racine
    src="$(findmnt -no SOURCE "$SAUV" 2>/dev/null)"
    racine="$(findmnt -no SOURCE /)"
    if [[ -n "$src" && "$src" != "$racine" ]] && grep -qE "^UUID=\S+\s+$SAUV\s" /etc/fstab; then
        ok "B1" "$SAUV monté depuis $src (second disque, UUID dans fstab)"
    else
        ko "B1" "$SAUV n'est pas monté sur le second disque"
    fi
}

test_B1_versions_datees() {
    local n
    n="$(versions | wc -l)"
    if [[ $n -ge 1 && -L "$SAUV/derniere" && -d "$SAUV/derniere/srv" && -d "$SAUV/derniere/etc" ]]; then
        ok "B1" "$n version(s) datée(s), la dernière contient /srv et /etc"
    else
        ko "B1" "aucune version datée complète dans $SAUV"
    fi
}

test_B1_acl_conservees() {
    local a b
    a="$(getfacl -p /srv/commun/depot 2>/dev/null)"
    b="$(getfacl -p "$SAUV/derniere/srv/commun/depot" 2>/dev/null | sed "s#$SAUV/derniere##")"
    [[ -n "$a" && "$a" == "$b" ]] && ok "B1" "droits et ACL conservés dans la sauvegarde" \
                                  || ko "B1" "ACL de /srv/commun/depot différentes dans la sauvegarde"
}

test_B1_incremental() {
    local v a b
    mapfile -t v < <(versions)
    if [[ ${#v[@]} -lt 2 ]]; then
        grep -q -- '--link-dest' "$SBIN/sauvegarde.sh" \
            && ok "B1" "une seule version pour l'instant, sauvegarde.sh utilise --link-dest" \
            || ko "B1" "sauvegarde.sh n'est pas incrémental"
        return
    fi
    a="$(stat -c %i "${v[-2]}/etc/debian_version")"
    b="$(stat -c %i "${v[-1]}/etc/debian_version")"
    [[ "$a" == "$b" ]] && ok "B1" "incrémental : fichier inchangé partagé entre 2 versions (inode $a)" \
                       || ko "B1" "fichier inchangé recopié (inodes $a / $b)"
}

test_B1_rotation() {
    local n g
    n="$(versions | wc -l)"
    g="$(grep -oE '^GARDER=[0-9]+' "$SBIN/sauvegarde.sh" | cut -d= -f2)"
    [[ -n "$g" && $g -ge 7 && $n -le $g ]] && ok "B1" "rotation : $g versions gardées, $n présentes" \
                                           || ko "B1" "rotation incorrecte (GARDER='$g', $n versions)"
}

test_B2_timer() {
    actif_et_active sauvegarde.timer && ok "B2" "sauvegarde.timer actif et activé ($(systemctl show -p NextElapseUSecRealtime --value sauvegarde.timer))" \
                                     || ko "B2" "sauvegarde.timer arrêté ou désactivé"
}

test_B2_journalisee() {
    journalctl --no-pager -q -t sauvegarde 2>/dev/null | grep -q 'sauvegarde terminée' \
        && ok "B2" "exécutions de la sauvegarde présentes dans le journal" \
        || ko "B2" "aucune trace de sauvegarde dans le journal"
}

test_B3_droits() {
    [[ "$(stat -c '%U:%G %a' "$SAUV" 2>/dev/null)" == "root:admins 750" ]] \
        && ok "B3" "$SAUV en root:admins 750" \
        || ko "B3" "$SAUV en $(stat -c '%U:%G %a' "$SAUV" 2>/dev/null) (attendu root:admins 750)"
}

test_B3_non_admin() {
    local u a
    u="$(membre direction)"; a="$(membre admins)"
    if ! sudo -u "$u" ls "$SAUV" >/dev/null 2>&1 && sudo -u "$a" ls "$SAUV" >/dev/null 2>&1; then
        ok "B3" "$a liste les sauvegardes, $u non"
    else
        ko "B3" "accès aux sauvegardes incorrect pour $u ou $a"
    fi
}

test_B4_restauration() {
    TMPD="${TMPD:-$(mktemp -d)}"
    if rsync -aAX "$SAUV/derniere/etc/debian_version" "$SAUV/derniere/srv/commun/depot" "$TMPD/" 2>/dev/null \
       && cmp -s "$TMPD/debian_version" /etc/debian_version \
       && [[ "$(getfacl -cp "$TMPD/depot" 2>/dev/null)" == "$(getfacl -cp /srv/commun/depot)" ]]; then
        ok "B4" "restauration testée dans $TMPD : contenu et ACL identiques"
    else
        ko "B4" "la restauration depuis $SAUV/derniere échoue"
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
