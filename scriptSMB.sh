#!/bin/bash

NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data"
# --- IP DE TEST À ADAPTER POUR VOTRE PC ---
SMB_SERVER_IP="192.168.135.14"
# ----------------------------------------
MOUNT_DISPLAY_NAME="Mon Dossier Personnel SMB Test" # Nom pour le test
MOUNT_POINT="/MesFichiersSMBTest"                   # Point de montage pour le test

echo "--- Démarrage de l'automatisation des montages SMB pour Nextcloud ---"
echo "Serveur SMB ciblé : $SMB_SERVER_IP"
echo "Point de montage : $MOUNT_POINT"

USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r '.[].id')

if [ -z "$USERS" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for USER_ID in $USERS; do
    echo "Traitement de l'utilisateur : $USER_ID"

    # Vérification si un montage SMB existe déjà pour cet utilisateur
    # On vérifie la correspondance exacte de l'hôte, du partage (nom de l'utilisateur),
    # et l'absence de sous-dossier, et le point de montage.
    MOUNT_EXISTS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$USER_ID" --output=json | \
                   jq -r --arg user_id "$USER_ID" \
                   --arg smb_server_ip "$SMB_SERVER_IP" \
                   --arg mount_point "$MOUNT_POINT" \
                   '[.[] | select(
                       .backend == "smb" and
                       .configuration.host == $smb_server_ip and
                       .configuration.share == $user_id and
                       .configuration.subfolder == "" and
                       .mount_point == $mount_point and
                       (.applicable_users | contains([$user_id]))
                   )] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "Un montage SMB existe déjà pour cet utilisateur."
    else
        echo "Aucun montage SMB trouvé pour cet utilisateur. Création du montage..."

        # Création du montage SMB
        # Le partage est le nom de l'utilisateur ($USER_ID), et il n'y a pas de 'subfolder' car
        # le chemin est directement \\IP\NOM_UTILISATEUR
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
            "$MOUNT_DISPLAY_NAME" \
            smb \
            --config "host=$SMB_SERVER_IP,share=$USER_ID" \
            --applicable-users "$USER_ID" \
            --mount-point "$MOUNT_POINT" \
            --option "save_login_credentials=true" \
            --option "enable_sharing=true"

        if [ $? -eq 0 ]; then
            echo "Montage SMB créé avec succès pour l'utilisateur $USER_ID."
        else
            echo "Échec de la création du montage SMB pour l'utilisateur $USER_ID."
            echo "Vérifiez que le partage '\\\\$SMB_SERVER_IP\\$USER_ID' existe sur le serveur SMB et que les permissions sont correctes."
        fi
    fi
done

echo "--- Automatisation des montages SMB pour Nextcloud terminée ---"