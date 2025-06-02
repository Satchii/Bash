#!/bin/bash

NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data"
SMB_server_IP="192.168.1.150"
MOUNT_DISPLAY_NAME="Mon Dossier Personnel"
MOUNT_POINT="/MesFichiersSMB"

echo "--- Démarrage de l'automatisation des montages SMB pour Nextcloud ---"
echo "Serveur SMB ciblé:$SMB_server_IP"
echo "Point de montage: $MOUNT_POINT"

# Récuperer la liste de tous les utilisateurs nextcloud actifs 
USERS=$(sudo -u $NEXTCLOUD_WEB_USER php $NEXTCLOUD_PATH/occ user:list | awk '{print $2}' | tail -n +2)

if [ -z "$USERS" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions de occ, ou le nom d'utilisateur."
    exit 1
fi

for USER_ID in $USERS; do 
    echo "Traitement de l'utilisateur: $USER_ID"
    MOUNT_EXISTS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$USER_ID" --output=json |\
                    jq -r --argjson user_id "$USER_ID" '[.[] | select(.backend == "smb" and .configuration.share == $user_id and (.applicable_users | contains([$user_id]) ) )] | length')
    if [ "$MOUNT_EXISTS" -gt 0 ]; then 
        echo " Un montage SMB existe déja pour cet utilisateur."

    else 
        echo "Aucun montage SMB trouvé pour ce uilisateur. Création du montage..."
        # Creation montage SMB 
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
                "$MOUNT_DISPLAY_NAME" \
                smb \
                --config "host=$SMB_server_IP, share=$USER_ID" \
                --applicable-users "$USER_ID" \
                --mount-point "$MOUNT_POINT" \
                --option "save_login_credentials=true" \
                --option "enable_sharing=true" \

        if [ $? -eq 0 ]
        then
            echo "Montage SMB créé avec succès pour l'utilisateur $USER_ID."
        else
            echo "Échec de la création du montage SMB pour l'utilisateur $USER_ID."
        fi   
    fi
done  

echo "--- Automatisation des montages SMB pour Nextcloud terminée ---"



