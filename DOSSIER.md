# Dossier XTI302-CYB : serveur srv-masterpoulet

Contexte B du sujet (cabinet comptable), appliqué à l'entreprise Master Poulet. Serveur Debian 13 (trixie) minimal, VM VirtualBox `debian13-masterpoulet`, second disque de 2 Go pour les sauvegardes. Groupe : Clément, Lucas, Aymeric.

Le résultat de `verifier.sh` sur la VM reconstruite depuis le snapshot `vierge` est dans `docs/captures/verifier_installation.txt` et `docs/captures/verifier_apres_redemarrage.txt`.

## 1. Tableau de conformité

La colonne ANSSI n'est remplie que pour les numéros que nous avons pu relire dans les guides. Le site cyber.gouv.fr nous a bloqués (vérification anti-robot) au moment de la rédaction : les cases vides sont à compléter après relecture du guide BP-028 v2.0 et de la note « Usage sécurisé d'(Open)SSH ».

| Exigence | Ce qui a été fait | Tests de `verifier.sh` | ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv` (en-tête et lignes vides ignorés, `\r` supprimés, login et groupes validés par regex), crée les groupes manquants, crée les comptes absents, ajoute les groupes secondaires avec `usermod -a`, installe `authorized_keys` en 700/600. Relancé, il ne crée rien. | `test_C1_comptes_csv`, `test_C1_groupes`, `test_C1_deux_par_groupe`, `test_C1_pas_de_doublon`, `test_C1_acces_ssh`, `test_C1_cles_ssh` | |
| C2 | Répertoires en `root:root 0770`, droits donnés par ACL nommées (`g:comptables:rwx`...), mêmes entrées en ACL par défaut, `o::---`. `depot` : `g:stagiaire:-wx` sans entrée stagiaire dans l'ACL par défaut, sticky bit. | 16 tests `test_C2_<rep>_<groupe>` (une case du tableau chacun), `test_C2_autres_aucun_acces`, 3 tests `test_C2_acl_defaut_*`, 5 tests `test_C2_depot_*` | |
| C3 | `/etc/sudoers.d/masterpoulet` (0440, contrôlé par `visudo -c` avant installation) : `%admins ALL=(ALL:ALL) ALL`, `support` limité à `/usr/local/sbin/analyse_logs.sh`. Le compte d'installation est retiré du groupe `sudo`. Scripts en `root:root 0755`. | `test_C3_admins_sudo`, `test_C3_admins_avec_mot_de_passe`, `test_C3_support`, `test_C3_aucun_autre_sudo`, `test_C3_groupe_sudo_vide`, `test_C3_fichiers_sudoers`, `test_C3_sudoers_d_attendu`, `test_C3_scripts_root` | |
| C4 | `passwd -l root` (seulement après avoir vérifié qu'un admin a un mot de passe), home en 700, `HOME_MODE 0700` dans `/etc/login.defs`. | `test_C4_root_verrouille`, `test_C4_home_prives`, `test_C4_home_illisible_autre`, `test_C4_home_mode`, `test_C4_admin_mot_de_passe` | |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`. | `test_S1_mot_de_passe_refuse` (sshd -T), `test_S1_tentative_mot_de_passe` (vraie connexion) | |
| S2 | `PermitRootLogin no` (et root n'est pas dans `acces_ssh`). | `test_S2_root`, `test_S2_tentative_root` | |
| S3 | `AllowGroups acces_ssh`. | `test_S3_allowgroups`, `test_S3_pas_d_autre_filtre` | |
| S4 | `MaxAuthTries 3`, `LoginGraceTime 30`, `ChannelTimeout session=10m`, `ClientAliveInterval 300` x `ClientAliveCountMax 2`, `TMOUT=600` en lecture seule. | `test_S4_maxauthtries`, `test_S4_inactivite`, `test_S4_tmout` | |
| S5 | `/etc/ssh/sshd_config.d/10-durcissement.conf`, `sshd -t` avant `systemctl reload ssh` ; en cas d'erreur le fichier est retiré. | `test_S5_fichier_et_syntaxe`, `test_S5_pas_de_contradiction`, `test_S5_service_ssh` | |
| J1 | Jail `sshd` : `backend = systemd`, `mode = aggressive`, `banaction = nftables-multiport`, 5 échecs en 10 min, bannissement 15 min. | `test_J1_fail2ban_actif`, `test_J1_jail_sshd`, `test_J1_journald_nftables`, `test_J1_table_f2b` | |
| J2 | Table `inet filtre`, input en `policy drop`, `lo`, `invalid drop`, `established,related`, 22/tcp, ICMP limité. Pas de `flush ruleset`. `nftables.service` activé. | `test_J2_nftables_actif`, `test_J2_politique_drop`, `test_J2_regles`, `test_J2_seul_ssh_ouvert`, `test_J2_pas_de_flush`, `test_J2_forward_drop` | |
| J3 | `/etc/systemd/journald.conf.d/persistant.conf` : `Storage=persistent`. | `test_J3_persistant`, `test_J3_journal_sur_disque` | |
| J4 | `analyse_logs.sh` : échecs par IP, comptes visés, connexions réussies ; `-s`, `-d` validés par liste blanche ; `--no-pager`, `PAGER`/`SYSTEMD_PAGER` neutralisés ; codes 0/1/2. | `test_J4_alerte_seuil_0`, `test_J4_rapport`, `test_J4_arguments`, `test_J4_pas_de_pager`, `test_J4_support_peut_lancer`, `test_J4_support_rien_d_autre` | |
| B1 | `sauvegarde.sh` : `rsync -aAXH --numeric-ids --delete --link-dest` vers `/sauvegardes/AAAA-MM-JJ_HHMMSS`, lien `derniere`, 7 versions gardées, verrou `flock`. Disque monté par UUID avec `nofail`. | `test_B1_disque_monte`, `test_B1_versions_datees`, `test_B1_acl_conservees`, `test_B1_incremental`, `test_B1_rotation` | |
| B2 | `sauvegarde.timer` (tous les jours à 2 h, `Persistent=true`), sortie dans journald + `logger -t sauvegarde`. | `test_B2_timer`, `test_B2_journalisee` | |
| B3 | `/sauvegardes` en `root:admins 0750`. | `test_B3_droits`, `test_B3_non_admin` | |
| B4 | Restauration testée (partie 4). | `test_B4_restauration` | |
| D1 | `unattended-upgrades` + `20auto-upgrades`, origines par défaut (dont `debian-security`). | `test_D1_unattended`, `test_D1_timers_apt`, `test_D1_origine_securite` | |
| D2 | Seul sshd écoute sur le réseau (annexe A). | `test_D2_ecoutes` | |
| D3 | `installer.sh` retire `o+w` aux fichiers trouvés ; SUID comparés à `config/suid_attendus.txt` (annexe B). | `test_D3_world_writable`, `test_D3_suid` | |

## 2. Choix techniques

**Réseau et poste d'attaque.** Les deux VM sont sur un NAT Network VirtualBox (`xti302`, 192.168.65.0/24). La Kali y a sa propre IP (192.168.65.4) et sert aux attaques : nmap, tentatives SSH en boucle. Windows administre la VM par une redirection de port (2222 vers 22). À travers cette redirection, toutes les connexions de l'hôte arrivent avec l'IP de la passerelle du NAT Network. Si on attaquait depuis Windows, fail2ban bannirait la passerelle et on perdrait l'accès d'administration. C'est pour ça qu'on n'a pas utilisé le NAT simple avec redirection, où l'analyse par IP n'aurait plus de sens. On l'a d'ailleurs vécu avec la protection intégrée d'OpenSSH 10 (`PerSourcePenalties`) : après une série de connexions avortées depuis Windows, sshd a refusé l'IP de la passerelle pendant plusieurs minutes. On n'a pas exempté cette IP (ni dans sshd ni dans fail2ban) : n'importe qui passant par la redirection en profiterait. En cas de blocage, il suffit d'attendre ou de passer par la console de la VM.

**Compte d'installation.** L'installeur Debian, sans mot de passe root, met le premier utilisateur (`installeur`) dans le groupe `sudo`. Ce compte n'est pas nominatif et n'est pas dans `comptes.csv`. `installer.sh` vide donc le groupe `sudo`, verrouille `installeur` (`usermod -L -e 1`, shell `nologin`) mais ne le supprime pas : on garde son UID et ses fichiers pour l'historique, et il est facile de le réactiver depuis un compte admin si besoin.

**Mots de passe des admins, pas de NOPASSWD.** Root est verrouillé, donc les admins ont besoin d'un mot de passe pour la console de secours et pour sudo. On garde la demande de mot de passe à sudo : une clé SSH volée (ou une session laissée ouverte) ne donne pas root directement. `installer.sh` refuse de verrouiller root si aucun admin n'a de mot de passe. `support` n'a pas de mot de passe (clé seule), donc sa ligne est en `NOPASSWD`, mais limitée à un script.

**Scripts en root:root 0755 dans /usr/local/sbin.** `support` lance `analyse_logs.sh` en root. S'il pouvait modifier le script (ou le répertoire qui le contient), il y mettrait `bash` et deviendrait root. Même chose pour `sauvegarde.sh` lancé par le timer. Dans `analyse_logs.sh`, les arguments passent par une liste blanche et le pager est désactivé : `journalctl` lancé en root avec `less` permet d'ouvrir un shell (`!sh`, cf. GTFOBins).

**MaxAuthTries 3.** Avec des clés, un client légitime essaie rarement plus de 2 ou 3 clés. 3 reste sous la limite de 4 du sujet. Si un admin a beaucoup de clés dans son agent, il doit préciser `-i`.

**Inactivité : ChannelTimeout + TMOUT.** `ClientAliveInterval 300` et `ClientAliveCountMax 2` ne ferment que les sessions dont le client ne répond plus (câble coupé, VM client éteinte) : sshd envoie des messages de maintien, et tant que le client y répond la session reste ouverte même si personne ne tape rien. Pour une vraie inactivité, on utilise `ChannelTimeout session=10m` (OpenSSH 9.2 et plus) : sshd ferme le canal s'il n'y a eu aucun trafic dessus pendant 10 minutes. On ajoute `TMOUT=600` en lecture seule dans `/etc/profile.d/` : bash se ferme seul après 10 minutes sans commande, ce qui marche aussi en console. On reste sous les 15 minutes du sujet.

**fail2ban : maxretry 5, findtime 10 min, bantime 15 min, mode aggressive.** Avec l'authentification par clé, il n'y a pas de « Failed password » : un attaquant produit surtout `Invalid user ...` et `Connection closed by authenticating user ... [preauth]`. Le mode `normal` ne compte pas cette seconde ligne, d'où `aggressive`. 5 échecs laissent de la marge à un admin qui se trompe de clé. 15 minutes de bannissement suffisent à casser une attaque automatisée sans nous bloquer longtemps pendant la démo (et `fail2ban-client set sshd unbanip` débannit tout de suite).

**Seuil d'alerte de analyse_logs.sh : 10 échecs par IP sur 24 h.** fail2ban bannit à 5 échecs en 10 minutes. Une IP qui atteint 10 est soit revenue après un bannissement, soit en train d'attaquer lentement pour rester sous le seuil de fail2ban. Dans les deux cas un humain doit regarder. Le seuil est réglable avec `-s` ; avec `-s 0` le script est toujours en alerte, ce qui sert à tester la chaîne de supervision.

**Pare-feu et ICMP.** On accepte `echo-request` limité à 5 par seconde (le ping reste utile pour diagnostiquer) et les messages d'erreur ICMP nécessaires (destination injoignable, dépassement de délai, paquet trop gros en IPv6 pour la découverte de MTU). En IPv6, la découverte de voisins est indispensable. On n'utilise pas `flush ruleset` : on supprime et recrée seulement notre table `inet filtre`, pour que `systemctl reload nftables` ne vide pas la table `f2b-table` de fail2ban. On l'a testé : reload, puis `nft list tables` montre toujours `f2b-table`.

**Sauvegardes.** Une version par jour à 2 h, 7 versions gardées : une semaine d'historique, ce qui laisse le temps de s'apercevoir d'une suppression faite un vendredi. Grâce à `--link-dest`, un fichier inchangé ne prend pas de place une deuxième fois (lien dur vers la même inode, vérifié avec `stat -c %i`). `-A -X` gardent ACL et attributs étendus, `--numeric-ids` évite qu'un UID soit remappé. La version est écrite dans `AAAA-MM-JJ_HHMMSS.encours` puis renommée : une version datée est toujours complète. `/sauvegardes` est en `root:admins 0750` : un admin peut parcourir l'historique, et à l'intérieur les droits d'origine sont conservés (par exemple `/srv/rh` reste fermé aux non-membres de `rh`). Le disque est monté en `nodev,nosuid,noexec` et avec `nofail` pour que la VM démarre même sans lui. Le script refuse de tourner si `/sauvegardes` n'est pas monté, sinon il remplirait le disque système.

**Règle 3-2-1.** Elle demande 3 copies des données, sur 2 supports différents, dont 1 hors site. Ici on a 2 copies sur la même machine : un incendie, un ransomware qui chiffre tout ce qui est monté ou un admin compromis détruisent les deux. En entreprise il faudrait au minimum une copie vers un autre serveur, poussée en mode « pull » par ce serveur de sauvegarde, et une copie hors ligne ou hors site.

**Préparation du disque.** `installer.sh` cherche un disque de 1 à 3 Gio qui ne porte pas la racine et dont rien n'est monté. S'il en trouve zéro ou plusieurs, il s'arrête. Il ne formate que si `blkid` ne trouve aucun système de fichiers et que `wipefs -n` ne trouve aucune signature, et demande confirmation s'il est lancé dans un terminal. Ensuite il ne se fie plus qu'à l'UUID écrit dans `/etc/fstab` : relancé, il ne reformate jamais.

**`set -u` seulement dans verifier.sh.** Le script lance exprès des commandes qui doivent échouer (un stagiaire qui lit `/srv/rh`...). Avec `-e`, il s'arrêterait au premier refus attendu ou au premier KO. Sans `pipefail` : dans `sshd -T | grep -q ...`, grep peut sortir dès qu'il a trouvé, sshd reçoit alors SIGPIPE et le tube serait en échec alors que le test est bon. `-u` reste utile pour repérer une faute de frappe dans un nom de variable. Les autres scripts sont en `set -euo pipefail`.

**ACL : root propriétaire et entrées nommées.** Les répertoires appartiennent à `root:root` avec `g::---`, et chaque groupe métier a une entrée nommée. Le groupe propriétaire d'un fichier créé dans `depot` par un stagiaire est `stagiaire` : comme l'ACL par défaut met `g::---` et n'a pas d'entrée `stagiaire`, un autre stagiaire n'a aucun droit sur ce fichier. Le masque est recalculé à chaque `setfacl -m` ; s'il était abaissé (par un `chmod g-rwx`), les entrées nommées perdraient leurs droits, ce que les tests de C2 détecteraient.

## 3. Défense

**Force brute SSH.** Pas de mot de passe accepté en SSH, donc rien à deviner. Les connexions ratées sont limitées à 3 essais, puis fail2ban bannit l'IP au bout de 5 échecs. Testé depuis la Kali : après la boucle de connexions, `nmap` voit le port 22 filtré et `fail2ban-client status sshd` liste 192.168.65.4 (captures `j1_*`).

**Vol d'un mot de passe.** Le mot de passe d'un admin ne sert qu'en console et pour sudo, pas en SSH. Pour l'utiliser il faut déjà être connecté avec sa clé.

**Utilisateur curieux.** Les home sont en 700, `o::---` sur tous les répertoires de `/srv`, et un comptable ne voit pas `/srv/rh`. Les comptes métier n'ont pas d'accès SSH.

**Compte stagiaire compromis.** Il peut déposer dans `depot` mais ne peut ni lister ni lire ce que les autres y ont mis, ni supprimer ou remplacer leurs fichiers (sticky bit). Il ne peut rien écrire ailleurs que dans `depot`.

**Support qui tente une élévation.** `support` ne peut lancer que `analyse_logs.sh`. Le script appartient à root, les arguments passent par une liste blanche (pas d'injection dans `journalctl`), et le pager est désactivé. `sudo -n bash` et `sudo journalctl` sont refusés (testés dans `verifier.sh`).

**Ce que la configuration ne couvre pas.** La sauvegarde est sur la même machine (voir 3-2-1). Un admin compromis (clé + mot de passe) a tous les droits, y compris celui d'effacer les sauvegardes et les journaux, qui ne sont pas envoyés vers un serveur distant. Une faille 0-day dans OpenSSH reste exploitable puisque le port 22 est ouvert ; les mises à jour automatiques réduisent seulement la fenêtre. Un attaquant qui dispose de nombreuses IP passe sous fail2ban. Enfin le disque n'est pas chiffré : qui récupère le fichier `.vdi` lit tout.

## 4. Procédure de restauration (B4)

Exemple testé : un comptable a supprimé `/srv/dossiers_clients/bilan_2025.txt`, qui existait dans une sauvegarde antérieure.

1. Se connecter avec un compte admin : `ssh -p 2222 clement@127.0.0.1`.
2. Lister les versions disponibles : `ls -l /sauvegardes/`.
3. Retrouver le fichier dans les versions : `sudo ls -l /sauvegardes/*/srv/dossiers_clients/bilan_2025.txt`.
4. Vérifier le contenu de la version choisie : `sudo cat /sauvegardes/2026-10-29_143012/srv/dossiers_clients/bilan_2025.txt`.
5. Restaurer en gardant droits, propriétaire et ACL :
   `sudo rsync -aAX --numeric-ids /sauvegardes/2026-10-29_143012/srv/dossiers_clients/bilan_2025.txt /srv/dossiers_clients/`
6. Contrôler : `getfacl /srv/dossiers_clients/bilan_2025.txt` doit montrer les mêmes entrées qu'avant, et un membre de `direction` doit pouvoir le lire : `sudo -u pmercier cat /srv/dossiers_clients/bilan_2025.txt`.

Pour un répertoire entier, même commande avec une barre oblique finale sur la source : `rsync -aAX --numeric-ids /sauvegardes/<version>/srv/rh/ /srv/rh/`. On ne met pas `--delete`, pour ne pas effacer ce qui a été créé depuis. En cas de doute, on restaure d'abord dans un répertoire temporaire et on compare avec `diff -r`.

Le test complet est dans `docs/captures/b4_restauration.txt`.

## Annexe A : écoutes réseau (D2)

`ss -tulpn` sur le serveur installé :

| Écoute | Processus | Justification |
|---|---|---|
| 0.0.0.0:22 et [::]:22 (tcp) | sshd | Seul service voulu. |
| 192.168.65.5:68 (udp) | client DHCP | L'adresse vient du DHCP du NAT Network. La socket n'accepte que les réponses du serveur DHCP, et le pare-feu ne laisse entrer que le trafic lié à une requête partie de la VM. |
| [fe80::...]:546 (udp) | client DHCPv6 | Même rôle en IPv6, limité à l'adresse lien-local. |

Vu de l'extérieur, `nmap -sS -p-` et `nmap -sU --top-ports 50` depuis la Kali ne montrent que 22/tcp ouvert, tout le reste est filtré (`docs/captures/nmap_depuis_kali.txt`). OpenSSH 10 ajoute aussi ses propres pénalités par source (`PerSourcePenalties`) : une IP qui échoue est refusée quelques secondes par sshd lui-même, avant même fail2ban.

## Annexe B : fichiers SUID et SGID (D3)

`verifier.sh` compare la liste trouvée avec `config/suid_attendus.txt` ; tout nouveau fichier SUID ou SGID donne un KO (testé avec `chmod u+s /usr/bin/find`).

| Fichier | Bit | Pourquoi il est là |
|---|---|---|
| /usr/bin/passwd | SUID root | un utilisateur change son mot de passe, donc écrit dans `/etc/shadow` |
| /usr/bin/chfn, /usr/bin/chsh | SUID root | changer son nom complet ou son shell dans `/etc/passwd` |
| /usr/bin/gpasswd, /usr/bin/newgrp | SUID root | gestion des mots de passe de groupe, changement de groupe courant |
| /usr/bin/su | SUID root | changer d'identité (inutile pour root, qui est verrouillé) |
| /usr/bin/sudo | SUID root | élévation contrôlée par `/etc/sudoers.d/masterpoulet` |
| /usr/bin/mount, /usr/bin/umount | SUID root | montages déclarés `user` dans fstab (aucun chez nous) |
| /usr/lib/openssh/ssh-keysign | SUID root | authentification par hôte d'OpenSSH (non utilisée) |
| /usr/lib/dbus-1.0/dbus-daemon-launch-helper | SUID root, groupe messagebus | lancement des services D-Bus système, exécutable seulement par le groupe messagebus |
| /usr/bin/chage, /usr/bin/expiry | SGID shadow | lire les dates d'expiration dans `/etc/shadow` |
| /usr/sbin/unix_chkpwd | SGID shadow | PAM vérifie le mot de passe d'un utilisateur (déverrouillage, sudo) |
| /usr/bin/crontab | SGID crontab | écrire dans `/var/spool/cron/crontabs` |
| /usr/bin/dotlockfile | SGID mail | verrous sur les boîtes aux lettres |
| /usr/bin/ssh-agent | SGID _ssh | empêche un autre processus de l'utilisateur de lire la mémoire de l'agent |

Ce sont tous des fichiers des paquets de base de Debian. On aurait pu enlever le bit SUID de `chfn`, `chsh`, `mount`, `umount` et `ssh-keysign`, inutiles sur ce serveur. On ne l'a pas fait : la prochaine mise à jour du paquet le remettrait, sauf à passer par `dpkg-statoverride`, et on a préféré une liste attendue vérifiée automatiquement.
