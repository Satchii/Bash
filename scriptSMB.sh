#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.100.8" # IP du serveur SMB
SMB_SHARE_ROOT="Utilisateurs" # Dossier racine sur le partage SMB (ne pas mettre de \\ devant)
NEXTCLOUD_PATH="/var/www/nextcloud" # Chemin vers Nextcloud
NEXTCLOUD_WEB_USER="www-data" # Utilisateur web de Nextcloud
AUTHENTICATION_BACKEND="password::userprovided" # Authentification utilisée
# ==============================================================

echo "--- Création de montages SMB pour chaque utilisateur Nextcloud ---"

# Vérification jq
if ! command -v jq &> /dev/null; then
    echo "⛔ jq est requis. Installez-le avec : sudo apt install jq"
    exit 1
fi

# Récupération des utilisateurs et de leur display_name
USER_INFO=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ user:list --output=json)

echo "$USER_INFO" | jq -r 'to_entries[] | "\(.key)§\(.value.display_name)"' | while IFS='§' read -r UUID DISPLAY_NAME; do
    echo "🔧 Traitement de l'utilisateur UUID: $UUID - Nom affiché: $DISPLAY_NAME"

    # Extraire prénom et nom
    PRENOM=$(echo "$DISPLAY_NAME" | awk '{print $NF}')
    NOM=$(echo "$DISPLAY_NAME" | awk '{$NF=""; print $0}' | sed 's/ *$//')

    if [[ -z "$NOM" || -z "$PRENOM" ]]; then
        echo "⛔ Nom ou prénom manquant pour: $DISPLAY_NAME"
        continue
    fi

    # Génération du nom de dossier SMB (p.nom en minuscule)
    SMB_USER=$(echo "${PRENOM:0:1}.$NOM" | tr '[:upper:]' '[:lower:]')
    SMB_SHARE_PATH="\\\\$SMB_HOST\\$SMB_SHARE_ROOT\\$SMB_USER"

    MOUNT_POINT="/PartageSMB_$DISPLAY_NAME"

    # Vérifie si le montage existe déjà
    EXISTING_ID=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:list --output=json | \
        jq -r --arg mp "$MOUNT_POINT" --arg user "$UUID" \
        '.[] | select(.mount_point == $mp and (.applicable_users | index($user))) | .id' | head -n1)

    if [[ -n "$EXISTING_ID" ]]; then
        echo "✅ Montage déjà existant pour $UUID (ID $EXISTING_ID), on passe."
        continue
    fi

    # Création du stockage
    CREATE_OUT=$(sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:create "$MOUNT_POINT" smb "$AUTHENTICATION_BACKEND" 2>&1)
    MOUNT_ID=$(echo "$CREATE_OUT" | grep -oP 'Storage created with id \K\d+')

    if [[ -z "$MOUNT_ID" ]]; then
        echo "⛔ Échec de création du montage pour $UUID"
        echo "$CREATE_OUT"
        continue
    fi

    # Configuration du montage
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" host "$SMB_HOST"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" share "$SMB_SHARE_ROOT\\$SMB_USER"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" enable_sharing "false"
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:config "$MOUNT_ID" save_login_credentials "true"

    # Lier à l'utilisateur
    sudo -u "$NEXTCLOUD_WEB_USER" php "$NEXTCLOUD_PATH"/occ files_external:applicable "$MOUNT_ID" --add-user "$UUID"

    echo "✅ Montage SMB ajouté : $MOUNT_POINT → \\\\$SMB_HOST\\$SMB_SHARE_ROOT\\$SMB_USER"
done

echo "--- Fin du script ---"
