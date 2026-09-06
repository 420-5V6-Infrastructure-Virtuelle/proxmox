#!/bin/bash

# =========================================================================
# CONFIGURATION ENSEIGNANT (À AJUSTER SELON VOTRE INFRASTRUCTURE)
# =========================================================================
TARGET_STORAGE_NVME="nvme-thin"   # Nom de votre stockage NVMe LVM-Thin
TARGET_STORAGE_SSD="ssd-ha-zfs"   # Nom de votre stockage SSD ZFS
BACKUP_STORAGE="local"            # Emplacement où se trouve le fichier de sauvegarde
BACKUP_FILE="vzdump-qemu-Debian-Baseline.vma.zst" # Nom exact du fichier importé

# =========================================================================
# ÉTAPE 1 : INTERACTION ET VALIDATION DU VMID
# =========================================================================
clear
echo "========================================================================="
echo "        PROXMOX DEPLOYMENT SCRIPT - LABO DE PERFORMANCE CEGEP"
echo "========================================================================="
echo ""
read -rp "Entrez le VMID que vous souhaitez créer (ex: 200) : " VMID

# Validation : Est-ce que le VMID est un nombre ?
if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo "❌ Erreur : Le VMID doit être un nombre entier."
    exit 1
fi

# Validation : Est-ce que le VMID est déjà utilisé par une VM ou un CT Proxmox ?
# (utilise jq sur du JSON structuré pour éviter les faux positifs de grep
#  sur un tableau texte où le nombre pourrait apparaître ailleurs)
if command -v jq &> /dev/null; then
    VMID_EXISTS=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | jq -r --arg id "$VMID" '.[] | select(.vmid == ($id | tonumber)) | .vmid')
else
    echo "(jq non installé, utilisation de qm list / pct list en solution de secours)"
    VMID_EXISTS=$(qm list 2>/dev/null | awk -v id="$VMID" '$1==id{print $1}')
    if [[ -z "$VMID_EXISTS" ]]; then
        VMID_EXISTS=$(pct list 2>/dev/null | awk -v id="$VMID" '$1==id{print $1}')
    fi
fi

if [[ -n "$VMID_EXISTS" ]]; then
    echo "❌ Erreur : Le VMID $VMID est déjà utilisé sur ce nœud ou le cluster. Arrêt du script."
    exit 1
fi

echo "✅ Le VMID $VMID est disponible."
echo ""

# =========================================================================
# ÉTAPE 2 : AFFICHAGE DU MENU DES CONFIGURATIONS STRATÉGIQUES
# =========================================================================
echo "Sélectionnez la configuration de test qui vous a été assignée :"
echo "-------------------------------------------------------------------------"
echo "AXE 1 : STOCKAGE"
echo "  1) C1  - NVMe | SCSI | No Cache (Baseline de référence)"
echo "  2) C2  - NVMe | SCSI | Write back"
echo "  3) C3  - NVMe | SCSI | Write through"
echo "  4) C4  - NVMe | SATA | No Cache"
echo "  5) C5  - NVMe | VirtIO Block | No Cache"
echo "  6) C6  - NVMe | SATA | Write back"
echo "  7) C7  - SSD (ZFS) | SCSI | No Cache"
echo "  8) C8  - SSD (ZFS) | SCSI | Write back"
echo "  9) C9  - SSD (ZFS) | SCSI | Write through"
echo " 10) C10 - SSD (ZFS) | SATA | No Cache"
echo " 11) C11 - SSD (ZFS) | VirtIO Block | No Cache"
echo " 12) C12 - SSD (ZFS) | SCSI | No Cache (Pas de Trim/Discard)"
echo "AXE 2 : CPU & TOPOLOGIE"
echo " 13) C13 - NVMe | CPU Type: kvm64 (Générique)"
echo " 14) C14 - NVMe | Topologie Absurde: 4 Sockets / 1 Core"
echo " 15) C15 - NVMe | Topologie Équilibrée: 2 Sockets / 2 Cores"
echo " 16) C16 - NVMe | CPU Type: max"
echo " 17) C17 - NVMe | CPU Limité à 50% via cpulimit"
echo " 18) C18 - NVMe | CPU Type: x86-64-v3"
echo "AXE 3 : GESTION RAM"
echo " 19) C19 - NVMe | RAM Dynamique (Ballooning ON, 4-16 Go)"
echo " 20) C20 - NVMe | Hugepages 2M activées"
echo " 21) C21 - SSD (ZFS) | Conflit RAM direct vs ARC Cache"
echo "AXE 4 : COMPARAISON IO THREAD"
echo " 22) C22 - NVMe | SCSI | No Cache | SANS IO Thread (à comparer avec C1)"
echo "-------------------------------------------------------------------------"
read -rp "Entrez votre choix (1-22) : " CHOIX

if [[ ! "$CHOIX" =~ ^[0-9]+$ ]] || (( CHOIX < 1 || CHOIX > 22 )); then
    echo "❌ Choix invalide. Script arrêté."
    exit 1
fi

# =========================================================================
# ÉTAPE 3 : RESTAURATION DU BACKUP DE BASE (C1 PAR DÉFAUT SUR NVME)
# =========================================================================
echo ""
echo "🔄 Restauration initiale du backup en cours..."
# Restauration par défaut sur le stockage NVMe ultra-rapide pour sauver du temps
qmrestore ${BACKUP_STORAGE}:backup/${BACKUP_FILE} "$VMID" --storage "$TARGET_STORAGE_NVME"

if [ $? -ne 0 ]; then
    echo "❌ Erreur critique lors de la restauration du backup."
    exit 1
fi

# Variable de commodité pour le nom du disque d'origine après restauration
DISK_NAME="vm-${VMID}-disk-0"
# Suit le storage qui héberge réellement le disque (change si on migre vers ZFS)
CURRENT_STORAGE="$TARGET_STORAGE_NVME"

# =========================================================================
# ÉTAPE 4 : APPLICATION DES CONFIGURATIONS SPÉCIFIQUES (STRUCTURE APPRENANTE)
# =========================================================================
# NOTE PÉDAGOGIQUE : l'IO Thread (iothread=1) est appliqué directement dans
# chaque configuration SCSI ci-dessous (1, 2, 3, 7, 8, 9, 12) plutôt qu'en
# bloc final, pour éviter d'écraser les paramètres cache/discard déjà
# définis (qm set remplace toute la chaîne d'options d'un disque, il ne la
# fusionne pas). Si vous voulez comparer explicitement IO Thread ON vs OFF,
# il faudrait ajouter une configuration dédiée sans iothread=1.

case $CHOIX in
    1)
        # C1 : Baseline - NVMe | SCSI | No Cache + IO Thread
        CONFIG_NUM="01"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --scsi0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=none,discard=on,iothread=1"
        ;;
    2)
        # C2 : NVMe | SCSI | Write back
        CONFIG_NUM="02"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --scsi0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=writeback,discard=on,iothread=1"
        ;;
    3)
        # C3 : NVMe | SCSI | Write through
        CONFIG_NUM="03"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --scsi0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=writethrough,discard=on,iothread=1"
        ;;
    4)
        # C4 : NVMe | SATA | No Cache
        CONFIG_NUM="04"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm set "$VMID" --delete scsi0
        qm set "$VMID" --sata0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=none,discard=on" --boot order=sata0
        ;;
    5)
        # C5 : NVMe | VirtIO Block | No Cache
        CONFIG_NUM="05"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm set "$VMID" --delete scsi0
        qm set "$VMID" --virtio0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=none,discard=on" --boot order=virtio0
        ;;
    6)
        # C6 : NVMe | SATA | Write back
        CONFIG_NUM="06"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm set "$VMID" --delete scsi0
        qm set "$VMID" --sata0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=writeback,discard=on" --boot order=sata0
        ;;
    7)
        # C7 : SSD (ZFS) | SCSI | No Cache
        CONFIG_NUM="07"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --scsi0 "${CURRENT_STORAGE}:${DISK_NAME},cache=none,discard=on,iothread=1"
        ;;
    8)
        # C8 : SSD (ZFS) | SCSI | Write back
        CONFIG_NUM="08"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --scsi0 "${CURRENT_STORAGE}:${DISK_NAME},cache=writeback,discard=on,iothread=1"
        ;;
    9)
        # C9 : SSD (ZFS) | SCSI | Write through
        CONFIG_NUM="09"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --scsi0 "${CURRENT_STORAGE}:${DISK_NAME},cache=writethrough,discard=on,iothread=1"
        ;;
    10)
        # C10 : SSD (ZFS) | SATA | No Cache
        CONFIG_NUM="10"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --delete scsi0
        qm set "$VMID" --sata0 "${CURRENT_STORAGE}:${DISK_NAME},cache=none,discard=on" --boot order=sata0
        ;;
    11)
        # C11 : SSD (ZFS) | VirtIO Block | No Cache
        CONFIG_NUM="11"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --delete scsi0
        qm set "$VMID" --virtio0 "${CURRENT_STORAGE}:${DISK_NAME},cache=none,discard=on" --boot order=virtio0
        ;;
    12)
        # C12 : SSD (ZFS) | SCSI | No Cache (Sans Discard/Trim) — à comparer avec C7
        CONFIG_NUM="12"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --scsi0 "${CURRENT_STORAGE}:${DISK_NAME},cache=none,iothread=1"
        ;;
    13)
        # C13 : CPU Générique kvm64
        CONFIG_NUM="13"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --cpu kvm64
        ;;
    14)
        # C14 : Topologie absurde multi-sockets (4 Sockets / 1 Core)
        CONFIG_NUM="14"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --sockets 4 --cores 1
        ;;
    15)
        # C15 : Topologie équilibrée (2 Sockets / 2 Cores)
        CONFIG_NUM="15"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --sockets 2 --cores 2
        ;;
    16)
        # C16 : CPU max
        CONFIG_NUM="16"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --cpu max
        ;;
    17)
        # C17 : CPU Limité (50% via cpulimit — plafond réel indépendant de la contention)
        # Note : contrairement à cpuunits (poids relatif qui n'a d'effet qu'en cas de
        # contention avec d'autres VMs sur le même hôte), cpulimit impose un plafond
        # dur en nombre de coeurs équivalents, visible même sans autre charge concurrente.
        # Avec 4 vCPU configurés, cpulimit 2 = plafond à 50% de la capacité totale.
        CONFIG_NUM="17"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --cpulimit 2
        ;;
    18)
        # C18 : CPU x86-64-v3
        CONFIG_NUM="18"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --cpu x86-64-v3
        ;;
    19)
        # C19 : RAM Dynamique (Min 4 Go, Max 16 Go, Ballooning Actif)
        CONFIG_NUM="19"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --memory 16384 --balloon 4096
        ;;
    20)
        # C20 : Hugepages 2M
        CONFIG_NUM="20"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --hugepages 2
        ;;
    21)
        # C21 : Conflit RAM direct vs ARC Cache (Stockage sur ZFS requis)
        CONFIG_NUM="21"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}"
        qm disk move "$VMID" scsi0 "$TARGET_STORAGE_SSD" --delete 1
        CURRENT_STORAGE="$TARGET_STORAGE_SSD"
        qm set "$VMID" --scsi0 "${CURRENT_STORAGE}:${DISK_NAME},cache=none,discard=on,iothread=1"
        ;;
    22)
        # C22 : NVMe | SCSI | No Cache | SANS IO Thread
        # Identique à C1 en tout point, sauf l'absence d'iothread : sert de
        # point de comparaison direct pour le Test 9 (QD32 random read).
        CONFIG_NUM="22"
        qm set "$VMID" --name "debian-c${CONFIG_NUM}" --scsi0 "${TARGET_STORAGE_NVME}:${DISK_NAME},cache=none,discard=on,iothread=0"
        ;;
esac

echo ""
echo "========================================================================="
echo " 🎉 CONFIGURATION TERMINÉE AVEC SUCCÈS !"
echo " VMID : $VMID"
echo " Nom Proxmox : debian-c${CONFIG_NUM}"
echo "========================================================================="
echo " Vous pouvez démarrer la VM et débuter les tests du guide de labo."
echo "========================================================================="
