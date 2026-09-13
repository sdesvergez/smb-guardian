# smb-guardian

Service macOS (LaunchAgent) qui monte, surveille et restaure automatiquement
un point de montage SMB vers un NAS Unifi Pro.

## Fonctionnement

- **Verification periodique** : toutes les `CHECK_INTERVAL` secondes (30s par
  defaut), le script controle que le point de montage existe et repond
  reellement (pas seulement qu'il apparait dans la liste des montages - un
  montage "stale" reste souvent visible mais bloque toute lecture).
- **Reaction aux evenements systeme** : le LaunchAgent utilise `WatchPaths`
  pour declencher une verification immediate des qu'un changement reseau est
  detecte (Wi-Fi, Ethernet, DNS), ce qui couvre la plupart des cas de reveil
  du Mac ou de changement de reseau. Un ecart anormal entre deux executions
  periodiques (signe probable de mise en veille) est aussi journalise et
  declenche une verification immediate.
- **Restauration automatique** : en cas de montage absent ou bloque, le
  service force le demontage puis retente le montage jusqu'a
  `MAX_RETRIES` fois, avec un delai `RETRY_DELAY` entre les tentatives.
- **Notifications macOS natives** : une notification s'affiche a la
  deconnexion detectee, puis a la restauration reussie ou a l'echec final.
- **Integration Home Assistant (optionnelle)** : si `HA_WEBHOOK_URL` est
  renseigne dans la configuration, chaque evenement (deconnexion,
  restauration, echec) est aussi envoye en POST JSON a ce webhook - sur le
  meme principe que vos services `devrg-*` existants.

## Prerequis

- macOS (le service s'appuie sur `mount_smbfs`, `diskutil` et `launchd`,
  tous natifs).
- Le partage SMB doit deja etre accessible manuellement depuis ce Mac
  (memes identifiants) avant d'automatiser le montage.

## Installation

1. Decompressez l'archive puis, dans le Terminal :

   ```bash
   cd smb-guardian
   chmod +x install.sh
   ./install.sh
   ```

2. Le script vous demande l'hote du NAS, le nom du partage, l'utilisateur
   SMB et le point de montage (valeurs par defaut proposees entre
   crochets - Entree pour les accepter).

3. Il vous propose ensuite d'enregistrer le mot de passe SMB dans le
   Trousseau (voir section suivante - **etape essentielle**).

4. Le LaunchAgent est genere et charge automatiquement.

## Identifiants et Trousseau (Keychain)

Le service appelle `mount_smbfs -N`, qui **ne demande jamais** le mot de
passe de facon interactive (indispensable puisqu'il tourne en tache de
fond, sans terminal). Le mot de passe doit donc deja se trouver dans le
Trousseau macOS pour le couple utilisateur/serveur concerne.

Deux methodes :

### Methode A - recommandee (via le Finder)

1. Dans le Finder : **Cmd+K** (Se connecter au serveur).
2. Adresse : `smb://<utilisateur>@<nas-host>/<partage>`
3. Cochez **"Se souvenir de ce mot de passe dans mon trousseau"**.
4. Une fois monte manuellement une premiere fois, demontez le partage
   (le script s'occupera du montage automatique ensuite) - ou laissez-le
   monte, le service detectera qu'il est deja present.

Cette methode cree exactement le format d'entree Keychain que macOS
utilise en interne, donc `mount_smbfs` la retrouve toujours sans probleme.

### Methode B - automatique (via `install.sh` ou `security`)

`install.sh` propose de creer l'entree directement avec la commande
`security add-internet-password`. C'est plus rapide mais legerement plus
fragile (le type de protocole SMB doit correspondre exactement). Si le
montage automatique echoue apres cette methode, basculez sur la methode A.

Pour ajouter ou remplacer l'entree manuellement a tout moment :

```bash
security add-internet-password -a "<utilisateur>" -s "<nas-host>" -r "smb " \
    -D "network password" -w -T "/sbin/mount_smbfs" -U
```

## Configuration

Le fichier de log est rote automatiquement au-dela de 5 Mo (une seule
sauvegarde `.old` conservee, pas de dependance externe type `logrotate`).

Fichier : `~/.config/smb-guardian/smb-guardian.conf`

| Variable | Role |
|---|---|
| `NAS_HOST` | Hote ou IP du NAS Unifi |
| `SMB_SHARE` | Nom du partage SMB |
| `SMB_USER` | Utilisateur SMB (doit correspondre au Trousseau) |
| `MOUNT_POINT` | Dossier local de montage |
| `CHECK_INTERVAL` | Frequence de verification (secondes) |
| `MAX_RETRIES` | Tentatives de remontage avant abandon temporaire |
| `RETRY_DELAY` | Delai entre deux tentatives (secondes) |
| `STALE_TIMEOUT` | Timeout pour detecter un montage bloque (secondes) |
| `NOTIFICATIONS_ENABLED` | Notifications macOS natives (true/false) |
| `HA_WEBHOOK_URL` | Webhook Home Assistant optionnel |
| `LOG_FILE` | Emplacement du fichier de log |

Apres modification, relancez une verification immediate :

```bash
launchctl kickstart -k gui/$(id -u)/eu.devrg.smbguardian
```

Si vous changez `CHECK_INTERVAL`, reinstallez le LaunchAgent (`./install.sh`
regenere le plist avec la nouvelle valeur) pour que le `StartInterval`
soit mis a jour.

## Commandes utiles

```bash
# Suivre les logs en direct
tail -f ~/Library/Logs/smb-guardian.log

# Forcer une verification immediate
launchctl kickstart -k gui/$(id -u)/eu.devrg.smbguardian

# Etat du service
launchctl list | grep eu.devrg.smbguardian

# Arreter temporairement
launchctl unload ~/Library/LaunchAgents/eu.devrg.smbguardian.plist

# Redemarrer
launchctl load -w ~/Library/LaunchAgents/eu.devrg.smbguardian.plist
```

## Desinstallation

```bash
chmod +x uninstall.sh
./uninstall.sh
```

L'entree du Trousseau n'est pas supprimee automatiquement (retrait manuel
via l'app Trousseaux d'acces si besoin).

## Depannage

- **Le montage automatique ne fonctionne jamais** : verifiez que le mot de
  passe est bien dans le Trousseau pour le bon couple utilisateur/serveur
  (methode A ci-dessus est la plus fiable). Testez manuellement :
  `mount_smbfs -N "//utilisateur@nas-host/partage" /tmp/test-mount`.
- **Le service ne se declenche jamais** : `launchctl list | grep
  eu.devrg.smbguardian` doit afficher une ligne. Sinon, relancez
  `./install.sh`.
- **Montage "stale" jamais detecte** : reduisez `STALE_TIMEOUT` si votre
  reseau est rapide, ou augmentez-le si le NAS repond lentement sous
  charge.
- **Logs** : `~/Library/Logs/smb-guardian.log` (logique du script) et
  `~/Library/Logs/smb-guardian.launchd.log` (sortie standard/erreurs de
  launchd, utile en cas de plantage du script lui-meme).

## Limites connues

- La detection du reveil du Mac est approximative : elle repose sur les
  changements de configuration reseau (`WatchPaths`) et sur l'ecart de
  temps entre deux executions periodiques, et non sur une vraie
  notification systeme de reveil (`IOKit`/`NSWorkspace`). Dans la grande
  majorite des cas, cela suffit a restaurer le montage en quelques dizaines
  de secondes apres un reveil. Une version future pourrait ajouter un
  petit binaire Swift ecoutant les notifications de reveil natives si un
  delai plus court s'avere necessaire.
