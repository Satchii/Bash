#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14"
SHARE="DESKTOP-V3LBNSU"
NEXTCLOUD_MOUNT="/MesFichiersSMBTest"
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test"
DOMAIN=""
PASSWORD="votre_mot_de_passe"  # à sécuriser
# ==============================================================

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_HOST"
echo "Partage SMB fixe sur PC   : \\\\$SMB_HOST\\$SHARE"
echo "Point de montage Nextcloud: $NEXTCLOUD_MOUNT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_LABEL"
echo "------------------------------------------------"

# Récupérer tous les utilisateurs Nextcloud sauf les systèmes
users=$(sudo -u www-data php occ user:list --output=json | jq -r 'keys[]')

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # Vérifier si un montage existe déjà pour cet utilisateur
    exists=$(sudo -u www-data php occ files_external:list --output=json | jq -r '.[] | select(.mount_point == "'"$NEXTCLOUD_MOUNT"'")')

    if [[ -n "$exists" ]]; then
        echo "✅ Montage SMB déjà existant pour $user."
        continue
    fi

    echo "Aucun montage SMB trouvé. Création en cours..."

    # Créer le montage SMB
    sudo -u www-data php occ files_external:create "$NEXTCLOUD_MOUNT" smb password::logincredentials \
        -c host="$SMB_HOST" \
        -c share="$SHARE" \
        -c root="$user" \
        -c timeout="30" \
        -c domain="$DOMAIN" \
        -c remote_subfolder="$user" \
        -c username="$user" \
        -c password="$PASSWORD"

    # Récupérer l'ID du montage en fonction du point de montage
    id=$(sudo -u www-data php occ files_external:list --output=json | jq -r '.[] | select(.mount_point == "'"$NEXTCLOUD_MOUNT"'") | .id')

    if [[ -z "$id" ]]; then
        echo "❌ Erreur : impossible de récupérer l'ID du montage SMB pour $user."
        continue
    fi

    echo "Montage SMB créé avec l'ID $id. Attribution à l'utilisateur..."

    # Attribuer le montage SMB à l'utilisateur
    sudo -u www-data php occ files_external:applicable --mount-id "$id" --user "$user"

    echo "✅ Montage attribué à l'utilisateur $user."
done

echo "--- Fin du script d'automatisation SMB ---"