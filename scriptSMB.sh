#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14" # L'adresse IP de votre PC Windows où se trouve le partage SMB
SMB_SHARE_NAME="Other"    # Le nom du partage SMB sur votre PC Windows (confirmé par image_87515c.png)
# Le sous-dossier distant est le nom de l'utilisateur, ce qui donne \\192.168.135.14\Other\Other pour l'utilisateur Other
# ATTENTION : NEXTCLOUD_MOUNT_POINT sera utilisé comme le point de montage interne (le chemin d'accès)
# ET comme le nom affiché dans l'interface Nextcloud pour ce stockage externe.
NEXTCLOUD_MOUNT_POINT="/MesFichiersSMBTest"
# NEXTCLOUD_LABEL n'est plus utilisé comme argument séparé dans la création, mais pour la clarté des messages.
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test (alias MesFichiersSMBTest)"

DOMAIN="" # Laissez vide si vous n'êtes pas dans un domaine Active Directory spécifique

# Chemin absolu vers votre installation Nextcloud
NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data" # L'utilisateur sous lequel Nextcloud tourne (généralement www-data sur Debian/Ubuntu)
# ==============================================================

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_HOST"
echo "Partage SMB Windows       : \\\\$SMB_HOST\\$SMB_SHARE_NAME"
echo "Point de montage interne  : $NEXTCLOUD_MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_MOUNT_POINT (sera identique au point de montage)"
echo "------------------------------------------------"

# Vérification de la version de jq (outil nécessaire pour parser le JSON)
echo "Version de jq : $(jq --version)"

# Récupérer tous les utilisateurs Nextcloud (sauf les systèmes comme guest, oc_ldap_user_manager, etc.)
users=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # La sortie de files_external:list n'est pas fiable pour 'applicable_users' avant l'attribution,
    # donc on va simplement chercher un montage existant qui correspond aux paramètres.
    # Et ensuite vérifier s'il est attribué.

    # Rechercher un ID de montage existant qui correspond à cette configuration spécifique pour cet utilisateur
    # (basé sur host, share, subfolder)
    current_mount_id=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
                       jq -r --arg smb_host "$SMB_HOST" --arg smb_share "$SMB_SHARE_NAME" --arg user_subfolder "$user" \
                       '.[] | select(.backend == "smb" and .configuration.host == $smb_host and .configuration.share == $smb_share and .configuration.subfolder == $user_subfolder) | .id' | head -n 1)

    if [[ -n "$current_mount_id" ]]; then
        echo "✅ Montage SMB existant (ID: $current_mount_id) trouvé pour $user. Vérification de l'attribution..."
        id="$current_mount_id"
    else
        echo "Aucun montage existant pour $user. Création d'un nouveau montage..."
        # Étape 1 : Créer le montage de base.
        # Nous ne passons que le strict minimum ici, car --config avec host/share/subfolder simultanément posait problème.
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
            "$NEXTCLOUD_MOUNT_POINT" \
            smb \
            password::logincredentials

        # Récupérer l'ID du montage nouvellement créé.
        # On recherche le plus récent ou un qui n'a pas encore de configuration SMB complète,
        # ou, mieux, celui qui a le mount_point que nous venons de créer et n'a pas encore de 'applicable_users'.
        id=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
             jq -r --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" \
             '.[] | select(.mount_point == $mount_point_val and (.applicable_users | length == 0 or .applicable_users == null)) | .id' | head -n 1)
        
        if [[ -z "$id" ]]; then
            echo "❌ Erreur CRITIQUE : Impossible d'obtenir un ID de montage après la création de base pour $user."
            echo "Ceci peut indiquer que la création a échoué ou que le filtre d'ID est incorrect."
            continue
        fi
        echo "Montage de base créé avec l'ID $id."

        # Étape 2 : Configurer les détails SMB (hôte, partage, sous-dossier) en utilisant files_external:config
        echo "Configuration des détails SMB pour le montage (ID: $id)..."
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$id" host "$SMB_HOST"
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$id" share "$SMB_SHARE_NAME"
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$id" subfolder "$user" # Le sous-dossier est le nom de l'utilisateur
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$id" enable_sharing "true"
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$id" save_login_credentials "true"
        # Ajoutez ici d'autres options si nécessaire, par exemple le domaine si pertinent
        # sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$id" domain "$DOMAIN"

    fi

    # Étape 3 : Attribuer le montage SMB à l'utilisateur spécifique.
    echo "Attribution/Vérification de l'attribution du montage (ID: $id) à l'utilisateur $user..."
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable --mount-id "$id" --user "$user"

    # Vérifier si l'attribution a réussi (optionnel, mais robuste)
    # Vérifiez la sortie de `files_external:list` après l'attribution.
    is_assigned=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json | \
                  jq -r --arg mount_id "$id" --arg user_id "$user" \
                  '[.[] | select(.id == ($mount_id | tonumber) and (.applicable_users | contains([$user_id])))] | length')
    
    if [ "$is_assigned" -gt 0 ]; then
        echo "✅ Montage configuré et attribué avec succès pour l'utilisateur $user."
    else
        echo "❌ Échec de l'attribution du montage (ID: $id) pour l'utilisateur $user. Vérifiez les journaux Nextcloud."
    fi

done

echo "--- Fin du script d'automatisation SMB ---"