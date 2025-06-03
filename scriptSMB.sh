#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14"
SHARE="DESKTOP-V3LBNSU"
# ATTENTION : NEXTCLOUD_MOUNT_POINT sera utilisé comme le point de montage interne ET le nom affiché.
# Nextcloud affichera un dossier nommé "MesFichiersSMBTest" directement à la racine des fichiers de l'utilisateur.
NEXTCLOUD_MOUNT_POINT="/MesFichiersSMBTest" 
# NEXTCLOUD_LABEL n'est plus utilisé comme argument séparé dans create, mais pour la cohérence des messages.
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test (alias MesFichiersSMBTest)" 

DOMAIN="" # Laissez vide si pas de domaine Active Directory spécifique

# Chemin absolu vers votre installation Nextcloud
NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data" # L'utilisateur sous lequel Nextcloud tourne
# ==============================================================

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_HOST"
echo "Partage SMB fixe sur PC   : \\\\$SMB_HOST\\$SHARE"
echo "Point de montage interne  : $NEXTCLOUD_MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_MOUNT_POINT (sera identique au point de montage)"
echo "------------------------------------------------"

# Vérification de la version de jq
echo "Version de jq : $(jq --version)"

# Récupérer tous les utilisateurs Nextcloud sauf les systèmes
users=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # Récupérer la sortie brute de occ files_external:list pour éviter de la réexécuter
    OCC_LIST_OUTPUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json)

    # Vérifier si un montage existe déjà pour cet utilisateur
    # Le filtre jq utilise NEXTCLOUD_MOUNT_POINT comme le nom affiché (mount_point)
    MOUNT_EXISTS=$(echo "$OCC_LIST_OUTPUT" | \
                   jq -r --arg user_id "$user" --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" \
                   '[.[] | select(.backend == "smb" and .mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id and (.applicable_users | contains([$user_id])))] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "✅ Montage SMB déjà existant pour $user."
        continue
    fi

    echo "Aucun montage SMB trouvé. Création en cours..."

    # Créer le montage SMB - SYNTAXE ADAPTÉE À VOTRE OCC
    # Le premier argument est le mount_point (nom affiché et chemin interne)
    # Plus d'option --mount-point séparée.
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
        "$NEXTCLOUD_MOUNT_POINT" \
        smb \
        password::logincredentials \
        --config "host=$SMB_HOST" \
        --config "share=$SHARE" \
        --config "subfolder=$user" \
        --applicable-users "$user" \
        --option "enable_sharing=true" \
        --option "save_login_credentials=true"

    # Récupérer l'ID du montage après création
    # Le filtre jq utilise NEXTCLOUD_MOUNT_POINT comme le nom affiché (mount_point)
    id=$(echo "$OCC_LIST_OUTPUT" | \
         jq -r --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg user_id "$user" \
         '.[] | select(.mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id and (.applicable_users | contains([$user_id]))) | .id')

    if [[ -z "$id" ]]; then
        echo "❌ Erreur : impossible de récupérer l'ID du montage SMB pour $user après création."
        echo "Vérifiez les journaux Nextcloud (Interface Admin > Journaux) et les sorties du script."
        echo "Assurez-vous que le chemin '\\\\$SMB_HOST\\$SHARE\\$user' existe sur le serveur SMB et que les permissions sont correctes."
        continue
    fi

    echo "✅ Montage configuré pour l'utilisateur $user (ID: $id)."
done

echo "--- Fin du script d'automatisation SMB ---"