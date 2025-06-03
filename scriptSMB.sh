#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14"
SHARE="DESKTOP-V3LBNSU"
NEXTCLOUD_MOUNT_POINT="/MesFichiersSMBTest" # Chemin interne visible dans Nextcloud
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test" # Nom affiché dans l'interface

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
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_LABEL"
echo "------------------------------------------------"

# Récupérer tous les utilisateurs Nextcloud sauf les systèmes
# Note : 'keys[]' est utilisé car votre 'occ user:list --output=json' retourne un objet, pas un tableau d'objets avec 'id'.
users=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # Vérifier si un montage existe déjà pour cet utilisateur
    # On cherche un montage SMB avec le bon hôte, partage, sous-dossier, POINT DE MONTAGE INTERNE ET APPLICABLE A L'UTILISATEUR
    MOUNT_EXISTS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json | \
                   jq -r --arg user_id "$user" \
                   --arg smb_host "$SMB_HOST" \
                   --arg share_name "$SHARE" \
                   --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" \
                   --arg label_val "$NEXTCLOUD_LABEL" \
                   '[.[] | select(
                       .backend == "smb" and
                       .mount_point == $label_val and # Pour des versions plus récentes, c'est le label affiché.
                       .configuration.host == $smb_host and
                       .configuration.share == $share_name and
                       .configuration.subfolder == $user_id and
                       (.applicable_users | contains([$user_id])) # Vérifie que c'est bien applicable à cet utilisateur
                   )] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "✅ Montage SMB déjà existant pour $user."
        continue
    fi

    echo "Aucun montage SMB trouvé. Création en cours..."

    # Créer le montage SMB avec --mount-point
    # La syntaxe pour Nextcloud 25+ est :
    # files_external:create [--user <user>] [-c|--config <config>] [--applicable-users <user list>]
    #                       [--mount-point <mount_point>] [--option <option>] <label> <storage_backend> <authentication_backend>

    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
        "$NEXTCLOUD_LABEL" \
        smb \
        password::logincredentials \
        --config "host=$SMB_HOST" \
        --config "share=$SHARE" \
        --config "subfolder=$user" \
        --mount-point "$NEXTCLOUD_MOUNT_POINT" \
        --applicable-users "$user" \
        --option "enable_sharing=true" \
        --option "save_login_credentials=true" # Rétabli cette option car elle est la bonne pour les versions modernes

    # Récupérer l'ID du montage après création pour vérifier s'il a bien été créé
    # J'ai ajouté l'argument "$user" à files_external:list pour filtrer les montages de cet utilisateur
    id=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json | \
         jq -r '.[] | select(
             .mount_point == "'"$NEXTCLOUD_MOUNT_POINT"'" and # Le mount_point interne
             .configuration.host == "'"$SMB_HOST"'" and
             .configuration.share == "'"$SHARE"'" and
             .configuration.subfolder == "'"$user"'" and
             (.applicable_users | contains(["'"$user"'"]))
         ) | .id')

    if [[ -z "$id" ]]; then
        echo "❌ Erreur : impossible de récupérer l'ID du montage SMB pour $user après création."
        echo "Vérifiez les journaux Nextcloud (Interface Admin > Journaux) et les sorties du script."
        echo "Assurez-vous que le chemin '\\\\$SMB_HOST\\$SHARE\\$user' existe sur le serveur SMB et que les permissions sont correctes."
        continue
    fi

    echo "✅ Montage configuré pour l'utilisateur $user (ID: $id)."
done

echo "--- Fin du script d'automatisation SMB ---"