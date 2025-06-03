#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14"
SHARE="DESKTOP-V3LBNSU"
NEXTCLOUD_MOUNT="/MesFichiersSMBTest"
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test"
DOMAIN="" # Laissez vide si pas de domaine Active Directory spécifique

# Chemin absolu vers votre installation Nextcloud
NEXTCLOUD_PATH="/var/www/nextcloud"
# ==============================================================

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_HOST"
echo "Partage SMB fixe sur PC   : \\\\$SMB_HOST\\$SHARE"
echo "Point de montage Nextcloud: $NEXTCLOUD_MOUNT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_LABEL"
echo "------------------------------------------------"

# Récupérer tous les utilisateurs Nextcloud sauf les systèmes
users=$(sudo -u www-data php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # Vérifier si un montage existe déjà pour cet utilisateur
    exists=$(sudo -u www-data php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
             jq -r '.[] | select(.mount_point == "'"$NEXTCLOUD_MOUNT"'" and (.applicable_users | contains(["'"$user"'"])))')

    if [[ -n "$exists" ]]; then
        echo "✅ Montage SMB déjà existant pour $user."
        continue
    fi

    echo "Aucun montage SMB trouvé. Création en cours..."

    # Créer le montage SMB
    sudo -u www-data php "$NEXTCLOUD_PATH"/occ files_external:create "$NEXTCLOUD_LABEL" smb \
        --config "host=$SMB_HOST,share=$SHARE,subfolder=$user" \
        --mount-point "$NEXTCLOUD_MOUNT" \
        --applicable-users "$user" \
        --option "save_login_credentials=true" \
        --option "enable_sharing=true"

    # Récupérer l'ID du montage en fonction du point de montage et de l'utilisateur
    id=$(sudo -u www-data php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json | \
         jq -r '.[] | select(.mount_point == "'"$NEXTCLOUD_MOUNT"'" and (.applicable_users | contains(["'"$user"'"])) ) | .id')

    if [[ -z "$id" ]]; then
        echo "❌ Erreur : impossible de récupérer l'ID du montage SMB pour $user après création."
        continue
    fi

    echo "✅ Montage configuré pour l'utilisateur $user."
done

echo "--- Fin du script d'automatisation SMB ---"