#!/bin/bash

read -p "Enter pool site [a/b]?: " POOL

# ใส่ 2>&1 เพื่อดึงเอา Standard Error (Log ค้นหาไฟล์ไม่เจอ) ส่งเข้า awk ด้วย
rbd mirror pool status data-site-"$POOL"01 --verbose 2>&1 | awk '
BEGIN {
  GREEN = "\033[1;32m"
  RED = "\033[1;31m"
  YELLOW = "\033[1;33m"
  RESET = "\033[0m"
  
  # ตัวนับสถานะต่างๆ
  ok_count = 0
  failed_count = 0
  nosuch_count = 0
}

# ดักจับและนับพวกบรรทัด Error ที่แจ้งว่าหาไฟล์ไม่เจอ (No such file or directory)
/^[0-9]{4}-[0-9]{2}-[0-9]{2}/ || /^rbd: failed to open/ {
  if ($0 ~ /failed to open image/) {
    match($0, /failed to open image [^:]+/)
    if (RSTART > 0) {
      img_name = substr($0, RSTART + 20, RLENGTH - 20)
      
      # ตรวจสอบเพื่อไม่ให้เก็บชื่อซ้ำ
      is_duplicate = 0
      for (i = 1; i <= nosuch_count; i++) {
        if (nosuch_images[i] == img_name) {
          is_duplicate = 1
          break
        }
      }
      
      if (!is_duplicate) {
        nosuch_count++
        nosuch_images[nosuch_count] = img_name
      }
    }
  }
  next
}

/^IMAGES$/ {
  in_image = 1
  next
}

!in_image {
  print $0
  next
}

/^[^ ]/ && /:/ {
  image=$1
  in_peer = 0
  state_local = ""
  desc_local = ""
  state_peer = ""
  desc_peer = ""
}

/^  state:/ && !in_peer {
  state_local = $2
}

/^  description:/ && !in_peer {
  desc_local = substr($0, index($0, $2))
}

/^  peer_sites:/ {
  in_peer = 1
  next
}

in_peer && /^    state:/ {
  state_peer = $2
}

/^    description:/ && in_peer {
  desc_peer = substr($0, index($0, $2))

  # ตรวจสอบว่ามีคำว่า error หรือไม่
  is_error = 0
  err_reason = ""
  
  if (state_local ~ /error/ || desc_local ~ /error/) {
    is_error = 1
    err_reason = "[Local] " state_local " - " desc_local
  }
  if (state_peer ~ /error/ || desc_peer ~ /error/) {
    is_error = 1
    # ถ้ามี error ทั้งคู่ให้คั่นด้วยเครื่องหมาย /
    if (err_reason != "") { err_reason = err_reason " / " }
    err_reason = err_reason "[Peer] " state_peer " - " desc_peer
  }

  # คัดแยกหมวดหมู่และเก็บข้อมูล
  if (is_error) {
    failed_count++
    failed_images[failed_count] = image
    failed_reasons[failed_count] = err_reason
    color = RED
  } else {
    ok_count++
    color = GREEN
  }

  # พิมพ์รายละเอียดรายตัวระหว่างการรัน
  printf "%s%s%s\n", color, image, RESET
  print "  [local] state:       " state_local
  print "  [local] description: " desc_local
  print "  [peer]  state:       " state_peer
  print "  [peer]  description: " desc_peer
  print ""

  in_peer = 0
}

# บล็อกแสดงผลสรุปรายงานตอนท้ายสุด
END {
  print "--------------------------------------------------"
  print "                     SUMMARY                      "
  print "--------------------------------------------------"
  printf "  Mirroring OK      : %s%d image(s)%s\n", GREEN, ok_count, RESET
  printf "  Mirroring Failed  : %s%d image(s)%s\n", (failed_count > 0 ? RED : RESET), failed_count, RESET
  printf "  No Such File      : %s%d image(s)%s\n", (nosuch_count > 0 ? YELLOW : RESET), nosuch_count, RESET
  print "--------------------------------------------------"

  # 1. แสดงรายชื่อกลุ่ม Failed พร้อมสาเหตุ (ใช้สีแดงเตือนอาการผิดปกติ)
  if (failed_count > 0) {
    printf "%s[Failed Images Status & Reasons]%s\n", RED, RESET
    for (i = 1; i <= failed_count; i++) {
      printf "  - %s\n", failed_images[i]
      printf "    %sReason: %s%s\n", YELLOW, failed_reasons[i], RESET
    }
    print ""
  }

  # 2. แสดงรายชื่อกลุ่ม No Such File (ใช้สีเหลืองเตือนขยะค้างระบบ)
  if (nosuch_count > 0) {
    printf "%s[No Such File or Directory Images]%s\n", YELLOW, RESET
    for (i = 1; i <= nosuch_count; i++) {
      printf "  - %s\n", nosuch_images[i]
    }
    print ""
  }

  if (failed_count == 0 && nosuch_count == 0) {
    printf "%s✔ All images are healthy and clean!%s\n", GREEN, RESET
    print "--------------------------------------------------"
  }
}
'