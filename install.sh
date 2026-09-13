#!/bin/bash
# ==========================================================
# install.sh - Installation du service smb-guardian (macOS)
# ==========================================================
# A executer depuis le dossier decompresse, dans le Terminal :
#   chmod +x install.sh && ./install.sh
#
# Ce script :
#  1. copie le script et la configuration a leur emplacement final
#  2. genere le LaunchAgent (launchd) a partir du modele fourni
#  3. propose d'enregistrer les identifiants SMB dans le Trousseau
#  4. charge le service
# ==========================================================

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/smb-guardian"
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"

SCRIPT_DEST="$BIN_DIR/smb-guardian.sh"
CONFIG_DEST="$CONFIG_DIR/smb-guardian.conf"
PLIST_LABEL="eu.devrg.smbguardian"
PLIST_DEST="$LAUNCHAGENTS_DIR/${PLIST_LABEL}.plist"

echo "=== Installation de smb-guardian ==="
echo

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LAUNCHAGENTS_DIR" "$LOG_DIR"

# --- 1. Script principal -------------------------------------------------
cp "$SRC_DIR/smb-guardian.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
echo "Script installe : $SCRIPT_DEST"

# --- 2. Configuration ------------------------------------------------------
if [[ -f "$CONFIG_DEST" ]]; then
    echo "Configuration existante conservee : $CONFIG_DEST"
else
    cp "$SRC_DIR/smb-guardian.conf" "$CONFIG_DEST"
    echo "Configuration copiee : $CONFIG_DEST"
    echo
    echo "--- Configuration rapide (laisser vide pour garder la valeur par defaut) ---"

    read -r -p "Hote ou IP du NAS Unifi [unifi-nas.local] : " nas_host
    read -r -p "Nom du partage SMB [backup] : " smb_share
    read -r -p "Utilisateur SMB [$USER] : " smb_user
    read -r -p "Point de montage local [$HOME/NAS-Unifi] : " mount_point
    read -r -p "Intervalle de verification en secondes [30] : " check_interval

    nas_host="${nas_host:-unifi-nas.local}"
    smb_share="${smb_share:-backup}"
    smb_user="${smb_user:-$USER}"
    mount_point="${mount_point:-$HOME/NAS-Unifi}"
    check_interval="${check_interval:-30}"

    # Echappement leger pour l'usage dans sed (les valeurs contiennent
    # rarement des caracteres speciaux, mais on reste prudent)
    esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

    sed -i '' \
        -e "s/^NAS_HOST=.*/NAS_HOST=\"$(esc "$nas_host")\"/" \
        -e "s/^SMB_SHARE=.*/SMB_SHARE=\"$(esc "$smb_share")\"/" \
        -e "s/^SMB_USER=.*/SMB_USER=\"$(esc "$smb_user")\"/" \
        -e "s|^MOUNT_POINT=.*|MOUNT_POINT=\"$(esc "$mount_point")\"|" \
        -e "s/^CHECK_INTERVAL=.*/CHECK_INTERVAL=$check_interval/" \
        "$CONFIG_DEST"

    echo "Configuration ecrite dans $CONFIG_DEST (modifiable a tout moment)"
fi

# shellcheck source=/dev/null
source "$CONFIG_DEST"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

# --- 3. Trousseau (Keychain) ------------------------------------------------
echo
echo "--- Identifiants SMB dans le Trousseau ---"
echo "Le service utilise 'mount_smbfs -N', qui ne demande jamais le mot de"
echo "passe : celui-ci doit deja etre enregistre dans le Trousseau macOS pour"
echo "le couple utilisateur/serveur (${SMB_USER}@${NAS_HOST})."
echo
echo "Deux methodes possibles (voir README.md pour le detail) :"
echo "  A. Recommandee : dans le Finder, Cmd+K -> smb://${SMB_USER}@${NAS_HOST}/${SMB_SHARE}"
echo "     puis cocher 'Se souvenir de ce mot de passe dans mon trousseau'."
echo "  B. Automatique : ce script peut ajouter l'entree maintenant via 'security'."
echo
read -r -p "Ajouter l'entree maintenant avec 'security' ? [o/N] " add_keychain
if [[ "${add_keychain:-}" =~ ^[oOyY]$ ]]; then
    read -r -s -p "Mot de passe SMB pour ${SMB_USER}@${NAS_HOST} : " smb_password
    echo
    security add-internet-password -a "$SMB_USER" -s "$NAS_HOST" -r "smb " \
        -D "network password" -w "$smb_password" -T "/sbin/mount_smbfs" -U
    unset smb_password
    echo "Entree ajoutee/mise a jour dans le Trousseau de connexion."
    echo "Verification :"
    if security find-internet-password -a "$SMB_USER" -s "$NAS_HOST" -r "smb " >/dev/null 2>&1; then
        echo "  OK - l'entree est bien retrouvable."
    else
        echo "  ATTENTION : l'entree n'a pas ete retrouvee avec ces parametres."
        echo "  Utilisez la methode A (Finder) en cas de probleme de montage."
    fi
else
    echo "Ok, pensez a enregistrer le mot de passe via le Finder avant le premier lancement."
fi

# --- 4. LaunchAgent ----------------------------------------------------------
echo
echo "--- Installation du LaunchAgent ---"

sed \
    -e "s|__SCRIPT_PATH__|$SCRIPT_DEST|g" \
    -e "s|__CHECK_INTERVAL__|$CHECK_INTERVAL|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$SRC_DIR/${PLIST_LABEL}.plist" > "$PLIST_DEST"

echo "LaunchAgent genere : $PLIST_DEST"

launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST_DEST"
echo "Service charge et actif (verification toutes les ${CHECK_INTERVAL}s)."

echo
echo "=== Installation terminee ==="
echo "Config    : $CONFIG_DEST"
echo "Script    : $SCRIPT_DEST"
echo "LaunchAgent : $PLIST_DEST"
echo "Logs      : $LOG_DIR/smb-guardian.log et $LOG_DIR/smb-guardian.launchd.log"
echo
echo "Commandes utiles :"
echo "  Forcer une verification immediate :"
echo "    launchctl kickstart -k gui/\$(id -u)/${PLIST_LABEL}"
echo "  Suivre les logs en direct :"
echo "    tail -f $LOG_DIR/smb-guardian.log"
echo "  Arreter le service :"
echo "    launchctl unload $PLIST_DEST"
