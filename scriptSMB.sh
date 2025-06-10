#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.100.8" # Ip serveur SMB 
SMB_SHARE_BASE="\\192.168.100.8\Utilisateurs" # Racine du partage. Exemple : \\192.168.100.8\Utilisateurs\<utilisateur>

NEXTCLOUD_PATH="/var/www/nextcloud" # Chemin vers l'installation Nextcloud
NEXTCLOUD_WEB_USER="www-data" # Utilisateur web de Nextcloud (généralement www-data sur Debian/Ubuntu)
AUTHENTICATION_BACKEND="password::userprovided" # Méthode d'authentification pour les utilisateurs Nextcloud
# ==============================================================

echo "--- Création de montages SMB personnalisés pour chaque utilisateur Nextcloud ---"

# Vérification de jq
if ! command -v jq &> /dev/null; then
    echo "jq est requis mais non installé. Installez-le avec : sudo apt install jq" 
    exit 1
fi

# Récupérer tous les utilisateurs Nextcloud
USERS=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

for USER in $USERS; do # Boucle pour chaque utilisateur
    echo "🔧 Traitement de l'utilisateur : $USER" 

    MOUNT_POINT="/PartageSMB_$USER" 
    SMB_SHARE_PATH="$SMB_SHARE_BASE/$USER"

    # Vérifier si un montage existe déjà pour cet utilisateur
    EXISTING_ID=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
        jq -r --arg mp "$MOUNT_POINT" --arg user "$USER" \
        '.[] | select(.mount_point == $mp and (.applicable_users | index($user))) | .id' | head -n1)

    if [[ -n "$EXISTING_ID" ]]; then
        echo "Montage déjà existant pour $USER (ID $EXISTING_ID), on passe." # Éviter de recréer un montage
        continue
    fi

    # Créer le montage
    CREATE_OUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create "$MOUNT_POINT" smb "$AUTHENTICATION_BACKEND" 2>&1)
    MOUNT_ID=$(echo "$CREATE_OUT" | grep -oP 'Storage created with id \K\d+')

    if [[ -z "$MOUNT_ID" ]]; then # Si l'ID n'a pas été trouvé, c'est une erreur
        echo "Échec de la création du montage pour $USER"
        echo "$CREATE_OUT"
        continue
    fi

    # Configurer le montage
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" host "$SMB_HOST" #Hôte SMB
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" share "$SMB_SHARE_PATH" #Partage
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" enable_sharing "false" # Désactiver le partage pour éviter les problèmes de sécurité
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" save_login_credentials "true" # Sauvegarder les identifiants

    # Attribuer au bon utilisateur
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable "$MOUNT_ID" --add-user "$USER"

    echo "Montage SMB créé pour $USER -> \\\\$SMB_HOST\\$SMB_SHARE_PATH (ID $MOUNT_ID)" 
done

echo "--- Fin du script ---"