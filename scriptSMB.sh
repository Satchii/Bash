#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14" # L'adresse IP de votre PC Windows où se trouve le partage SMB
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
echo "Partage SMB fixe sur PC   : \\\\$SMB_HOST\\$SHARE"
echo "Point de montage interne  : $NEXTCLOUD_MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_MOUNT_POINT (sera identique au point de montage)"
echo "------------------------------------------------"

# Vérification de la version de jq (outil nécessaire pour parser le JSON)
echo "Version de jq : $(jq --version)"

# Récupérer tous les utilisateurs Nextcloud (sauf les systèmes comme guest, oc_ldap_user_manager, etc.)
users=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')
SHARE=$users   # Le nom du partage SMB sur votre PC Windows

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"
    SHARE=$user   # Le nom du partage SMB sur votre PC Windows

    # Récupérer la sortie brute de 'occ files_external:list' pour cet utilisateur.
    # On la réutilise pour la vérification MOUNT_EXISTS et pour la récupération de l'ID.
    OCC_LIST_OUTPUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json)

    # Vérifier si un montage SMB existe déjà pour cet utilisateur avec les bonnes caractéristiques.
    # IMPORTANT : Cette partie du code vérifie si le montage est DÉJÀ ATTRIBUÉ à l'utilisateur.
    # C'est pour cela que nous incluons (.applicable_users | contains([$user_id]))
    MOUNT_EXISTS=$(echo "$OCC_LIST_OUTPUT" | \
                   jq -r --arg user_id "$user" --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" \
                   '[.[] | select(.backend == "smb" and .mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id and (.applicable_users | contains([$user_id])))] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "Montage SMB déjà existant pour $user et correctement attribué."
        continue
    fi

    echo "Aucun montage SMB trouvé pour $user ou non attribué. Création/Attribution en cours..."

    # Vérifions d'abord si le montage existe déjà mais n'est pas attribué.
    # On ne filtre PAS par applicable_users ici.
    CURRENT_MOUNT_ID=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
                       jq -r --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg user_id "$user" \
                       '.[] | select(.backend == "smb" and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id) | .id' | head -n 1) # Prendre le premier ID trouvé

    if [[ -n "$CURRENT_MOUNT_ID" ]]; then
        echo "Montage SMB déjà existant (ID: $CURRENT_MOUNT_ID) mais non attribué ou mal configuré pour $user. Réutilisation de l'ID."
        id="$CURRENT_MOUNT_ID"
    else
        echo "Aucun montage existant à réutiliser. Création d'un nouveau montage..."
        # Étape 1 : Créer le montage SMB.
        # La syntaxe est adaptée à votre version spécifique de 'occ files_external:create'.
        sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
            "$NEXTCLOUD_MOUNT_POINT" \
            smb \
            password::logincredentials \
            --config "host=$SMB_HOST,share=$SHARE,subfolder=$user,enable_sharing=true,save_login_credentials=true"

        # Récupérer l'ID du montage nouvellement créé.
        # Utiliser la liste générale de tous les montages et filtrer par les propriétés de config.
        # C'est la ligne qui posait problème : elle est maintenant juste après la création pour trouver l'ID.
        id=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
             jq -r --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" --arg smb_host "$SMB_HOST" --arg share_name "$SHARE" --arg user_id "$user" \
             '.[] | select(.backend == "smb" and .mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $share_name and .configuration.subfolder == $user_id) | .id' | head -n 1) # Prendre le premier ID trouvé
    fi

    if [[ -z "$id" ]]; then
        echo "Erreur CRITIQUE : Impossible d'obtenir un ID de montage pour $user, même après création ou réutilisation."
        echo "Vérifiez les journaux Nextcloud (Interface Admin > Journaux) et les sorties du script."
        echo "Cela peut indiquer que la création a échoué silencieusement ou que le filtre d'ID est incorrect."
        continue
    fi

    echo "Montage SMB en cours de traitement (ID: $id)."

    # Étape 2 : Attribuer le montage SMB à l'utilisateur spécifique.
    # Ceci remplace la nécessité de l'option '--applicable-users' qui n'est pas reconnue par 'create'.
    echo "Attribution/Vérification de l'attribution du montage (ID: $id) à l'utilisateur $user..."
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable --mount-id "$id" --user "$user"

    # Désactiver "Toutes les personnes" si nécessaire (uniquement si le montage a été créé par le script)
    # Vérifier l'état actuel du montage pour s'assurer qu'il n'est plus "Pour toutes les personnes"
    # Cela est généralement fait automatiquement par files_external:applicable --user
    # Si des problèmes persistent, on pourrait ajouter une vérification ici pour la désactiver explicitement.

    echo "✅ Montage configuré et attribué pour l'utilisateur $user."
done

echo "--- Fin du script d'automatisation SMB ---"