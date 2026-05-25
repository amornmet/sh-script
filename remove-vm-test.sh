#!/bin/bash

# กำหนดรหัสสีสำหรับแสดงผลบน Terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color (ล้างค่าสี)

echo -e "${CYAN}🔍 กำลังดึงรายชื่อ VM ทั้งหมดบน Node นี้...${NC}"
echo "----------------------------------------"

VM_ARRAY=()

# ดึงข้อมูลผ่าน pvesh คล้ายระบบ API ของ Proxmox เพื่อตัดปัญหารูปแบบตาราง qm list เลื่อนถาวร
# วิธีนี้ทำผ่าน Command Line ล้วนๆ และได้ค่าที่เสถียรที่สุด
while IFS= read -r line; do
    if [ -z "$line" ]; then
        continue
    fi
    
    # ดึงค่า VMID, Name, และ Status ออกมาจากโครงสร้างระบบ
    VM_ID=$(echo "$line" | awk '{print $1}')
    VM_STAT=$(echo "$line" | awk '{print $2}')
    
    # กรณีที่ qm list ของบางเวอร์ชันเอาสถานะไว้หน้าชื่อ ให้เราเช็กและสลับสลับตำแหน่งให้ถูกต้อง
    if [[ "$VM_STAT" == "running" ]] || [[ "$VM_STAT" == "stopped" ]]; then
        # คอลัมน์ที่ 2 เป็นสถานะ -> ดังนั้นชื่อจริงจะเริ่มตั้งแต่คอลัมน์ที่ 3 เป็นต้นไป
        # ตัดเอาคำที่ 3 ของบรรทัดมาเป็นชื่อแทน
        VM_NAME=$(echo "$line" | awk '{print $3}')
    else
        # คอลัมน์ที่ 2 เป็นชื่อ -> สถานะจะถูกดันไปอยู่คอลัมน์ท้ายๆ
        VM_NAME="$VM_STAT"
        VM_STAT=$(echo "$line" | awk '{print $NF}')
    fi

    # เผื่อกรณีหาชื่อไม่พบ หรือชื่ออ่านไม่ออก ให้ตั้งค่าสำรองไว้
    if [ -z "$VM_NAME" ] || [[ "$VM_NAME" == "running" ]] || [[ "$VM_NAME" == "stopped" ]]; then
        # หากชื่อยังหลุดเป็นคำว่า running/stopped ให้ลองดึงจากคำสั่งเฉพาะตัว
        VM_NAME=$(pvesh get /nodes/localhost/qemu/$VM_ID/config --output-format posix 2>/dev/null | grep -E "^name:" | awk '{print $2}')
        if [ -z "$VM_NAME" ]; then
            VM_NAME="VM-$VM_ID"
        fi
    fi
    
    # ดักจับสถานะให้เป็นตัวพิมพ์เล็กมาตรฐานเพื่อนำไปเช็กสี
    if [[ "$line" =~ "running" ]]; then
        VM_STAT="running"
    else
        VM_STAT="stopped"
    fi
    
    # เก็บข้อมูลลง Array รูปแบบ VMID:Name:Status
    VM_ARRAY+=("$VM_ID:$VM_NAME:$VM_STAT")
done < <(qm list | awk 'NR>1')

# ตรวจสอบว่ามี VM อยู่ใน Node ไหม
if [ ${#VM_ARRAY[@]} -eq 0 ]; then
    echo -e "${RED}❌ ไม่พบ VM ใดๆ บน Node นี้${NC}"
    exit 1
fi

# แสดงเมนูให้ผู้ใช้เลือกตามรูปแบบที่คุณระบุเป๊ะๆ
echo -e "${YELLOW}📋 กรุณาเลือก VM ที่ต้องการลบ (สามารถเลือกได้มากกว่า 1 ตัว โดยใช้ช่องว่างเว้นวรรค เช่น: 1 3 5)${NC}"
echo "----------------------------------------"
for i in "${!VM_ARRAY[@]}"; do
    VM_ID=$(echo "${VM_ARRAY[$i]}" | cut -d':' -f1)
    VM_NAME=$(echo "${VM_ARRAY[$i]}" | cut -d':' -f2)
    VM_STAT=$(echo "${VM_ARRAY[$i]}" | cut -d':' -f3)
    
    # ตรวจสอบสถานะจริงเพื่อพ่นสีที่ชื่อ VM
    if [ "$VM_STAT" = "running" ]; then
        NAME_DISPLAY="${GREEN}${VM_NAME}${NC}"  # ชื่อเป็นสีเขียวถ้าเปิดอยู่
    else
        NAME_DISPLAY="${RED}${VM_NAME}${NC}"    # ชื่อเป็นสีแดงถ้าปิดอยู่
    fi
    
    # พิมพ์ผลลัพธ์ตาม Format: [ 1] VMID: 100 | ชื่อ: web-server
    printf "[%2d] VMID: %-4s | ชื่อ: %b\n" "$((i+1))" "$VM_ID" "$NAME_DISPLAY"
done
echo "----------------------------------------"

# รับค่าอินพุตจากผู้ใช้
read -p "👉 ใส่หมายเลขที่ต้องการลบ: " USER_INPUT

# ตรวจสอบว่าผู้ใช้ได้กรอกอะไรมาไหม
if [ -z "$USER_INPUT" ]; then
    echo -e "${RED}❌ ยกเลิกการทำงานเนื่องจากไม่มีการเลือกหมายเลข${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}⚠️  คุณเลือกหมายเลข: $USER_INPUT${NC}"
echo -e "${RED}💣 คุณแน่ใจจริงๆ ใช่ไหมว่าจะลบ VM เหล่านี้? ข้อมูลจะหายถาวร! (y/N): ${NC}"
read -r FINAL_CONFIRM
if [[ ! "$FINAL_CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}⏭️  ยกเลิกการลบทั้งหมด${NC}"
    exit 0
fi

# วนลูปตามหมายเลขที่ผู้ใช้กรอกเข้ามาเพื่อลบ
for CHOICE in $USER_INPUT; do
    if [[ ! "$CHOICE" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}⚠️  ❌ '$CHOICE' ไม่ใช่หมายเลขที่ถูกต้อง (ข้าม)${NC}"
        continue
    fi

    INDEX=$((CHOICE-1))

    if [ $INDEX -lt 0 ] || [ $INDEX -ge ${#VM_ARRAY[@]} ]; then
        echo -e "${YELLOW}⚠️  ❌ หมายเลข [$CHOICE] ไม่อยู่ในรายการที่มี (ข้าม)${NC}"
        continue
    fi

    VM_ID=$(echo "${VM_ARRAY[$INDEX]}" | cut -d':' -f1)
    VM_NAME=$(echo "${VM_ARRAY[$INDEX]}" | cut -d':' -f2)
    VM_STAT=$(echo "${VM_ARRAY[$INDEX]}" | cut -d':' -f3)

    echo "----------------------------------------"
    echo -e "${CYAN}⏳ [กำลังจัดการ] VM: $VM_NAME (VMID: $VM_ID)${NC}"
    
    # สั่งหยุด VM ก่อนลบ (เฉพาะกรณีที่สถานะเบื้องหลังระบุว่า running)
    if [ "$VM_STAT" = "running" ]; then
        echo "🛑 VM กำลังเปิดอยู่.. กำลังสั่ง Stop VM..."
        qm stop $VM_ID 2>/dev/null
        sleep 2
    fi
    
    # สั่งลบ VM
    echo "🗑️  กำลังสั่ง Destroy VM..."
    qm destroy $VM_ID
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ ลบ VM: $VM_NAME [ID: $VM_ID] สำเร็จ!${NC}"
    else
        echo -e "${RED}❌ เกิดข้อผิดพลาดในการลบ VMID: $VM_ID${NC}"
    fi
done

echo "----------------------------------------"
echo -e "${GREEN}🎉 เสร็จสิ้นกระบวนการเลือกลบ VM เรียบร้อยแล้ว${NC}"