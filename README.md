# XTI302-CYB : durcir un serveur Linux et le prouver

Contexte B du sujet (cabinet comptable), appliqué à l'entreprise Master Poulet.
Les groupes métier et les répertoires de `/srv` gardent les noms du sujet :
`comptables`, `rh`, `direction`, `stagiaire`.

Groupe : Clément, Lucas et Aymeric.

| Membre | Partie |
|---|---|
| Clément | comptes, ACL, sudo, sauvegardes (`comptes.csv`, `creer_comptes.sh`, `config/sudoers.d`, `sauvegarde.sh`, `config/systemd`) |
| Lucas | SSH, fail2ban, nftables, journaux, système, installation (`config/ssh`, `config/fail2ban`, `config/nftables.conf`, `analyse_logs.sh`, `config/apt`, `installer.sh`) |
| tous | `verifier.sh`, `DOSSIER.md` |

Le rapport est dans [DOSSIER.md](DOSSIER.md).

## Prérequis

- VM Debian 13 (trixie) installée en minimal : sans bureau, avec « serveur SSH » et « utilitaires usuels du système ».
- Un second disque virtuel de 1 à 2 Go, vierge, pour les sauvegardes. `installer.sh` le repère tout seul (disque de 1 à 3 Gio qui ne porte pas la racine et dont rien n'est monté) et ne le formate que s'il ne contient aucune signature.
- Réseau : chez nous la VM `debian13-masterpoulet` et la Kali sont sur le NAT Network VirtualBox `xti302` (192.168.65.0/24). Une redirection de port 2222 de l'hôte vers le port 22 de la VM sert à l'administration depuis Windows. La Kali sert de poste d'attaque avec sa propre IP.
- Un snapshot `vierge` pris juste après l'installation.

## Installation

Copier le dépôt sur la VM (le dépôt est privé, on ne met pas de jeton sur le serveur) :

```
tar -cf - . | ssh -p 2222 installeur@127.0.0.1 "mkdir -p /tmp/xti302 && tar -xf - -C /tmp/xti302"
```

Puis sur la VM :

```
sudo /tmp/xti302/installer.sh --secrets /root/secrets_admins
```

`--secrets` donne les mots de passe des administrateurs qui n'en ont pas encore, au format `chpasswd` (`login:motdepasse`). Ce fichier n'est jamais dans le dépôt : on le copie en `/root` en mode 600 et on le supprime avec `shred -u` après l'installation. Sans `--secrets`, le script demande les mots de passe si on est sur un terminal ; sinon il s'arrête avant de verrouiller root, pour ne jamais se retrouver sans accès.

Le script est relançable : il ne recrée ni compte ni groupe, ne reformate jamais un disque qui a déjà un système de fichiers et ne touche pas aux sauvegardes existantes.

Après l'installation, la connexion se fait avec un compte admin et sa clé :

```
ssh -p 2222 -i ~/.ssh/xti302/clement clement@127.0.0.1
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

Codes de sortie : 0 normal, 1 erreur d'usage, 2 alerte (une IP a atteint le seuil d'échecs). Le compte `support` n'a le droit de lancer en root que ce script.

## Sauvegardes

Elles tournent toutes les nuits à 2 h (`sauvegarde.timer`, rattrapée au démarrage si la VM était éteinte). Pour en lancer une à la main :

```
sudo systemctl start sauvegarde.service     # ou : sudo sauvegarde.sh
journalctl -u sauvegarde.service -t sauvegarde
ls -l /sauvegardes
```

La procédure de restauration est dans DOSSIER.md, partie 4.

## Débannir une IP

```
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip 192.168.65.4
```
