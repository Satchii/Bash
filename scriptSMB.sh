#!/bin/bash
set -euo pipefail

NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data"

# --- PARAMÈTRES À ADAPTER ---
SMB_SERVER_IP="192.168.135.14"            # Adresse IP du PC Windows
SMB_SHARE_NAME_FIXED="DESKTOP-V3LBNSU"    # Nom du partage SMB racine
MOUNT_DISPLAY_NAME="Mon Dossier Personnel SMB Test"
MOUNT_POINT="/MesFichiersSMBTest"
# -----------------------------

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_SERVER_IP"
echo "Partage SMB fixe sur PC   : \\\\$SMB_SERVER_IP\\$SMB_SHARE_NAME_FIXED"
echo "Point de montage Nextcloud: $MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $MOUNT_DISPLAY_NAME"
echo "------------------------------------------------"

# Récupérer tous les utilisateurs actifs Nextcloud
USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" user:list --output=json | jq -r 'keys[]')

if [ -z "$USERS" ]; then
    echo "❌ Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions."
    exit 1
fi

for USER_ID in $USERS; do
    echo ""
    echo "🔄 Traitement de l'utilisateur : $USER_ID"

    # Vérifier si un montage existe déjà pour cet utilisateur
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
        echo "✅ Montage SMB déjà existant pour $USER_ID."
    else
        echo "➕ Aucun montage trouvé. Création en cours..."

        # Étape 1 : Création du montage SMB
        MOUNT_ID=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" files_external:create \
            "$MOUNT_DISPLAY_NAME" \
            smb \
            password::login credentials::save \
            --config "host=$SMB_SERVER_IP,share=$SMB_SHARE_NAME_FIXED,subfolder=$USER_ID" \
            --mount-point "$MOUNT_POINT" \
            --output=json | jq -r '.id')

        if [ -n "$MOUNT_ID" ]; then
            echo "✅ Montage SMB créé avec succès (ID: $MOUNT_ID). Attribution en cours..."

            # Étape 2 : Attribution du montage à l'utilisateur
            sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH/occ" files_external:applicable "$MOUNT_ID" --add-user "$USER_ID"

            echo "✅ Montage SMB attribué à l'utilisateur $USER_ID."
        else
            echo "❌ Échec de la création du montage SMB pour $USER_ID."
        fi
    fi
done

echo ""
echo "--- Automatisation terminée pour tous les utilisateurs ---"
echo "⚠️  Chaque utilisateur devra entrer ses identifiants SMB dans l'interface Nextcloud s'ils ne sont pas enregistrés."