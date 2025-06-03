#!/bin/bash

# ======================== CONFIGURATION ========================
SMB_HOST="192.168.135.14"
SHARE="DESKTOP-V3LBNSU"
NEXTCLOUD_MOUNT="/MesFichiersSMBTest" # Point de montage interne dans Nextcloud
NEXTCLOUD_LABEL="Mon Dossier Personnel SMB Test" # Nom affiché dans l'interface Nextcloud
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
# Note : 'keys[]' est utilisé car votre 'occ user:list --output=json' retourne un objet, pas un tableau d'objets avec 'id'.
users=$(sudo -u www-data php "$NEXTCLOUD_PATH"/occ user:list --output=json | jq -r 'keys[]')

if [ -z "$users" ]; then
    echo "Aucun utilisateur Nextcloud trouvé. Vérifiez les permissions ou le chemin vers occ."
    exit 1
fi

for user in $users; do
    echo "Traitement de l'utilisateur : $user"

    # Vérifier si un montage existe déjà pour cet utilisateur
    # On cherche un montage SMB avec le bon hôte, partage, sous-dossier, POINT DE MONTAGE ET label.
    MOUNT_EXISTS=$(sudo -u www-data php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json | \
                   jq -r --arg user_id "$user" \
                   --arg smb_host "$SMB_HOST" \
                   --arg share_name "$SHARE" \
                   --arg mount_point_val "$NEXTCLOUD_MOUNT" \
                   --arg label_val "$NEXTCLOUD_LABEL" \
                   '[.[] | select(
                       .backend == "smb" and
                       .mount_point == $label_val and # Ancien Nextcloud utilise le label comme mount_point, récent le chemin
                       .configuration.host == $smb_host and
                       .configuration.share == $share_name and
                       .configuration.subfolder == $user_id and
                       (.applicable_users | contains([$user_id]))
                   )] | length')

    if [ "$MOUNT_EXISTS" -gt 0 ]; then
        echo "✅ Montage SMB déjà existant pour $user."
        continue
    fi

    echo "Aucun montage SMB trouvé. Création en cours..."

    # Créer le montage SMB avec --mount-point
    # Nextcloud 31.0.5 devrait supporter '--mount-point'.
    # Les guillemets autour des variables sont cruciaux pour la syntaxe bash.
    sudo -u www-data php "$NEXTCLOUD_PATH"/occ files_external:create "$NEXTCLOUD_LABEL" smb \
        --config "host=$SMB_HOST,share=$SHARE,subfolder=$user" \
        --mount-pointsz "$NEXTCLOUD_MOUNT" \
        --applicable-users "$user" \
        --option "save_login_credentials=true" \
        --option "enable_sharing=true"

    # Récupérer l'ID du montage après création pour vérifier s'il a bien été créé
    # On utilise maintenant le label comme le point de montage dans la vérification pour la compatibilité
    # avec la façon dont occ list retourne le "mount_point" pour les versions > 25 et < 27.
    id=$(sudo -u www-data php "$NEXTCLOUD_PATH"/occ files_external:list "$user" --output=json | \
         jq -r '.[] | select(.mount_point == "'"$NEXTCLOUD_MOUNT"'" and (.applicable_users | contains(["'"$user"'"])) ) | .id')

    if [[ -z "$id" ]]; then
        echo "❌ Erreur : impossible de récupérer l'ID du montage SMB pour $user après création."
        echo "Vérifiez les journaux Nextcloud pour des erreurs (Interface Admin > Journaux)."
        echo "Vérifiez que le chemin '\\\\$SMB_HOST\\$SHARE\\$user' existe sur le serveur SMB et que les permissions sont correctes."
        continue
    fi

    echo "✅ Montage configuré pour l'utilisateur $user."
done

echo "--- Fin du script d'automatisation SMB ---"