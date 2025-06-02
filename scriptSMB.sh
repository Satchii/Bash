#!/bin/bash

# Configuration
NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data"

# --- À personnaliser ---
SMB_SERVER_IP="192.168.135.14"            # Adresse IP de la machine Windows
SMB_SHARE_NAME_FIXED="DESKTOP-V3LBNSU"    # Nom du partage sur la machine Windows
MOUNT_DISPLAY_NAME="Mon Dossier Personnel SMB Test"
MOUNT_POINT="/MesFichiersSMBTest"
# ------------------------

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_SERVER_IP"
echo "Partage SMB fixe sur PC   : \\\\$SMB_SERVER_IP\\$SMB_SHARE_NAME_FIXED"
echo "Point de montage Nextcloud: $MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $MOUNT_DISPLAY_NAME"
echo "------------------------------------------------"

# Récupération des utilisateurs Nextcloud
USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" user:list --output=json | jq -r 'keys[]')

if [ -z "$USERS" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers 'occ'."
    exit 1
fi

for USER_ID in $USERS; do
    echo "Traitement de l'utilisateur : $USER_ID"

    # Vérifie si un montage SMB existe déjà pour cet utilisateur
    MOUNT_EXISTS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" files_external:list "$USER_ID" --output=json | \
        jq -r --arg user_id "$USER_ID" \
              --arg smb_server_ip "$SMB_SERVER_IP" \
              --arg smb_share_fixed "$SMB_SHARE_NAME_FIXED" \
              --arg mount_point "$MOUNT_POINT" \
              '[.[] | select(
                  .backend == "smb" and
                  .configuration.host == $smb_server_ip and
                  .configuration.share == $smb_share_fixed and
                  .configuration.subfolder == $user_id and
                  .mount_point == $mount_point
              )] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "Un montage SMB existe déjà pour cet utilisateur."
    else
        echo "Aucun montage SMB trouvé. Création en cours..."

        # Création du montage
        OUTPUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" files_external:create \
            "$MOUNT_POINT" \
            smb \
            password::login \
            --config "host=$SMB_SERVER_IP,share=$SMB_SHARE_NAME_FIXED,subfolder=$USER_ID" \
            --output=json 2>&1)

        if echo "$OUTPUT" | jq -e . >/dev/null 2>&1; then
            MOUNT_ID=$(echo "$OUTPUT" | jq -r '.id')
            echo "Montage SMB créé avec l'ID $MOUNT_ID. Attribution à l'utilisateur..."

            # Attribution du montage à l'utilisateur
            sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" files_external:applicable "$MOUNT_ID" --add-user "$USER_ID"
            echo "Montage attribué à l'utilisateur $USER_ID."
        else
            echo "Échec de la création du montage pour $USER_ID."
            echo "Message retourné par Nextcloud :"
            echo "$OUTPUT"
        fi
    fi
done

echo "--- Fin du script d'automatisation SMB ---"