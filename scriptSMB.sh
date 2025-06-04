#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14" # L'adresse IP de votre PC Windows où se trouve le partage SMB
SMB_SHARE_NAME="Other"    # Le nom du partage SMB sur votre PC Windows (le dossier partagé)

# ATTENTION : NEXTCLOUD_MOUNT_POINT sera utilisé comme le point de montage interne (le chemin d'accès)
# ET comme le nom affiché dans l'interface Nextcloud pour ce stockage externe.
NEXTCLOUD_MOUNT_POINT="/MonPartageSMB" # Nom du dossier dans Nextcloud pour ce partage SMB.

# VALEUR CONFIRMÉE PAR 'occ files_external:backends'
# 'password::userprovided' signifie que l'utilisateur Nextcloud devra entrer ses propres identifiants SMB
AUTHENTICATION_BACKEND="password::userprovided" 

# Chemin absolu vers votre installation Nextcloud
NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_WEB_USER="www-data" # L'utilisateur sous lequel Nextcloud tourne (généralement www-data sur Debian/Ubuntu)
# ==============================================================

echo "------------------------------------------------"
echo "--- Démarrage de l'automatisation SMB pour Nextcloud ---"
echo "Serveur SMB ciblé         : $SMB_HOST"
echo "Partage SMB Windows       : \\\\$SMB_HOST\\$SMB_SHARE_NAME"
echo "Point de montage interne  : $NEXTCLOUD_MOUNT_POINT"
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_MOUNT_POINT"
echo "Méthode d'authentification: $AUTHENTICATION_BACKEND (Identifiants fournis par l'utilisateur)"
echo "------------------------------------------------"

# Vérification de la version de jq (outil nécessaire pour parser le JSON)
echo "Version de jq : $(jq --version)"

# --- Étape 1 : Vérifier si le montage existe déjà et le créer si nécessaire ---

# Rechercher un ID de montage existant qui correspond à cette configuration spécifique.
# On filtre par le backend d'authentification spécifique et on s'assure qu'il n'est PAS attribué à "all".
MOUNT_ID=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
           jq -r --arg smb_host "$SMB_HOST" --arg smb_share "$SMB_SHARE_NAME" --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" --arg auth_backend "$AUTHENTICATION_BACKEND" \
           '.[] | select(.backend == "smb" and .mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $smb_share and .auth_backend == $auth_backend and (.applicable_users | length > 0) ) | .id' | head -n 1)

if [[ -n "$MOUNT_ID" ]]; then
    echo "✅ Montage SMB existant (ID: $MOUNT_ID) trouvé pour $NEXTCLOUD_MOUNT_POINT. Vérification/Mise à jour de la configuration et de l'attribution..."
else
    echo "Aucun montage SMB existant pour $NEXTCLOUD_MOUNT_POINT. Création d'un nouveau montage..."
    
    # Créer le montage de base avec la méthode d'authentification 'password::userprovided'
    # Nextcloud demandera les identifiants à l'utilisateur lors de la première connexion.
    CREATE_OUTPUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create \
        "$NEXTCLOUD_MOUNT_POINT" \
        smb \
        "$AUTHENTICATION_BACKEND" 2>&1) # Capture stdout et stderr
    
    echo "$CREATE_OUTPUT" # Afficher la sortie pour le diagnostic

    # Tenter de parser l'ID de la sortie. On cherche "Storage created with id X"
    MOUNT_ID=$(echo "$CREATE_OUTPUT" | grep -oP 'Storage created with id \K\d+' | head -n 1)

    if [[ -z "$MOUNT_ID" ]]; then
        echo "❌ Erreur CRITIQUE : Impossible d'obtenir un ID de montage après la création de base pour $NEXTCLOUD_MOUNT_POINT."
        echo "Le message de création de stockage n'a pas été trouvé ou n'a pas pu être parsé."
        echo "Vérifiez les journaux Nextcloud."
        exit 1
    fi
    echo "Montage de base créé avec l'ID $MOUNT_ID."

    # Configurer les détails SMB (hôte, partage) en utilisant files_external:config
    echo "Configuration des détails SMB pour le montage (ID: $MOUNT_ID)..."
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" host "$SMB_HOST"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" share "$SMB_SHARE_NAME"
    # PAS DE SOUS-DOSSIER.
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" enable_sharing "true"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" save_login_credentials "true"
    # NE PAS CONFIGURER 'user' ET 'password' ICI, car ils sont fournis par l'utilisateur Nextcloud.
fi

# --- Étape 2 : Attribuer le montage aux utilisateurs spécifiques ---

echo "Attribution du montage (ID: $MOUNT_ID) aux utilisateurs détectés..."
ALL_USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')
USER_LIST_FOR_APPLICABLE=""
for u in $ALL_USERS; do
    # On ajoute uniquement les utilisateurs "réels" et non les comptes système pour l'attribution
    # MODIFIER CETTE SECTION si vous voulez attribuer le montage à des utilisateurs ou groupes spécifiques.
    # Exemple pour attribuer uniquement à "admin" et "Test":
    # if [[ "$u" == "admin" || "$u" == "Test" ]]; then
    #     USER_LIST_FOR_APPLICABLE="$USER_LIST_FOR_APPLICABLE --add-user $u"
    # fi
    # Pour l'instant, cela attribue à TOUS les utilisateurs Nextcloud "réels".
    if [[ "$u" != "guest" && "$u" != "oc_ldap_user_manager" && "$u" != "nextcloud-bot" ]]; then
        USER_LIST_FOR_APPLICABLE="$USER_LIST_FOR_APPLICABLE --add-user $u"
    fi
done

if [[ -n "$USER_LIST_FOR_APPLICABLE" ]]; then
    echo "Attribution/Vérification de l'attribution du montage (ID: $MOUNT_ID) à ces utilisateurs : $USER_LIST_FOR_APPLICABLE"
    
    # Pour s'assurer que seuls les utilisateurs désirés sont attribués, on fait un --remove-all
    # S'il y a déjà des attributions incorrectes, cela les nettoiera.
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable --mount-id "$MOUNT_ID" --remove-all

    # Ensuite, on attribue aux utilisateurs spécifiques
    eval "sudo -u \"$NEXTCLOUD_WEB_USER\" php \"$NEXTCLOUD_PATH\"/occ files_external:applicable --mount-id \"$MOUNT_ID\" $USER_LIST_FOR_APPLICABLE"
    
    echo "✅ Montage attribué aux utilisateurs actifs."
else
    echo "Aucun utilisateur à attribuer."
fi

echo "--- Fin du script d'automatisation SMB ---"