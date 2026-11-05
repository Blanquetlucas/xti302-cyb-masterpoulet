# Dossier XTI302-CYB : serveur srv-masterpoulet

Contexte B du sujet (cabinet comptable), appliqué à l'entreprise Master Poulet. Serveur Debian 13 (trixie) minimal, VM VirtualBox `debian13-masterpoulet`, second disque de 2 Go pour les sauvegardes. Groupe : Clément Berton, Lucas Blanquet, Aymeric Brevet.

`verifier.sh` compte 90 tests. Sur la VM reconstruite par `installer.sh` depuis le snapshot `vierge`, il donne 90/90 juste après l'installation, après une deuxième exécution d'`installer.sh` et après un redémarrage (`docs/captures/verifier_*`).

## 1. Tableau de conformité

Les tests sont les fonctions de `verifier.sh` ; leur nom commence par l'identifiant de l'exigence. La colonne ANSSI renvoie au guide « Recommandations de configuration d'un système GNU/Linux » (BP-028 v2.0) et à la note « Usage sécurisé d'(Open)SSH » (notée SSH). Le guide ne traite pas des sauvegardes.

| Exigence | Ce qui a été fait | Tests | ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv` (en-tête, lignes vides et `\r` ignorés, login et groupes validés par regex), crée groupes et comptes absents, ajoute les groupes secondaires avec `usermod -a`, installe `authorized_keys` (700/600). Relancé, il ne crée rien. | 6 tests `test_C1_*` (comptes du CSV et leurs groupes, doublons, `acces_ssh`, clés) | BP-028 R33 ; SSH R21 |
| C2 | Répertoires en `root:root 0770`, droits par ACL nommées (`g:comptables:rwx`...), mêmes entrées en ACL par défaut, `o::---`. `depot` : `g:stagiaire:-wx`, aucune entrée stagiaire dans l'ACL par défaut, sticky bit. | 25 tests : une case du tableau par test, `o::---`, ACL par défaut sur un fichier créé, 5 cas sur `depot` | BP-028 R50, R54 |
| C3 | `/etc/sudoers.d/masterpoulet` (0440, contrôlé par `visudo -c`) : `%admins ALL=(ALL:ALL) ALL`, `support` limité à `analyse_logs.sh`. Groupe `sudo` vidé. Scripts en `root:root 0755`. | 8 tests `test_C3_*` (`sudo -l -U` pour chaque compte, droits des sudoers, scripts) | BP-028 R30, R38, R39 (en partie : `use_pty` et journal sudo ; `noexec` bloquerait apt lancé par les admins) |
| C4 | `passwd -l root` après avoir vérifié qu'un admin a un mot de passe, home en 700, `HOME_MODE 0700`. | 5 tests `test_C4_*` | BP-028 R33, R50 |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`. | `sshd -T` + vraie tentative par mot de passe | SSH R17 |
| S2 | `PermitRootLogin no`, root hors de `acces_ssh`. | `sshd -T` + vraie tentative en root | SSH R21 |
| S3 | `AllowGroups acces_ssh`. | 2 tests `test_S3_*` | SSH R22 |
| S4 | `MaxAuthTries 3`, `ChannelTimeout session=10m`, `ClientAliveInterval 300` x 2, `TMOUT=600` en lecture seule. | 3 tests `test_S4_*` | BP-028 R32 |
| S5 | `10-durcissement.conf` dans `sshd_config.d`, `sshd -t` avant `systemctl reload ssh`. | 3 tests `test_S5_*` (syntaxe, aucune directive contraire, service) | SSH R23, R27, R28 (même fichier) |
| J1 | Jail `sshd` : `backend = systemd`, `mode = aggressive`, action `nftables-multiport`, 5 échecs en 10 min, bannissement 15 min. | 4 tests `test_J1_*` (service, jail, action, table `f2b-table`) | BP-028 R79 |
| J2 | Table `inet filtre` : input en `policy drop`, `lo`, `invalid drop`, `established,related`, 22/tcp, ICMP limité. Pas de `flush ruleset`. | 6 tests `test_J2_*` | BP-028 R79, R80 |
| J3 | `journald.conf.d/persistant.conf` : `Storage=persistent`. | 2 tests `test_J3_*` | BP-028 R71 |
| J4 | `analyse_logs.sh` : échecs par IP, comptes visés, connexions réussies ; arguments en liste blanche ; pas de pager ; codes 0/1/2. | 6 tests `test_J4_*` (seuil 0, rapport, arguments, `support`) | BP-028 R71, R79 |
| B1 | `sauvegarde.sh` : `rsync -aAXH --numeric-ids --link-dest` vers `/sauvegardes/AAAA-MM-JJ_HHMMSS`, 7 versions, `flock`. Disque monté par UUID, `nofail`. | 5 tests `test_B1_*` (montage, versions, ACL, inode partagé, rotation) | aucune (hors périmètre du guide) |
| B2 | `sauvegarde.timer` (2 h, `Persistent=true`), sortie dans journald. | 2 tests `test_B2_*` | aucune |
| B3 | `/sauvegardes` en `root:admins 0750`. | 2 tests `test_B3_*` | BP-028 R50 |
| B4 | Restauration testée (partie 4). | `test_B4_restauration` | aucune |
| D1 | `unattended-upgrades` + `20auto-upgrades`, origine `debian-security`. | 3 tests `test_D1_*` | BP-028 R59, R61 |
| D2 | Seul sshd écoute sur le réseau (annexe A). | `test_D2_ecoutes` | BP-028 R62, R80 |
| D3 | Aucun fichier modifiable par tous ; SUID comparés à `config/suid_attendus.txt` (annexe B). | 2 tests `test_D3_*` | BP-028 R54, R56, R57 |

## 2. Choix techniques

**Réseau, administration et attaques.** La Kali de Lucas administre le serveur, la Kali d'Aymeric l'attaque (nmap, connexions SSH en boucle). Avec deux IP différentes, fail2ban bannit l'attaquant sans couper l'administration. Sur un même PC, VM et Kali sont sur un NAT Network VirtualBox (`xti302`, 192.168.65.0/24) ; pour une Kali sur un autre PC, la carte de la VM passe en accès par pont. On a écarté le NAT avec redirection de port : toutes les connexions y arrivent avec l'IP de la passerelle, qui serait bannie. On l'a constaté depuis l'hôte Windows : après des connexions avortées, la protection intégrée d'OpenSSH 10 (`PerSourcePenalties`) a refusé la passerelle plusieurs minutes. On n'exempte aucune IP ; en cas de blocage, on passe par la console de la VM.

**Compte d'installation.** Sans mot de passe root, l'installeur Debian met le premier utilisateur (`installeur`) dans le groupe `sudo`. Ce compte n'est pas nominatif : `installer.sh` vide le groupe `sudo` et verrouille `installeur` (`usermod -L -e 1`, shell `nologin`) sans le supprimer, pour garder la trace de ses fichiers.

**Pas de NOPASSWD pour les admins.** Root étant verrouillé, les admins ont un mot de passe pour sudo et pour la console de secours. Une clé SSH volée ou une session laissée ouverte ne donne donc pas root directement. `installer.sh` refuse de verrouiller root si aucun admin n'a de mot de passe. `support`, qui n'a qu'une clé, est en `NOPASSWD` mais pour un seul script.

**Scripts en root:root 0755 dans /usr/local/sbin.** `support` lance `analyse_logs.sh` en root : s'il pouvait modifier le script ou son répertoire, il y mettrait `bash` et deviendrait root. Les arguments du script passent par une liste blanche et le pager est désactivé, car `journalctl` lancé en root dans `less` permet d'ouvrir un shell (`!sh`, cf. GTFOBins).

**SSH : MaxAuthTries 3 et inactivité.** Un client légitime présente rarement plus de 2 ou 3 clés, et 3 reste sous la limite de 4. `ClientAliveInterval 300` x 2 ne ferme que les sessions dont le client ne répond plus : tant qu'il répond aux messages de maintien, une session oubliée reste ouverte. Pour la vraie inactivité, `ChannelTimeout session=10m` ferme un canal sans trafic depuis 10 minutes, et `TMOUT=600` en lecture seule ferme le shell, y compris en console. On reste sous les 15 minutes demandées.

**fail2ban : 5 échecs en 10 min, 15 min de bannissement, mode aggressive.** Avec la clé seule, il n'y a jamais de « Failed password » : un attaquant produit `Invalid user`, `not allowed because ... AllowGroups` et `Connection closed by authenticating user ... [preauth]`, que le mode `normal` ne compte pas entièrement. Une connexion ratée produit souvent deux lignes : en pratique l'IP est bannie après 3 connexions. 15 minutes cassent une attaque automatisée, et `fail2ban-client set sshd unbanip` débloque tout de suite.

**Seuil de analyse_logs.sh : 10 échecs par IP sur 24 h.** Comme fail2ban bannit à 5, une IP qui atteint 10 est revenue après un bannissement ou attaque lentement sous le seuil : un humain doit regarder. Le seuil se règle avec `-s`.

**Pare-feu.** Ping accepté mais limité à 5 par seconde, messages d'erreur ICMP utiles acceptés, découverte de voisins IPv6 indispensable. Pas de `flush ruleset` : on supprime et recrée seulement `inet filtre`, sinon `systemctl reload nftables` viderait la table `f2b-table` de fail2ban (testé : capture `j2_reload_nftables_garde_f2b.txt`).

**Sauvegardes.** Une version par jour, 7 gardées : une semaine pour s'apercevoir d'une suppression. Avec `--link-dest`, un fichier inchangé est un lien dur vers la même inode (vérifié avec `stat -c %i`). La version est écrite dans un `.encours` puis renommée, donc une version datée est toujours complète. `/sauvegardes` est en `root:admins 0750`, les droits d'origine sont conservés à l'intérieur, le disque est monté `nodev,nosuid,noexec,nofail` et le script refuse de tourner s'il n'est pas monté. `installer.sh` ne formate qu'un disque unique de 1 à 3 Gio, sans système de fichiers ni signature, puis ne se fie plus qu'à l'UUID de `/etc/fstab` : relancé, il ne reformate jamais.

**Règle 3-2-1.** 3 copies, sur 2 supports, dont 1 hors site. Ici les 2 copies sont sur la même machine : un incendie, un ransomware ou un admin compromis détruisent les deux. Il faudrait au minimum une copie récupérée par un autre serveur, plus une copie hors ligne.

**`set -u` seulement dans verifier.sh.** Le script lance exprès des commandes qui doivent échouer : avec `-e`, il s'arrêterait au premier refus attendu. Sans `pipefail`, car dans `sshd -T | grep -q`, grep sort dès qu'il a trouvé et sshd reçoit SIGPIPE : le tube serait en échec alors que le test est bon. Les autres scripts sont en `set -euo pipefail`.

**ACL.** Répertoires à `root:root` avec `g::---` et une entrée nommée par groupe. Un fichier déposé par un stagiaire a pour groupe `stagiaire`, mais l'ACL par défaut de `depot` met `g::---` et n'a pas d'entrée stagiaire : un autre stagiaire n'y a aucun droit. Si le masque était abaissé (`chmod g-rwx`), les entrées nommées perdraient leurs droits, ce que les tests C2 détectent.

## 3. Défense

**Force brute SSH.** Aucun mot de passe accepté en SSH, donc rien à deviner ; 3 essais par connexion, puis bannissement par fail2ban. Testé depuis la Kali : `Connection refused`, port 22 vu `filtered` par nmap, IP dans `fail2ban-client status sshd` (captures `j1_*`).

**Vol d'un mot de passe.** Le mot de passe d'un admin ne sert qu'en console et pour sudo : pour s'en servir, il faut déjà être connecté avec sa clé.

**Utilisateur curieux.** Home en 700, `o::---` sur `/srv`, un comptable ne voit pas `/srv/rh`, et les comptes métier n'ont pas d'accès SSH.

**Compte stagiaire compromis.** Il dépose dans `depot` mais ne peut ni lister, ni lire, ni supprimer les dépôts des autres (sticky bit), et n'écrit nulle part ailleurs.

**Support qui tente une élévation.** Il ne lance que `analyse_logs.sh`, qui appartient à root, filtre ses arguments et n'ouvre pas de pager. `sudo bash` et `sudo journalctl` lui sont refusés (testés).

**Ce qui n'est pas couvert.** Les sauvegardes sont sur la même machine. Un admin compromis (clé + mot de passe) peut tout effacer, journaux compris, car rien n'est envoyé vers un serveur distant. Une faille 0-day d'OpenSSH reste exploitable sur le port 22. Un attaquant aux nombreuses IP passe sous fail2ban. Le disque n'est pas chiffré : qui récupère le `.vdi` lit tout.

## 4. Procédure de restauration (B4)

Cas testé : un comptable a supprimé `/srv/dossiers_clients/bilan_2025.txt`.

1. Se connecter avec un compte admin : `ssh lucas@192.168.65.5`.
2. Lister les versions : `sudo ls -l /sauvegardes/`.
3. Trouver les versions qui contiennent le fichier : `sudo ls -l /sauvegardes/*/srv/dossiers_clients/bilan_2025.txt`.
4. Vérifier le contenu de la version choisie : `sudo cat /sauvegardes/2026-10-29_114110/srv/dossiers_clients/bilan_2025.txt`.
5. Restaurer avec droits, propriétaire et ACL :
   `sudo rsync -aAX --numeric-ids /sauvegardes/2026-10-29_114110/srv/dossiers_clients/bilan_2025.txt /srv/dossiers_clients/`
6. Contrôler : `getfacl /srv/dossiers_clients/bilan_2025.txt` montre les mêmes entrées qu'avant ; `sudo -u pmercier cat ...` (direction) fonctionne, `sudo -u sgarnier cat ...` (rh) est refusé.

Pour un répertoire entier : `rsync -aAX --numeric-ids /sauvegardes/<version>/srv/rh/ /srv/rh/`, sans `--delete` pour ne pas effacer ce qui a été créé depuis. En cas de doute, on restaure d'abord dans un répertoire temporaire et on compare avec `diff -r`. Le test complet est dans `docs/captures/b4_restauration.txt`.

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
