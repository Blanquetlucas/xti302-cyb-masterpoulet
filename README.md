# XTI302-CYB : durcir un serveur Linux et le prouver

Contexte B du sujet (cabinet comptable), appliqué à l'entreprise Master Poulet. Les groupes métier et les répertoires de `/srv` gardent les noms du sujet : `comptables`, `rh`, `direction`, `stagiaire`.

Groupe : Clément Berton, Lucas Blanquet, Aymeric Brevet.

| Membre | Partie |
|---|---|
| Clément | comptes, ACL, sudo, sauvegardes : `comptes.csv`, `creer_comptes.sh`, `config/sudoers.d`, `sauvegarde.sh`, `config/systemd` |
| Lucas | SSH, fail2ban, nftables, journaux, système, installation : `config/ssh`, `config/fail2ban`, `config/nftables.conf`, `config/journald.conf.d`, `analyse_logs.sh`, `config/apt`, `installer.sh` |
| Aymeric | tests d'attaque depuis sa Kali (scan de ports, force brute SSH, bannissement fail2ban) |
| tous | `verifier.sh`, `DOSSIER.md` |

Le rapport est dans [DOSSIER.md](DOSSIER.md).

## Machines

| Machine | Rôle |
|---|---|
| VM `debian13-masterpoulet` (Debian 13 minimal) | le serveur à durcir, avec un second disque de 2 Go pour les sauvegardes |
| Kali de Lucas | poste d'administration : connexion SSH avec les clés des admins, copie du dépôt, lancement des scripts |
| Kali d'Aymeric | poste d'attaque : nmap, tentatives SSH en boucle |

On sépare l'administration et les attaques sur deux IP différentes : fail2ban bannit l'IP qui attaque, et le poste d'administration n'est jamais coupé. Sur un seul PC, la VM et la Kali sont sur le NAT Network VirtualBox `xti302` (192.168.65.0/24). Pour que la Kali d'Aymeric, sur un autre PC, atteigne le serveur, la carte réseau de la VM passe en « accès par pont » sur le même réseau.

## Prérequis

- VM Debian 13 (trixie) installée en minimal : sans bureau, avec « serveur SSH » et « utilitaires usuels du système ».
- Un second disque virtuel de 1 à 2 Go, vierge. `installer.sh` le repère tout seul (disque de 1 à 3 Gio qui ne porte pas la racine et dont rien n'est monté) et ne le formate que s'il ne contient aucune signature.
- Un snapshot `vierge` pris juste après l'installation.

## Installation

Depuis la Kali d'administration, copier le dépôt sur la VM (dépôt privé : pas de jeton sur le serveur) :

```
tar -cf - . | ssh installeur@192.168.65.5 "mkdir -p ~/xti302 && tar -xf - -C ~/xti302"
```

Puis sur la VM :

```
sudo cp -r ~/xti302 /opt/xti302 && sudo chown -R root:root /opt/xti302
sudo /opt/xti302/installer.sh --secrets /root/secrets_admins
sudo shred -u /root/secrets_admins
```

`--secrets` donne les mots de passe des administrateurs qui n'en ont pas encore, au format `chpasswd` (`login:motdepasse`). Ce fichier n'est jamais dans le dépôt : on le copie en `/root` en mode 600 et on le supprime après l'installation. Sans `--secrets`, le script demande les mots de passe si on est sur un terminal ; sinon il s'arrête avant de verrouiller root, pour ne jamais se retrouver sans accès.

Le script est relançable : il ne recrée ni compte ni groupe, ne reformate jamais un disque qui a déjà un système de fichiers et ne touche pas aux sauvegardes existantes.

Ensuite on se connecte avec un compte admin et sa clé :

```
ssh -i ~/.ssh/xti302/lucas lucas@192.168.65.5
```

## Vérification

```
sudo verifier.sh
```

Une ligne `[OK]` ou `[KO]` par test, le total à la fin, code de sortie 0 si tout est conforme et 1 sinon. Le script ne modifie rien, à part des fichiers de test dans `/srv` et un dossier temporaire qu'il supprime en sortant.

## Analyse des journaux SSH

```
sudo analyse_logs.sh                       # dernières 24 h, seuil 10
sudo analyse_logs.sh -s 5 -d "2 hours ago"
sudo analyse_logs.sh -d today
```

Codes de sortie : 0 normal, 1 erreur d'usage, 2 alerte (une IP a atteint le seuil d'échecs). Le compte `support` ne peut lancer en root que ce script.

## Sauvegardes

Elles tournent toutes les nuits à 2 h (`sauvegarde.timer`, rattrapée au démarrage si la VM était éteinte). Pour en lancer une à la main :

```
sudo systemctl start sauvegarde.service
journalctl -t sauvegarde
ls -l /sauvegardes
```

La procédure de restauration est dans DOSSIER.md, partie 4.

## Audits (bonus)

Lynis et ssh-audit ne sont pas installés par `installer.sh` : ce sont des outils de contrôle, pas des services du serveur. Les résultats et les choix sont dans DOSSIER.md, annexe C.

```
sudo apt install lynis
sudo lynis audit system --quick
sudo grep '^hardening_index\|^suggestion' /var/log/lynis-report.dat
ssh-audit 192.168.65.5        # depuis la Kali
```

## Débannir une IP

```
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <IP de la Kali>
```
