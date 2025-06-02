#!/bin/bash
set -euo pipefail

NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data"

# --- PARAMÈTRES À ADAPTER POUR VOTRE TEST ---
SMB_SERVER_IP="192.168.135.14"          # IP du serveur SMB (ex: Windows)
SMB_SHARE_NAME_FIXED="DESKTOP-V3LBNSU"  # Nom du partage racine SMB (ex: nom de l'ordinateur Windows)
MOUNT_DISPLAY_NAME="Mon Dossier Personnel SMB Test"
MOUNT_POINT="/MesFichiersSMBTest"       # Nom affiché dans Nextcloud (virtuel)
# --------------------------------------------

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_SERVER_IP"
echo "Partage SMB fixe sur PC   : \\\\$SMB_SERVER_IP\\$SMB_SHARE_NAME_FIXED"
echo "Point de montage Nextcloud: $MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $MOUNT_DISPLAY_NAME"
echo "------------------------------------------------"

# Récupération de la liste des utilisateurs Nextcloud
USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$USERS" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for USER_ID in $USERS; do
    echo ""
    echo "-------------------------------------------"
    echo "Traitement de l'utilisateur : $USER_ID"

    # Vérifie si un montage SMB existe déjà
    MOUNT_EXISTS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$USER_ID" --output=json | \
        jq -r --arg user_id "$USER_ID" \
              --arg smb_server_ip "$SMB_SERVER_IP" \
              --arg smb_share_fixed "$SMB_SHARE_NAME_FIXED" \
              --arg mount_point "$MOUNT_POINT" \
              '[.[] | select(
                  .backend == "smb" and
                  .configuration.host == $smb_server_ip and
                  .configuration.share == $smb_share_fixed and
                  .configuration.subfolder == $user_id and
                  .mount_point == $mount_point and
                  (.applicable_users | contains([$user_id]))
              )] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo " Un montage SMB existe déjà pour cet utilisateur."
    else
        echo " Aucun montage SMB trouvé. Création en cours..."

        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
            "$MOUNT_DISPLAY_NAME" \
            smb \
            --config "host=$SMB_SERVER_IP,share=$SMB_SHARE_NAME_FIXED,subfolder=$USER_ID" \
            --applicable-users "$USER_ID" \
            --mount-point "$MOUNT_POINT" \
            --option "save_login_credentials=true" \
            --option "enable_sharing=true"

        if [ $? -eq 0 ]; then
            echo "Montage SMB créé avec succès pour $USER_ID."
        else
            echo "Échec de la création du montage pour $USER_ID."
            echo "   Vérifiez que le chemin '\\\\$SMB_SERVER_IP\\$SMB_SHARE_NAME_FIXED\\$USER_ID' existe et que les droits SMB sont corrects."
        fi
    fi
done

echo ""
echo "--- Automatisation terminée pour tous les utilisateurs ---"
echo "Chaque utilisateur devra entrer ses identifiants SMB dans Nextcloud s'ils ne sont pas enregistrés."