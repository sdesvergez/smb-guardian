#!/bin/bash
# ==========================================================
# uninstall.sh - Desinstallation du service smb-guardian
# ==========================================================

set -uo pipefail

PLIST_LABEL="eu.devrg.smbguardian"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_DEST="$HOME/.local/bin/smb-guardian.sh"
CONFIG_DIR="$HOME/.config/smb-guardian"

echo "Arret et desenregistrement du LaunchAgent..."
launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"

echo "Suppression du script..."
rm -f "$SCRIPT_DEST"

read -r -p "Supprimer aussi la configuration ($CONFIG_DIR) ? [o/N] " del_config
if [[ "${del_config:-}" =~ ^[oOyY]$ ]]; then
    rm -rf "$CONFIG_DIR"
    echo "Configuration supprimee."
else
    echo "Configuration conservee : $CONFIG_DIR"
fi

echo
echo "Le service est desinstalle."
echo "Note : l'entree du Trousseau (Keychain) n'est PAS supprimee automatiquement."
echo "Pour la retirer manuellement : Trousseaux d'acces > rechercher le nom du NAS."
