#!/bin/bash
# ==========================================================
# smb-guardian.sh
# Monte, surveille et restaure automatiquement un point de
# montage SMB (NAS Unifi Pro) sur macOS.
#
# Concu pour etre lance par launchd (LaunchAgent), en polling
# periodique ET en reaction aux changements reseau (WatchPaths).
# ==========================================================

set -uo pipefail

# --- Chargement de la configuration -----------------------------------

CONFIG_FILE="${SMB_GUARDIAN_CONFIG:-$HOME/.config/smb-guardian/smb-guardian.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Fichier de configuration introuvable : $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Valeurs par defaut si absentes du fichier de config
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
STALE_TIMEOUT="${STALE_TIMEOUT:-5}"
NOTIFICATIONS_ENABLED="${NOTIFICATIONS_ENABLED:-true}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/smb-guardian.log}"

STATE_DIR="$HOME/.local/state/smb-guardian"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
LAST_RUN_FILE="$STATE_DIR/last_run"

# --- Fonctions utilitaires ----------------------------------------------

rotate_log_if_needed() {
    # Rotation simple basee sur la taille (pas de logrotate dedie ici) :
    # au-dela de 5 Mo, on garde une seule sauvegarde .old
    local max_bytes=$((5 * 1024 * 1024))
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if (( size > max_bytes )); then
            mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
        fi
    fi
}

log() {
    # $1 = niveau (INFO/WARN/ERROR/DEBUG), $2 = message
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
}

notify() {
    # Notification macOS native, silencieuse si NOTIFICATIONS_ENABLED=false
    [[ "$NOTIFICATIONS_ENABLED" == "true" ]] || return 0
    local title="$1" message="$2"
    /usr/bin/osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"Basso\"" \
        >/dev/null 2>&1 &
}

push_ha() {
    # Envoie un evenement a Home Assistant si HA_WEBHOOK_URL est configure
    [[ -n "${HA_WEBHOOK_URL:-}" ]] || return 0
    local event="$1" detail="$2"
    curl -s -m 5 -X POST "$HA_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"event\":\"${event}\",\"mount_point\":\"${MOUNT_POINT}\",\"detail\":\"${detail}\",\"source\":\"smb-guardian\"}" \
        >/dev/null 2>&1 &
}

run_with_timeout() {
    # macOS ne fournit pas `timeout` de base -> implementation maison.
    # Usage : run_with_timeout <secondes> <commande...>
    local timeout_sec="$1"; shift
    "$@" &
    local cmd_pid=$!
    ( sleep "$timeout_sec"; kill -9 "$cmd_pid" 2>/dev/null ) &
    local watcher_pid=$!
    wait "$cmd_pid" 2>/dev/null
    local status=$?
    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null
    return $status
}

detect_wake_gap() {
    # Si l'ecart depuis la derniere execution est bien superieur a
    # l'intervalle attendu, le Mac sortait probablement de veille ou
    # d'une coupure reseau : on le journalise (la verification qui suit
    # se declenche de toute facon immediatement).
    local now last gap
    now=$(date +%s)
    if [[ -f "$LAST_RUN_FILE" ]]; then
        last=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "$now")
        gap=$(( now - last ))
        if (( gap > CHECK_INTERVAL * 3 )); then
            log "INFO" "Ecart de ${gap}s depuis la derniere execution (reveil ou coupure reseau probable) - verification immediate"
        fi
    fi
    echo "$now" > "$LAST_RUN_FILE"
}

is_mount_present() {
    /sbin/mount | grep -qF " on ${MOUNT_POINT} "
}

is_mount_healthy() {
    is_mount_present || return 1
    run_with_timeout "$STALE_TIMEOUT" ls "$MOUNT_POINT" >/dev/null 2>&1
}

force_unmount() {
    log "WARN" "Demontage force de $MOUNT_POINT"
    /usr/sbin/diskutil unmount force "$MOUNT_POINT" >/dev/null 2>&1
    /sbin/umount -f "$MOUNT_POINT" >/dev/null 2>&1
    return 0
}

mount_share() {
    mkdir -p "$MOUNT_POINT"

    # Si SMB_USER est vide, on monte sans utilisateur dans l'URL - c'est le
    # cas si l'entree Trousseau a ete enregistree sans compte explicite
    # (verifiable avec : security find-internet-password -s "$NAS_HOST").
    # On ne tente qu'UNE seule forme : un essai qui echoue perturbe la
    # session SMB partagee avec le serveur et peut deconnecter les autres
    # partages montes depuis le meme NAS.
    local smb_url
    if [[ -n "$SMB_USER" ]]; then
        smb_url="//${SMB_USER}@${NAS_HOST}/${SMB_SHARE}"
    else
        smb_url="//${NAS_HOST}/${SMB_SHARE}"
    fi

    log "INFO" "Tentative de montage de ${smb_url} sur ${MOUNT_POINT}"
    run_with_timeout 15 /sbin/mount_smbfs -N "$smb_url" "$MOUNT_POINT" 2>>"$LOG_FILE"
}

attempt_restore() {
    local attempt=1
    while (( attempt <= MAX_RETRIES )); do
        log "INFO" "Tentative de restauration ${attempt}/${MAX_RETRIES}"
        is_mount_present && force_unmount
        if mount_share && is_mount_healthy; then
            log "INFO" "Montage restaure avec succes"
            notify "NAS Unifi" "Le partage ${SMB_SHARE} a ete remonte avec succes."
            push_ha "restored" "success after ${attempt} attempt(s)"
            return 0
        fi
        attempt=$(( attempt + 1 ))
        (( attempt <= MAX_RETRIES )) && sleep "$RETRY_DELAY"
    done
    log "ERROR" "Echec de restauration apres ${MAX_RETRIES} tentatives"
    notify "NAS Unifi - Erreur" "Impossible de remonter ${SMB_SHARE} apres ${MAX_RETRIES} tentatives."
    push_ha "restore_failed" "failed after ${MAX_RETRIES} attempts"
    return 1
}

main() {
    rotate_log_if_needed
    detect_wake_gap

    if is_mount_healthy; then
        log "DEBUG" "Montage OK (${MOUNT_POINT})"
        exit 0
    fi

    log "WARN" "Montage absent ou bloque : ${MOUNT_POINT}"
    notify "NAS Unifi" "Connexion au NAS perdue - tentative de restauration..."
    push_ha "disconnected" "mount missing or stale"
    attempt_restore
}

main "$@"
