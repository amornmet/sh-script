#!/bin/bash

#################################
# Script 1: Clone VM
#################################
clone_vm() {
    echo "=== Proxmox Clone VM Script ==="
    echo
    
    read -p "กรอก VMID Template: " TEMPLATE_ID
    read -p "กรอกจำนวน VM ที่ต้องการ Clone: " NUM_CLONES
    read -p "กรอก VMID เริ่มต้น: " VM_START_ID
    
    MAX_VM_PER_NODE=50   # จำนวน VM สูงสุดต่อ Node
    
    # ===============================
    # Detect Datastore (Storage)
    # ===============================
    mapfile -t STORAGES < <(
        pvesh get /storage --output-format json | jq -r '
        .[] |
        select(.enabled != 0) |
        select(.content != null and (.content | tostring | test("(^|,)images(,|$)"))) |
        .storage
        '
    )
    
    
    if [ "${#STORAGES[@]}" -eq 0 ]; then
        echo "❌ ไม่พบ Datastore ที่สามารถใช้เก็บ VM ได้"
        return
    fi
    
    echo
    echo "=== เลือก Datastore ที่จะใช้เก็บ VM ==="
    for i in "${!STORAGES[@]}"; do
        echo " [$((i+1))] ${STORAGES[$i]}"
    done
    echo
    
    while true; do
        read -p "กรอกหมายเลข Datastore: " STORAGE_INDEX
        if [[ "$STORAGE_INDEX" =~ ^[0-9]+$ ]] && \
        [ "$STORAGE_INDEX" -ge 1 ] && \
        [ "$STORAGE_INDEX" -le "${#STORAGES[@]}" ]; then
            DATASTORE="${STORAGES[$((STORAGE_INDEX-1))]}"
            break
        else
            echo "❌ กรุณาเลือกหมายเลขที่ถูกต้อง"
        fi
    done
    
    echo "✅ เลือก Datastore: $DATASTORE"
    echo
    
    # ===============================
    # Auto detect Proxmox Nodes
    # ===============================
    mapfile -t NODES < <(pvesh get /nodes --output-format json | jq -r '.[].node')
    NODE_COUNT=${#NODES[@]}
    
    if [ "$NODE_COUNT" -eq 0 ]; then
        echo "❌ ไม่พบ Node ใน cluster"
        return
    fi
    
    echo "Detected Proxmox Nodes:"
    for n in "${NODES[@]}"; do
        echo " - $n"
    done
    echo
    
    # ตัวแปรนับจำนวน VM ต่อ Node
    declare -A VM_COUNT
    for node in "${NODES[@]}"; do
        VM_COUNT[$node]=0
    done
    
    # ===============================
    # Clone VM Loop
    # ===============================
    for i in $(seq 1 "$NUM_CLONES"); do
        VMID=$((VM_START_ID + i - 1))
        TARGET_NODE=""
        
        # เลือก Node ที่ VM ยังไม่เต็ม
        for node in "${NODES[@]}"; do
            if [ "${VM_COUNT[$node]}" -lt "$MAX_VM_PER_NODE" ]; then
                TARGET_NODE=$node
                break
            fi
        done
        
        if [ -z "$TARGET_NODE" ]; then
            echo "❌ Error: ทุก Node มี VM ครบ $MAX_VM_PER_NODE แล้ว"
            return
        fi
        
        echo "✅ Cloning VMID $VMID → Node: $TARGET_NODE | Storage: $DATASTORE"
        
        qm clone "$TEMPLATE_ID" "$VMID" \
        --name "VM-A-$VMID" \
        --full \
        --storage "$DATASTORE" \
        --target "$TARGET_NODE"
        
        if [ $? -ne 0 ]; then
            echo "❌ Clone VM $VMID ล้มเหลว"
            return
        fi
        
        VM_COUNT[$TARGET_NODE]=$((VM_COUNT[$TARGET_NODE] + 1))
        
        echo "✅ VM $VMID ถูก Clone ไปยัง $TARGET_NODE"
        
        echo "สถานะ VM ต่อ Node:"
        for node in "${NODES[@]}"; do
            echo " - $node: ${VM_COUNT[$node]} VM"
        done
        echo
    done
    
    echo "🎉 การ Clone VM เสร็จสิ้น!"
    
}

#################################
# Script 2: Remove VM
#################################
remove_vm() {
    echo "=== Proxmox Remove VM Script ==="
    echo
    
    # ================= VMID Input (Flexible) =================
    echo "ตัวอย่างการกรอก VMID (รองรับหลายรูปแบบ):"
    echo "แบบที่1  5002"
    echo "แบบที่2  5001 5005"
    echo "แบบที่3  5000-5010"
    echo "แบบที่4  5001 5005-5010 5020"
    echo
    
    read -r -p "VMID: " INPUT
    
    expand_vmids() {
        for part in $INPUT; do
            if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                seq "${part%-*}" "${part#*-}"
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "$part"
            fi
        done
    }
    
    VMIDS=$(expand_vmids)
    
    if [ -z "$VMIDS" ]; then
        echo "❌ ไม่พบ VMID ที่ถูกต้อง"
        return
    fi
    
    echo
    echo "⚠️ VM ที่จะถูกลบ:"
    echo "$VMIDS"
    echo
    
    read -r -p "พิมพ์ YES เพื่อยืนยันการลบ VM: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "❌ ยกเลิกการทำงาน"
        return
    fi
    
    echo
    echo "Remove VM (Auto detect node)"
    echo "===================================="
    
    # ================= Remove Process =================
    for VMID in $VMIDS; do
        echo
        
        VM_NODE=$(pvesh get /cluster/resources --type vm --output-format json \
        | jq -r ".[] | select(.vmid==$VMID) | .node")
        
        if [ -z "$VM_NODE" ]; then
            echo "❌ ไม่พบ VMID $VMID ใน cluster"
            continue
        fi
        
        echo "📍 Destroying VM $VMID on node: $VM_NODE"
        
        # stop VM ก่อน (ถ้ายังรันอยู่)
        pvesh create /nodes/$VM_NODE/qemu/$VMID/status/stop &>/dev/null
        
        # destroy VM ผ่าน API (ข้าม node ได้จริง)
        pvesh delete /nodes/$VM_NODE/qemu/$VMID \
        --destroy-unreferenced-disks 1
        
        if [ $? -eq 0 ]; then
            echo "✅ VM $VMID ถูกลบเรียบร้อย"
        else
            echo "❌ ลบ VM $VMID ล้มเหลว"
        fi
    done
    
    echo
    echo "🎉 การ Remove VM เสร็จสิ้น!"
    
}

#################################
# Script 3: Protect RBD Snapshot
#################################
protect_snapshot() {
    GREEN="\033[1;32m"
    RED="\033[1;31m"
    YELLOW="\033[1;33m"
    RESET="\033[0m"
    
    SUCCESS=0
    FAILED=0
    SKIPPED=0
    TOTAL=0
    
    echo "=== Ceph RBD Snapshot PROTECT Script ==="
    echo
    
    # ================= Detect RBD Pools =================
    mapfile -t POOLS < <(ceph osd pool ls)
    
    if [ ${#POOLS[@]} -eq 0 ]; then
        echo -e "${RED}ไม่พบ Ceph pool ใด ๆ${RESET}"
        return
    fi
    
    echo "เลือก RBD Pool:"
    for i in "${!POOLS[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${POOLS[$i]}"
    done
    
    echo
    read -r -p "กรอกหมายเลข Pool: " POOL_NUM
    
    if ! [[ "$POOL_NUM" =~ ^[0-9]+$ ]] || \
    [ "$POOL_NUM" -lt 1 ] || \
    [ "$POOL_NUM" -gt "${#POOLS[@]}" ]; then
        echo -e "${RED}เลือก Pool ไม่ถูกต้อง${RESET}"
        return
    fi
    
    POOL="${POOLS[$((POOL_NUM-1))]}"
    
    echo
    echo "Pool ที่เลือก: $POOL"
    echo
    
    # ================= VMID Input (Flexible) =================
    echo "ตัวอย่างการกรอก VMID (รองรับหลายรูปแบบ):"
    echo "แบบที่1  5002"
    echo "แบบที่2  5001 5005"
    echo "แบบที่3  5000-5010"
    echo "แบบที่4  5001 5005-5010 5020"
    echo
    
    read -r -p "VMID: " INPUT
    
    expand_vmids() {
        for part in $INPUT; do
            if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                seq "${part%-*}" "${part#*-}"
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "$part"
            fi
        done
    }
    
    VMIDS=$(expand_vmids)
    
    if [ -z "$VMIDS" ]; then
        echo -e "${RED}ไม่พบ VMID ที่ถูกต้อง${RESET}"
        return
    fi
    
    echo
    echo "Protecting RBD snapshots"
    echo "VMID : $VMIDS"
    echo "==================================================="
    
    # ================= Protect Process =================
    for VMID in $VMIDS; do
        IMAGES=$(rbd ls "$POOL" 2>/dev/null | grep "^vm-${VMID}-disk-")
        
        for img in $IMAGES; do
            echo -e "\n==> VMID: $VMID | Image: $POOL/$img"
            
            SNAPS=$(rbd snap ls "$POOL/$img" --format plain | awk '{print $2}' | tail -n +2)
            
            for snap in $SNAPS; do
                TOTAL=$((TOTAL+1))
                echo -n "  → Protecting: $POOL/$img@$snap ... "
                
                ERR=$(rbd snap protect "$POOL/$img@$snap" 2>&1)
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}SUCCESS${RESET}"
                    SUCCESS=$((SUCCESS+1))
                    
                    elif echo "$ERR" | grep -qi "already protected"; then
                    echo -e "${YELLOW}SKIPPED (already protected)${RESET}"
                    SKIPPED=$((SKIPPED+1))
                    
                else
                    echo -e "${RED}FAILED${RESET}"
                    echo "      Error: $ERR"
                    FAILED=$((FAILED+1))
                fi
            done
        done
    done
    
    echo
    echo "==================== SUMMARY ===================="
    echo "Total snapshots : $TOTAL"
    echo -e "${GREEN}Success         : $SUCCESS${RESET}"
    echo -e "${YELLOW}Skipped         : $SKIPPED${RESET}"
    echo -e "${RED}Failed          : $FAILED${RESET}"
    echo "================================================"
    
    
}

#################################
# Script 4: Unprotect RBD Snapshot
#################################
unprotect_snapshot() {
    #!/bin/bash
    
    GREEN="\033[1;32m"
    RED="\033[1;31m"
    YELLOW="\033[1;33m"
    RESET="\033[0m"
    
    SUCCESS=0
    FAILED=0
    SKIPPED=0
    TOTAL=0
    
    echo "=== Ceph RBD Snapshot UNPROTECT Script ==="
    echo
    
    # ================= Detect RBD Pools =================
    mapfile -t POOLS < <(ceph osd pool ls)
    
    if [ ${#POOLS[@]} -eq 0 ]; then
        echo -e "${RED}ไม่พบ Ceph pool ใด ๆ${RESET}"
        return
    fi
    
    echo "เลือก RBD Pool:"
    for i in "${!POOLS[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${POOLS[$i]}"
    done
    
    echo
    read -r -p "กรอกหมายเลข Pool: " POOL_NUM
    
    if ! [[ "$POOL_NUM" =~ ^[0-9]+$ ]] || \
    [ "$POOL_NUM" -lt 1 ] || \
    [ "$POOL_NUM" -gt "${#POOLS[@]}" ]; then
        echo -e "${RED}เลือก Pool ไม่ถูกต้อง${RESET}"
        return
    fi
    
    POOL="${POOLS[$((POOL_NUM-1))]}"
    
    echo
    echo "Pool ที่เลือก: $POOL"
    echo
    
    # ================= VMID Input (Flexible) =================
    echo "ตัวย่างการกรอก VMID (รองรับหลายรูปแบบ):"
    echo "แบบที่1  5002"
    echo "แบบที่2  5001 5005"
    echo "แบบที่3  5000-5010"
    echo "แบบที่4  5001 5005-5010 5020"
    echo
    
    read -r -p "VMID: " INPUT
    
    expand_vmids() {
        for part in $INPUT; do
            if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                seq "${part%-*}" "${part#*-}"
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "$part"
            fi
        done
    }
    
    VMIDS=$(expand_vmids)
    
    if [ -z "$VMIDS" ]; then
        echo -e "${RED}ไม่พบ VMID ที่ถูกต้อง${RESET}"
        return
    fi
    
    echo
    echo "Unprotecting RBD snapshots"
    echo "VMID : $VMIDS"
    echo "==================================================="
    
    # ================= Unprotect Process =================
    for VMID in $VMIDS; do
        IMAGES=$(rbd ls "$POOL" 2>/dev/null | grep "^vm-${VMID}-disk-")
        
        for img in $IMAGES; do
            echo -e "\n==> VMID: $VMID | Image: $POOL/$img"
            
            SNAPS=$(rbd snap ls "$POOL/$img" --format plain | awk '{print $2}' | tail -n +2)
            
            for snap in $SNAPS; do
                TOTAL=$((TOTAL+1))
                echo -n "  → Unprotecting: $POOL/$img@$snap ... "
                
                ERR=$(rbd snap unprotect "$POOL/$img@$snap" 2>&1)
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}SUCCESS${RESET}"
                    SUCCESS=$((SUCCESS+1))
                    
                    elif echo "$ERR" | grep -qiE "not protected|already unprotected"; then
                    echo -e "${YELLOW}SKIPPED (already unprotected)${RESET}"
                    SKIPPED=$((SKIPPED+1))
                    
                else
                    echo -e "${RED}FAILED${RESET}"
                    echo "      $ERR"
                    FAILED=$((FAILED+1))
                fi
            done
        done
    done
    
    echo
    echo "==================== SUMMARY ===================="
    echo "Total snapshots : $TOTAL"
    echo -e "${GREEN}Success         : $SUCCESS${RESET}"
    echo -e "${YELLOW}Skipped         : $SKIPPED${RESET}"
    echo -e "${RED}Failed          : $FAILED${RESET}"
    echo "================================================"
    
}

#################################
# Script 5: Status RBD Snapshot
#################################
status_snapshot() {
    echo "=== List Ceph RBD Snapshots ==="
    echo
    
    # ---------- Detect RBD Pools ----------
    mapfile -t POOLS < <(ceph osd pool ls)
    
    if [ "${#POOLS[@]}" -eq 0 ]; then
        echo "ไม่พบ Ceph pool"
        return
    fi
    
    echo "เลือก RBD Pool:"
    for i in "${!POOLS[@]}"; do
        echo "  $((i+1))) ${POOLS[$i]}"
    done
    
    echo
    read -r -p "กรอกหมายเลข Pool: " POOL_NUM
    
    if ! [[ "$POOL_NUM" =~ ^[0-9]+$ ]] || \
    [ "$POOL_NUM" -lt 1 ] || \
    [ "$POOL_NUM" -gt "${#POOLS[@]}" ]; then
        echo "เลือก Pool ไม่ถูกต้อง"
        return
    fi
    
    POOL="${POOLS[$((POOL_NUM-1))]}"
    
    echo
    echo "Pool ที่เลือก: $POOL"
    echo
    
    # ---------- VMID Input ----------
    echo "ตัวอย่างการกรอก VMID (รองรับหลายรูปแบบ):"
    echo "แบบที่1  5002"
    echo "แบบที่2  5001 5005"
    echo "แบบที่3  5000-5010"
    echo
    
    read -r -p "VMID: " INPUT
    
    expand_vmids() {
        for part in $INPUT; do
            if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                seq "${part%-*}" "${part#*-}"
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "$part"
            fi
        done
    }
    
    VMIDS=$(expand_vmids)
    
    echo
    echo "Listing RBD snapshots"
    echo "============================================================"
    
    # ---------- List Snapshots ----------
    for VMID in $VMIDS; do
        IMAGES=$(rbd ls "$POOL" | grep "^vm-${VMID}-disk-")
        
        for img in $IMAGES; do
            echo
            echo "==> VMID: $VMID | Image: $POOL/$img"
            rbd snap ls "$POOL/$img"
        done
    done
    
    
}
#################################
# Script 6: Remove RBD Snapshot
#################################
remove_snapshot_proxmox() {
    echo "=== Proxmox Snapshot Management Script ==="
    echo
    
    # ================= VMID Input (Flexible) =================
    echo "ตัวอย่างการกรอก VMID (รองรับหลายรูปแบบ):"
    echo "แบบที่1  5002"
    echo "แบบที่2  5001 5005"
    echo "แบบที่3  5000-5010"
    echo "แบบที่4  5001 5005-5010 5020"
    echo
    
    read -r -p "VMID: " INPUT
    
    expand_vmids() {
        for part in $INPUT; do
            if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                seq "${part%-*}" "${part#*-}"
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "$part"
            fi
        done
    }
    
    VMIDS=$(expand_vmids)
    
    if [ -z "$VMIDS" ]; then
        echo "❌ ไม่พบ VMID ที่ถูกต้อง"
        return
    fi
    
    # ================= Mode Selection =================
    echo
    echo "เลือกโหมดการจัดการ snapshot:"
    echo "  [1] เก็บ snapshot ล่าสุดไว้ N point (Retention)"
    echo "  [2] ลบ snapshot ทั้งหมด (Delete all)"
    echo
    
    read -p "เลือกโหมด [1-2]: " MODE
    
    case "$MODE" in
        1)
            read -p "ต้องการเก็บ snapshot ล่าสุดกี่ point?: " KEEP
            if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
                echo "❌ จำนวน point ต้องเป็นตัวเลข ≥ 1"
                return
            fi
            MODE_DESC="Retention (keep last $KEEP snapshots)"
        ;;
        2)
            KEEP=0
            MODE_DESC="Delete ALL snapshots"
        ;;
        *)
            echo "❌ เลือกโหมดไม่ถูกต้อง"
            return
        ;;
    esac
    
    echo
    echo "⚠️ สรุปการทำงาน:"
    echo "VMID:"
    echo "$VMIDS"
    echo "โหมด: $MODE_DESC"
    echo
    
    read -r -p "พิมพ์ YES เพื่อยืนยันการทำงาน: " CONFIRM
    [ "$CONFIRM" != "YES" ] && echo "❌ ยกเลิกการทำงาน" && return
    
    echo
    echo "Snapshot Management (Auto detect node)"
    echo "===================================="
    
    # ================= Snapshot Process =================
    for VMID in $VMIDS; do
        echo
        echo "✅ VM $VMID"
        
        VM_NODE=$(pvesh get /cluster/resources --type vm --output-format json \
        | jq -r ".[] | select(.vmid==$VMID) | .node")
        
        if [ -z "$VM_NODE" ]; then
            echo "❌ VM $VMID not found in cluster, skip"
            continue
        fi
        
        echo "📍 VM อยู่ที่ node: $VM_NODE"
        
        # ดึง snapshot (ตัด current) + เรียงตามเวลาเก่า → ใหม่
        mapfile -t SNAPS < <(
            pvesh get /nodes/$VM_NODE/qemu/$VMID/snapshot \
            --output-format json |
            jq -r '
            .[]
            | select(.name != "current")
            | "\(.snaptime) \(.name)"
            ' | sort -n | awk '{print $2}'
        )
        
        SNAP_COUNT=${#SNAPS[@]}
        
        if [ "$SNAP_COUNT" -eq 0 ]; then
            echo "ℹ️ ไม่มี snapshot"
            continue
        fi
        
        if [ "$MODE" -eq 1 ]; then
            if [ "$SNAP_COUNT" -le "$KEEP" ]; then
                echo "ℹ️ มี snapshot $SNAP_COUNT ตัว (≤ $KEEP) ไม่ต้องลบ"
                continue
            fi
            DELETE_COUNT=$((SNAP_COUNT - KEEP))
            echo "📦 Snapshot ทั้งหมด: $SNAP_COUNT"
            echo "🗑️ จะลบ snapshot เก่า $DELETE_COUNT ตัว:"
        else
            DELETE_COUNT=$SNAP_COUNT
            echo "⚠️ จะลบ snapshot ทั้งหมด $SNAP_COUNT ตัว:"
        fi
        
        for ((i=0; i<DELETE_COUNT; i++)); do
            echo "   - ${SNAPS[$i]}"
        done
        
        for ((i=0; i<DELETE_COUNT; i++)); do
            SNAP="${SNAPS[$i]}"
            echo -n "🔥 Deleting snapshot $SNAP ... "
            
            pvesh delete /nodes/$VM_NODE/qemu/$VMID/snapshot/$SNAP &>/dev/null
            if [ $? -eq 0 ]; then
                echo "✅ OK"
            else
                echo "❌ FAILED"
            fi
        done
    done
    
    echo
    echo "🎉 Snapshot management เสร็จสิ้น!"
    
}

#################################
# Script 8: RBD Mirror Status
#################################
remove_snapshot_ceph() {
    echo "=== Ceph RBD Snapshot Management Script ==="
    echo
    
    # ================= VMID Input (Flexible) =================
    echo "ตัวอย่างการกรอก VMID (รองรับหลายรูปแบบ):"
    echo "แบบที่1  5002"
    echo "แบบที่2  5001 5005"
    echo "แบบที่3  5000-5010"
    echo "แบบที่4  5001 5005-5010 5020"
    echo
    
    read -r -p "VMID: " INPUT
    
    expand_vmids() {
        for part in $INPUT; do
            if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                seq "${part%-*}" "${part#*-}"
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "$part"
            fi
        done
    }
    
    VMIDS=$(expand_vmids)
    
    if [ -z "$VMIDS" ]; then
        echo "❌ ไม่พบ VMID ที่ถูกต้อง"
        return
    fi
    
    # ================= Mode Selection =================
    echo
    echo "เลือกโหมดการจัดการ RBD snapshot:"
    echo "  [1] เก็บ snapshot ล่าสุดไว้ N point (Retention)"
    echo "  [2] ลบ snapshot ทั้งหมด (Delete all)"
    echo
    
    read -p "เลือกโหมด [1-2]: " MODE
    
    case "$MODE" in
        1)
            read -p "ต้องการเก็บ snapshot ล่าสุดกี่ point?: " KEEP
            if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
                echo "❌ จำนวน point ต้องเป็นตัวเลข ≥ 1"
                return
            fi
            MODE_DESC="Retention (keep last $KEEP snapshots)"
        ;;
        2)
            KEEP=0
            MODE_DESC="Delete ALL snapshots"
        ;;
        *)
            echo "❌ เลือกโหมดไม่ถูกต้อง"
            return
        ;;
    esac
    
    echo
    echo "⚠️ สรุปการทำงาน:"
    echo "VMID:"
    echo "$VMIDS"
    echo "โหมด: $MODE_DESC"
    echo
    
    read -r -p "พิมพ์ YES เพื่อยืนยันการทำงาน: " CONFIRM
    [ "$CONFIRM" != "YES" ] && echo "❌ Cancelled" && return
    
    # ================= Detect Pools =================
    POOLS=$(ceph osd lspools 2>/dev/null | awk '{print $2}')
    
    if [ -z "$POOLS" ]; then
        echo "❌ ไม่พบ Ceph pool"
        return
    fi
    
    echo
    echo "Ceph RBD Snapshot Management"
    echo "===================================="
    
    FOUND_DISK=0
    FOUND_SNAP=0
    
    # ================= Process =================
    for VMID in $VMIDS; do
        echo
        echo "🖥️ VMID: $VMID"
        
        for pool in $POOLS; do
            DISKS=$(rbd ls "$pool" 2>/dev/null | grep "^vm-$VMID-disk-")
            [ -z "$DISKS" ] && continue
            
            FOUND_DISK=1
            echo "  📦 Pool: $pool"
            
            for disk in $DISKS; do
                # ดึง snapshot เรียงจากเก่า → ใหม่ (ตาม SNAPID)
                mapfile -t SNAPS < <(
                    rbd snap ls "$pool/$disk" 2>/dev/null |
                    awk 'NR>1 {print $1, $2}' |
                    sort -n |
                    awk '{print $2}'
                )
                
                SNAP_COUNT=${#SNAPS[@]}
                
                if [ "$SNAP_COUNT" -eq 0 ]; then
                    echo "    ℹ️ $disk : ไม่มี snapshot"
                    continue
                fi
                
                FOUND_SNAP=1
                
                if [ "$MODE" -eq 1 ]; then
                    if [ "$SNAP_COUNT" -le "$KEEP" ]; then
                        echo "    ℹ️ $disk : snapshot $SNAP_COUNT ตัว (≤ $KEEP) ไม่ต้องลบ"
                        continue
                    fi
                    DELETE_COUNT=$((SNAP_COUNT - KEEP))
                    echo "    🗑️ $disk : จะลบ snapshot เก่า $DELETE_COUNT ตัว"
                else
                    DELETE_COUNT=$SNAP_COUNT
                    echo "    ⚠️ $disk : จะลบ snapshot ทั้งหมด $SNAP_COUNT ตัว"
                fi
                
                for ((i=0; i<DELETE_COUNT; i++)); do
                    SNAP="${SNAPS[$i]}"
                    echo -n "      🔥 Deleting $pool/$disk@$SNAP ... "
                    rbd snap rm "$pool/$disk@$SNAP" &>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "✅ OK"
                    else
                        echo "❌ FAILED"
                    fi
                done
            done
        done
    done
    
    if [ "$FOUND_DISK" -eq 0 ]; then
        echo
        echo "❌ ไม่พบ RBD disk ของ VMID ที่ระบุ"
        return
    fi
    
    if [ "$FOUND_SNAP" -eq 0 ]; then
        echo
        echo "ℹ️ ไม่พบ snapshot ใด ๆ"
        return
    fi
    
    echo
    echo "🎉 Ceph RBD snapshot management เสร็จสิ้น!"
    
    
}

#################################
# Script 8: RBD Mirror Status
#################################
mirror_status() {
    #!/bin/bash
    
    GREEN="\033[1;32m"
    RED="\033[1;31m"
    RESET="\033[0m"
    
    echo "=== Ceph RBD Mirror Pool Status ==="
    echo
    
    # ================= Detect mirrored pools =================
    mapfile -t ALL_POOLS < <(ceph osd pool ls 2>/dev/null)
    
    MIRROR_POOLS=()
    
    for p in "${ALL_POOLS[@]}"; do
        if rbd mirror pool status "$p" &>/dev/null; then
            MIRROR_POOLS+=("$p")
        fi
    done
    
    if [ ${#MIRROR_POOLS[@]} -eq 0 ]; then
        echo -e "${RED}❌ ไม่พบ pool ที่เปิดใช้งาน rbd mirror${RESET}"
        return
    fi
    
    echo "เลือก Datastore / Pool ที่ต้องการตรวจสอบ:"
    for i in "${!MIRROR_POOLS[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${MIRROR_POOLS[$i]}"
    done
    
    echo
    read -p "กรอกหมายเลข Pool: " POOL_NUM
    
    if ! [[ "$POOL_NUM" =~ ^[0-9]+$ ]] || \
    [ "$POOL_NUM" -lt 1 ] || \
    [ "$POOL_NUM" -gt "${#MIRROR_POOLS[@]}" ]; then
        echo -e "${RED}❌ เลือก Pool ไม่ถูกต้อง${RESET}"
        return
    fi
    
    POOL="${MIRROR_POOLS[$((POOL_NUM-1))]}"
    
    echo
    echo "📦 Pool ที่เลือก: $POOL"
    echo "===================================================="
    echo
    
    # ================= Mirror Status =================
    rbd mirror pool status "$POOL" --verbose | awk '
BEGIN {
  GREEN = "\033[1;32m"
  RED   = "\033[1;31m"
  RESET = "\033[0m"
}

/^IMAGES$/ { in_image = 1; next }

!in_image { print; next }

/^[^ ]/ && /:/ {
  image=$1
  in_peer = 0
  state_local = desc_local = state_peer = desc_peer = ""
}

/^  state:/ && !in_peer { state_local = $2 }
/^  description:/ && !in_peer { desc_local = substr($0, index($0, $2)) }

/^  peer_sites:/ { in_peer = 1; next }

in_peer && /^    state:/ { state_peer = $2 }
/^    description:/ && in_peer {
  desc_peer = substr($0, index($0, $2))

  color = GREEN
  if (state_local ~ /error/ || desc_local ~ /error/ ||
      state_peer  ~ /error/ || desc_peer  ~ /error/)
    color = RED

  printf "%s%s%s\n", color, image, RESET
  print "  [local] state:       " state_local
  print "  [local] description: " desc_local
  print "  [peer]  state:       " state_peer
  print "  [peer]  description: " desc_peer
  print ""

  in_peer = 0
}
    '
    
}

#################################
# Main Menu
#################################
while true; do
    clear
    echo "=========== Proxmox Admin Menu ==========="
    echo "1) Clone VM"
    echo "2) Remove VM"
    echo "3) Protect RBD Snapshots"
    echo "4) Unprotect RBD Snapshots"
    echo "5) Status RBD Snapshots"
    echo "6) Remove Proxmox Snapshots"
    echo "7) Remove Ceph RBD Snapshots"
    echo "8) Check RBD Mirror Status"
    echo "0) Exit"
    echo "=========================================="
    read -p "Select menu [0-8]: " MENU
    
    case $MENU in
        1)
            clone_vm
            read -p "Press Enter to return to menu..."
        ;;
        2)
            remove_vm
            read -p "Press Enter to return to menu..."
        ;;
        3)
            protect_snapshot
            read -p "Press Enter to return to menu..."
        ;;
        4)
            unprotect_snapshot
            read -p "Press Enter to return to menu..."
        ;;
        5)
            status_snapshot
            read -p "Press Enter to return to menu..."
        ;;
        6)
            remove_snapshot_proxmox
            read -p "Press Enter to return to menu..."
        ;;
        7)
            remove_snapshot_ceph
            read -p "Press Enter to return to menu..."
        ;;
        8)
            mirror_status
            read -p "Press Enter to return to menu..."
        ;;
        0)
            echo "Bye 👋"
            break
        ;;
        *)
            echo "❌ Invalid selection"
            sleep 1
        ;;
    esac
done
