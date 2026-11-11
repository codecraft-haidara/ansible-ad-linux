# Intégration des serveurs Linux au domaine `finance.mef`

Rôle Ansible `ad_linux` : jonction à Active Directory (realmd, SSSD), contrôle d'accès
par groupes AD, création des répertoires personnels, sudoers des administrateurs et
droits restreints des DBA. Le rôle est idempotent : un second passage ne donne aucun `changed`.

Systèmes pris en charge : Debian, Ubuntu (y compris 25.10 et 26.04 avec sudo-rs), RHEL 8 et 9.

## Prérequis

Sur le poste de contrôle :

```bash
pip install ansible-core
```

```bash
ansible-galaxy collection install -r requirements.yml
```

Sur chaque serveur cible :

- accès SSH avec un compte ayant sudo ;
- DNS pointant vers les contrôleurs de domaine (guepard 10.10.1.18, guepard-01 10.10.1.27,
  guepard-02 10.10.1.37) ;
- horloge synchronisée par NTP (Kerberos tolère 5 minutes d'écart) ;
- nom court de 15 caractères au plus (limite NetBIOS) et FQDN en `.finance.mef`.

Côté AD : un compte de jonction ayant le droit de créer des objets ordinateur dans l'OU
visée. Le compte actuel est `al.haidara` ; un compte de service dédié, limité à cette
délégation, est préférable à un compte nominatif.

## Mot de passe de jonction (vault)

Le mot de passe n'est jamais écrit en clair ni affiché (`no_log`). Créer le vault :

```bash
ansible-vault create inventory/group_vars/all/vault.yml
```

et y mettre (modèle : `inventory/group_vars/all/vault.yml.example`) :

```yaml
vault_ad_join_password: "le mot de passe du compte de jonction"
vault_radius_secret: "le secret partagé RADIUS"
vault_emergency_password: "le mot de passe initial du compte de secours"
```

Pour compléter un vault existant :

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
```

## Lancement

Toujours commencer par **un seul serveur**, en gardant **une session root ouverte** sur ce
serveur pendant le premier passage : si le contrôle d'accès SSSD ou un sudoers est mal
réglé, cette session permet de corriger sans rester enfermé dehors.

```bash
ansible-playbook playbooks/ad_linux.yml --limit bison-01 --ask-become-pass --ask-vault-pass
```

Puis le reste du parc :

```bash
ansible-playbook playbooks/ad_linux.yml --ask-become-pass --ask-vault-pass
```

Relancer une seule partie, par exemple le contrôle d'accès SSSD :

```bash
ansible-playbook playbooks/ad_linux.yml --limit bison-08 --tags sssd --ask-become-pass
```

Les droits DBA / PostgreSQL sont **désactivés** dans l'inventaire fourni
(`dba_enabled: false` par défaut). Le rôle les gère toujours : pour les activer plus
tard, définir `dba_enabled: true` et `dba_group` pour les hôtes concernés.

## Inventaire

| Fichier | Rôle |
|---|---|
| `inventory/hosts.yml` | groupe `linux_ad` (tous les serveurs) |
| `inventory/group_vars/all/main.yml` | domaine, compte de jonction, groupes admins |
| `inventory/group_vars/all/vault.yml` | mot de passe de jonction, chiffré |
| `inventory/host_vars/<hôte>.yml` | groupes de connexion et comptes de test propres à un hôte |

## Variables

| Variable | Défaut | Description |
|---|---|---|
| `ad_domain` | `finance.mef` | Domaine AD |
| `ad_join_user` | `""` | Compte de jonction |
| `ad_join_password` | `vault_ad_join_password` | Mot de passe, fourni par le vault |
| `ad_computer_ou` | `""` | OU des objets ordinateur ; vide = conteneur par défaut |
| `ad_require_ntp_sync` | `true` | Refuser de continuer si l'horloge n'est pas synchronisée |
| `ad_use_fully_qualified_names` | `true` | Connexion en `utilisateur@finance.mef` ; ajoute `@finance.mef` aux groupes dans sudoers |
| `ad_admin_groups` | `[]` | Groupes AD : connexion + `ALL=(ALL:ALL) ALL` |
| `ad_host_login_groups` | `[]` | Groupes AD autorisés à se connecter, sans sudo |
| `ad_force_classic_sudo` | `true` | Ubuntu 25.10+ : basculer `sudo` de sudo-rs vers `/usr/bin/sudo.ws` |
| `ad_verify_users` | `[]` | Comptes pour lesquels afficher `id` et `sudo -l -U` |
| `dba_enabled` | `false` | Appliquer les droits DBA ; `false` supprime `/etc/sudoers.d/dba` |
| `dba_group` | `""` | Groupe AD des DBA |
| `dba_service_commands` | restart et reload de postgresql | Commandes de service exactes |
| `dba_run_as_users` | `[postgres]` | Comptes moteurs que les DBA peuvent endosser (oracle, mysql...) |
| `dba_pkg_mode` | `auto` | `auto`, `regex`, `list` ou `none` (voir plus bas) |
| `dba_pkg_whitelist` | `[]` | Paquets autorisés en mode `list` |
| `dba_io_logging` | `true` | `log_input, log_output` pour les DBA, si le sudo le permet |
| `dba_backup_dir` | `/var/backups/postgresql` | Répertoire de sauvegarde (mode 2770) |
| `dba_backup_owner` | `postgres` | Propriétaire du répertoire |

Les groupes autorisés à se connecter sont : `ad_admin_groups`, plus `dba_group` si
`dba_enabled`, plus `ad_host_login_groups`.

Les noms de groupes sont écrits **en minuscules** dans sudoers et sssd, quelle que soit
la casse donnée : SSSD renvoie les noms AD en minuscules et sudo respecte la casse. Les
espaces sont échappés (`\ `) dans sudoers.

### Second facteur SSH par RADIUS (FortiAuthenticator)

| Variable | Défaut | Description |
|---|---|---|
| `radius_enabled` | `false` | Activer le second facteur RADIUS pour SSH (Debian/Ubuntu seulement) |
| `radius_server` | `""` | Adresse du FortiAuthenticator |
| `radius_port` | `1812` | Port RADIUS |
| `radius_secret` | `vault_radius_secret` | Secret partagé, fourni par le vault |
| `radius_timeout` | `5` | Délai de réponse en secondes |
| `radius_source_ip` | `""` | Adresse source des requêtes, pour un serveur à plusieurs interfaces |
| `radius_bypass_group` | `noradius` | Groupe local dont les membres se connectent sans RADIUS |
| `radius_bypass_users` | `[]` | Comptes à mettre dans ce groupe (locaux, ou AD en minuscules) |
| `radius_emergency_user` | `emergency_account` | Compte local de secours (sudo, exempté) ; vide = ne pas le créer |
| `radius_emergency_password` | `vault_emergency_password` | Mot de passe initial du compte de secours, posé à la création seulement |

Déroulement d'une connexion SSH : mot de passe (local ou AD), puis RADIUS. Les membres de
`noradius` s'arrêtent au mot de passe. Si le FortiAuthenticator ne répond pas, tous les
autres comptes sont **refusés** : c'est le rôle du compte de secours.

Avant d'activer RADIUS sur un serveur :

- le déclarer comme client RADIUS sur le FortiAuthenticator, avec le même secret ;
- vérifier qu'il joint le FortiAuthenticator en UDP 1812 ;
- mettre dans `radius_bypass_users` le compte utilisé par Ansible s'il se connecte par
  mot de passe (une connexion par clé SSH ne passe pas par RADIUS).

Un serveur où RADIUS a déjà été configuré à la main (ligne `pam_radius_auth.so` active
dans `/etc/pam.d/sshd`, sans le repère du rôle) n'est pas modifié : le rôle y assure
seulement le groupe `noradius` et le compte de secours.

Le rôle ne remplace pas `sshd_config` : il y ajoute en tête `UsePAM`,
`KbdInteractiveAuthentication` et `ChallengeResponseAuthentication` à `yes`. Il ne touche
ni à `PermitRootLogin` ni à `PasswordAuthentication`.

### Installation de paquets par les DBA (`dba_pkg_mode`)

| Mode | Effet |
|---|---|
| `regex` | `apt-get update` et `apt-get ^install( -y)?( <nom>)+$`. Demande le sudo classique ≥ 1.9.10 |
| `list` | `apt-get update` et, pour chaque paquet de `dba_pkg_whitelist`, `apt-get install <paquet>` avec ou sans `-y` |
| `none` | aucune installation |
| `auto` | `regex` si le sudo le permet, sinon `list` si la liste n'est pas vide, sinon `none` |

Sur RHEL, la commande est `dnf` (et `dnf makecache`). RHEL 8 et 9 ont un sudo antérieur
à 1.9.10 : le mode `auto` y retombe sur `list` ou `none`.

En mode regex, un nom de paquet ne peut ni commencer par `-` (aucune option, donc pas de
`-o APT::Update::Pre-Invoke::=/bin/sh`) ni, sur Debian, finir par `-` (`apt-get install
paquet-` désinstalle le paquet). Aucun joker `*` n'est jamais écrit dans les arguments.

## Tags

| Tag | Ce qu'il fait |
|---|---|
| `preflight` | OS pris en charge, nom court ≤ 15, NTP ; avertissement si le FQDN est hors domaine |
| `packages` | Installation de realmd, sssd, adcli, etc. |
| `join` | `realm join` si le domaine n'est pas déjà joint |
| `sssd`, `access` | `access_provider = simple`, groupes autorisés, `use_fully_qualified_names` ; vidage du cache et redémarrage de sssd si changement |
| `mkhomedir` | `pam-auth-update --enable mkhomedir` (Debian) ; `authselect` + oddjobd (RHEL) |
| `sudo` | Bascule vers le sudo classique, `/etc/sudoers.d/ad-groups` |
| `dba` | `/etc/sudoers.d/dba`, apt-listchanges, répertoire de sauvegarde |
| `radius` | Compte de secours, groupe `noradius`, module PAM RADIUS, second facteur dans la pile PAM de sshd |
| `verify` | `realm list`, `visudo -c`, `id` et `sudo -l -U` des comptes de test |

## Dépannage

### Jonction : `000021C7` (affiché « Insufficient permissions »)

Le message est trompeur : ce n'est **pas** un problème de droits. `000021C7` signifie
qu'un SPN existe déjà ailleurs dans la forêt (domaines enfants datacenter, mefaci, dgdp
compris), souvent un ancien objet ordinateur du même nom. Sur un DC :

```
setspn -F -Q */<nom-du-serveur>*
```

Supprimer ou corriger l'objet en conflit, puis relancer avec `--tags join`. Le rôle
détecte ce cas et affiche cette commande.

### Jonction : « Insufficient permissions » sans `000021C7`

Vérifier, dans l'ordre :

1. la délégation du compte de jonction sur l'OU (`ad_computer_ou`) ;
2. `ms-DS-MachineAccountQuota` (10 par défaut ; un compte sans délégation est limité par ce quota) ;
3. un objet ordinateur du même nom déjà existant, créé par un autre compte.

Le détail d'adcli est affiché par le rôle ; voir aussi `journalctl -u realmd` sur le serveur.

### sudo-rs (Ubuntu 25.10 et suivants)

`/usr/bin/sudo` y pointe vers sudo-rs, qui ne gère ni `log_input`/`log_output` ni les
regex. Avec `ad_force_classic_sudo: true`, le rôle bascule l'alternative `sudo` vers
`/usr/bin/sudo.ws`. Pour vérifier :

```bash
sudo -V | head -1
```

« Sudo version 1.9.x » : sudo classique. « sudo-rs x.y » : sudo-rs. Si sudo-rs reste actif
(`ad_force_classic_sudo: false` ou `sudo.ws` absent), le rôle n'écrit ni regex ni
journalisation, et le mode `regex` demandé explicitement est refusé.

### « Timeout (12s) waiting for privilege escalation prompt »

sudo a mis trop de temps à répondre, souvent juste après la jonction, quand SSSD démarre.
`ansible.cfg` porte le délai à 60 secondes ; relancer simplement le playbook, il reprend
là où il s'est arrêté. Si Ansible ignore `ansible.cfg` (dépôt sous `/mnt/c` dans WSL),
faire `export ANSIBLE_CONFIG="$PWD/ansible.cfg"` ou cloner le dépôt dans `~`.

### Connexion SSH refusée après l'activation de RADIUS

- le compte n'est pas connu du FortiAuthenticator, ou le serveur n'y est pas déclaré
  comme client RADIUS ;
- le FortiAuthenticator est injoignable : se connecter avec le compte de secours ;
- serveur à plusieurs interfaces : fixer `radius_source_ip` dans `host_vars/<hôte>.yml`.

### Un utilisateur AD ne peut pas se connecter

- `id utilisateur@finance.mef` : le compte est-il résolu, avec ses groupes ?
- est-il membre d'un groupe de `simple_allow_groups` dans `/etc/sssd/sssd.conf` ?
- après un changement de groupe dans l'AD : `sss_cache -E`.

### `sudo -l` ne montre pas les droits attendus

Comparer le nom du groupe renvoyé par `id` avec celui écrit dans `/etc/sudoers.d/` : il
doit être identique, minuscules et suffixe `@finance.mef` compris.

## Tests

Rendu des deux templates dans tous les modes (regex, list, none ; fqdn True et False ;
Debian et RedHat), chaque rendu validé par `visudo -cf`. Ne modifie pas le système :

```bash
ansible-playbook tests/render_sudoers.yml
```

Test réel du volet sudo/DBA avec des groupes et utilisateurs locaux. **À lancer en root
sur une machine jetable** (il crée des comptes et écrit dans `/etc/sudoers.d/`) :

```bash
sudo bash tests/test_local_sudo.sh
```

Contrôle de qualité :

```bash
ansible-lint
```

## Limites connues

- `ALL=(postgres) ALL` donne aux DBA le compte `postgres` en entier : c'est voulu
  (sauvegardes, `sudo -iu postgres`), et les sessions sont journalisées.
- Lors d'un `apt-get install`, dpkg peut demander quoi faire d'un fichier de configuration
  modifié ; ce dialogue propose l'option `Z` (ouvrir un shell), qui s'exécute en root. Le
  rôle ne modifie pas ce comportement. Pour le fermer, ajouter `force-confdef` et
  `force-confold` dans `/etc/dpkg/dpkg.cfg.d/`, ce qui change aussi le comportement pour
  les administrateurs.
