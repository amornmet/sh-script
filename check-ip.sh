#!/bin/bash

# --- โค้ดสี ---
GREEN='\033[0;32m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

clear
echo -e "${BLUE}${BOLD}=========================================="
echo -e "       IP SCANNER (CLEAN FILENAME)"
echo -e "==========================================${NC}"
echo -en "${YELLOW}Enter Network (e.g., 192.168.1.0/24): ${NC}"
read INPUT_NETWORK

# 1. ลบช่องว่างที่อาจติดมาจากการ Copy/Paste
FULL_NETWORK=$(echo $INPUT_NETWORK | xargs)

if [ -z "$FULL_NETWORK" ]; then
    echo -e "${RED}Error: Network cannot be empty!${NC}"
    exit 1
fi

# 2. จัดการชื่อไฟล์ให้ไม่มีช่องว่างและตัวอักษรพิเศษที่ Linux ไม่ชอบ
# เปลี่ยน / เป็น - และลบจุดในส่วนของ subnet เพื่อความสะอาด
FILE_TAG=$(echo $FULL_NETWORK | sed 's/\//-/g' | tr -d ' ')
PREFIX=$(echo $FULL_NETWORK | cut -d. -f1-3)

TARGET_DIR="./ip_checks"
DATE=$(date +%Y-%m-%d)
mkdir -p "$TARGET_DIR"

# 3. กำหนดชื่อไฟล์แบบ Clean (ไม่มีช่องว่าง หน้า-หลัง)
USED_FILE="${TARGET_DIR}/used_ips_${FILE_TAG}_${DATE}.txt"
FREE_FILE="${TARGET_DIR}/free_ips_${FILE_TAG}_${DATE}.txt"

> "$USED_FILE"
> "$FREE_FILE"

count_used=0
count_free=0
total_ips=254

echo -e "\n${BOLD}Scanning: $FULL_NETWORK${NC}"

for ip in {1..254}; do
    current_ip="$PREFIX.$ip"
    percent=$(( $ip * 100 / $total_ips ))
    echo -ne "Progress: ${YELLOW}$percent%${NC} ($current_ip) \r"

    if ping -c 1 -W 0.5 $current_ip > /dev/null 2>&1; then
        ((count_used++))
        mac_addr=$(arp -n $current_ip | grep $current_ip | awk '{print $3}')
        [ -z "$mac_addr" ] || [ "$mac_addr" == "<incomplete>" ] && mac_addr="Unknown"

        echo -e "$current_ip | MAC: ${PURPLE}$mac_addr${NC}" >> "$USED_FILE"
    else
        ((count_free++))
        echo "$current_ip" >> "$FREE_FILE"
    fi
done

echo -e "\n"
echo "--------------------------------------------------"
echo -e "  Used IPs : ${GREEN}$count_used${NC} -> $(basename "$USED_FILE")"
echo -e "  Free IPs : ${RED}$count_free${NC} -> $(basename "$FREE_FILE")"
echo "--------------------------------------------------"