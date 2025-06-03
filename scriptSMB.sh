#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14" # L'adresse IP de votre PC Windows où se trouve le partage SMB
SHARE="DESKTOP-V3LBNSU"   # Le nom du partage SMB sur votre PC Windows
# ATTENTION : NEXTCLOUD_MOUNT_POINT sera utilisé comme le point de montage interne (le chemin d'accès)
# ET comme le nom affiché dans l'interface Nextcloud pour ce stockage externe.
NEXTCLOUD_MOUNT_POINT="/MesFichiersSMBTest" 
# NEXTCLOUD_LABEL n'est plus utilisé comme argument séparé dans la création, mais peut rester pour la clarté des messages.
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test (alias MesFichiersSMBTest)" 

DOMAIN="" # Laissez vide si vous n'êtes pas dans un domaine Active Directory spécifique

# Chemin absolu vers votre installation Nextcloud
NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data" # L'utilisateur sous lequel Nextcloud tourne (généralement www-data sur Debian/Ubuntu)
# ==============================================================

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_HOST"
echo "Partage SMB fixe sur PC   : \\\\$SMB_HOST\\$SHARE"
echo "Point de montage interne  : $NEXTCLOUD_MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_MOUNT_POINT (sera identique au point de montage)"
echo "------------------------------------------------"

# Vérification de la version de jq (outil nécessaire pour parser le JSON)
echo "Version de jq : $(jq --version)"

# Récupérer tous les utilisateurs Nextcloud (sauf les systèmes comme guest, oc_ldap_user_manager, etc.)
# 'keys[]' est utilisé car occ user:list --output=json retourne un objet, pas un tableau d'objets avec 'id'.
users=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # Récupérer la sortie brute de 'occ files_external:list' pour cet utilisateur.
    # Cela permet d'éviter de réexécuter la commande si elle est déjà disponible.
    OCC_LIST_OUTPUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json)

    # Vérifier si un montage SMB existe déjà pour cet utilisateur avec les bonnes caractéristiques.
    # Le filtre jq est sur une seule ligne pour éviter les erreurs de parsing Bash.
    # On utilise NEXTCLOUD_MOUNT_POINT comme le nom affiché (mount_point).
    MOUNT_EXISTS=$(echo "$OCC_LIST_OUTPUT" | \
                   jq -r --arg user_id "$user" --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" \
                   '[.[] | select(.backend == "smb" and .mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id and (.applicable_users | contains([$user_id])))] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "Montage SMB déjà existant pour $user."
        continue # Passer à l'utilisateur suivant si le montage existe déjà
    fi

    echo "Aucun montage SMB trouvé. Création en cours..."

    # Étape 1 : Créer le montage SMB.
    # La syntaxe est adaptée à votre version spécifique de 'occ files_external:create'.
    # - Le premier argument est le point de montage interne (qui sera aussi le nom affiché).
    # - Toutes les options de configuration sont regroupées dans un seul argument '--config'.
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
        "$NEXTCLOUD_MOUNT_POINT" \
        smb \
        password::logincredentials \
        --config "host=$SMB_HOST,share=$SHARE,subfolder=$user,enable_sharing=true,save_login_credentials=true"

    # Récupérer l'ID du montage nouvellement créé.
    # Note : À ce stade, le montage est créé mais pas encore attribué spécifiquement à l'utilisateur via 'files_external:applicable'.
    # On filtre donc par les propriétés de configuration (host, share, subfolder) et le point de montage.
    id=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
         jq -r --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg user_id "$user" \
         '.[] | select(.mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id) | .id')

    if [[ -z "$id" ]]; then
        echo "Erreur : impossible de récupérer l'ID du montage SMB pour $user après création."
        echo "Ceci peut indiquer un problème avec la création du montage ou un problème de parsing de la sortie de 'occ files_external:list'."
        echo "Vérifiez les journaux Nextcloud (Interface Admin > Journaux) pour plus de détails."
        echo "Assurez-vous que le chemin '\\\\$SMB_HOST\\$SHARE\\$user' existe sur le serveur SMB et que les permissions sont correctes."
        continue # Passer à l'utilisateur suivant malgré l'échec de récupération d'ID
    fi

    echo "Montage SMB créé avec l'ID $id."

    # Étape 2 : Attribuer le montage SMB à l'utilisateur spécifique.
    # Ceci remplace la nécessité de l'option '--applicable-users' qui n'est pas reconnue par 'create'.
    echo "Attribution du montage (ID: $id) à l'utilisateur $user..."
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable --mount-id "$id" --user "$user"

    echo "✅ Montage configuré et attribué pour l'utilisateur $user."
done

echo "--- Fin du script d'automatisation SMB ---"