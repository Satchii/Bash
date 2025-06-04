#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14" # L'adresse IP de votre PC Windows où se trouve le partage SMB
SMB_SHARE_NAME="Other"    # Le nom du partage SMB sur votre PC Windows

# IMPORTANT : Le sous-dossier distant est omis car le partage cible directement le dossier souhaité.
# Cela signifie que le chemin SMB final sera \\192.168.135.14\Other pour TOUS les utilisateurs.

# ATTENTION : NEXTCLOUD_MOUNT_POINT sera utilisé comme le point de montage interne (le chemin d'accès)
# ET comme le nom affiché dans l'interface Nextcloud pour ce stockage externe.
NEXTCLOUD_MOUNT_POINT="/MesFichiersSMBTest" # Ce dossier apparaîtra pour tous les utilisateurs.
# NEXTCLOUD_LABEL n'est plus utilisé comme argument séparé dans la création, mais pour la clarté des messages.
NEXTCLOUD_LABEL="Mon Dossier SMB Global (alias MesFichiersSMBTest)"

# Pour l'authentification, nous utiliserons les identifiants de l'utilisateur 'admin' de Windows
# ou de tout autre utilisateur Windows ayant accès au partage 'Other'.
SMB_USER="admin" # Nom d'utilisateur Windows pour l'authentification au partage SMB
SMB_PASSWORD="[VOTRE_MOT_DE_PASSE_WINDOWS_POUR_ADMIN]" # Mot de passe Windows pour l'utilisateur 'admin'

# VALEUR CONFIRMÉE PAR 'occ files_external:backends'
AUTHENTICATION_BACKEND="password::password" # C'est la valeur correcte pour 'Login and password'

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
echo "Nom affiché dans Nextcloud: $NEXTCLOUD_MOUNT_POINT"
echo "Utilisateur SMB pour auth.: $SMB_USER"
echo "Méthode d'authentification: $AUTHENTICATION_BACKEND"
echo "------------------------------------------------"

# Vérification de la version de jq (outil nécessaire pour parser le JSON)
echo "Version de jq : $(jq --version)"

# --- Étape 1 : Vérifier si le montage existe déjà et le créer si nécessaire ---

# Rechercher un ID de montage existant qui correspond à cette configuration spécifique (sans subfolder)
MOUNT_ID=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
           jq -r --arg smb_host "$SMB_HOST" --arg smb_share "$SMB_SHARE_NAME" --arg mount_point_val "$NEXTCLOUD_MOUNT_POINT" \
           '.[] | select(.backend == "smb" and .mount_point == $mount_point_val and .configuration.host == $smb_host and .configuration.share == $smb_share and (.configuration.subfolder == "" or .configuration.subfolder == null)) | .id' | head -n 1)

if [[ -n "$MOUNT_ID" ]]; then
    echo "✅ Montage SMB existant (ID: $MOUNT_ID) trouvé pour $NEXTCLOUD_MOUNT_POINT. Vérification/Mise à jour de la configuration et de l'attribution..."
else
    echo "Aucun montage SMB existant pour $NEXTCLOUD_MOUNT_POINT. Création d'un nouveau montage..."
    
    # Exécuter la commande et capturer la sortie complète
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
        echo "Vérifiez les journaux Nextcloud pour plus de détails."
        exit 1
    fi
    echo "Montage de base créé avec l'ID $MOUNT_ID."

    # Configurer les détails SMB (hôte, partage, authentification) en utilisant files_external:config
    echo "Configuration des détails SMB pour le montage (ID: $MOUNT_ID)..."
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" host "$SMB_HOST"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" share "$SMB_SHARE_NAME"
    # PAS DE SOUS-DOSSIER.
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" enable_sharing "true"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" save_login_credentials "true"
    # Authentification explicite via config (IMPORTANT pour que le mot de passe soit enregistré)
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" user "$SMB_USER"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" password "$SMB_PASSWORD"

fi

# --- Étape 2 : Attribuer le montage à tous les utilisateurs (si c'est le comportement désiré) ---

echo "Attribution du montage (ID: $MOUNT_ID) à tous les utilisateurs détectés..."
ALL_USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')
USER_LIST_FOR_APPLICABLE=""
for u in $ALL_USERS; do
    # On ajoute uniquement les utilisateurs "réels" et non les comptes système
    if [[ "$u" != "guest" && "$u" != "oc_ldap_user_manager" && "$u" != "nextcloud-bot" ]]; then
        USER_LIST_FOR_APPLICABLE="$USER_LIST_FOR_APPLICABLE --add-user $u"
    fi
done

if [[ -n "$USER_LIST_FOR_APPLICABLE" ]]; then
    # D'abord, on s'assure qu'il n'y a pas d'anciens utilisateurs/groupes attribués
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable --mount-id "$MOUNT_ID" --remove-all
    # Ensuite, on attribue à tous les utilisateurs détectés
    eval "sudo -u \"$NEXTCLOUD_WEB_USER\" php \"$NEXTCLOUD_PATH\"/occ files_external:applicable --mount-id \"$MOUNT_ID\" $USER_LIST_FOR_APPLICABLE"
    echo "✅ Montage attribué à tous les utilisateurs actifs."
else
    echo "Aucun utilisateur à attribuer."
fi

echo "--- Fin du script d'automatisation SMB ---"