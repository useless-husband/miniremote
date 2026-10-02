#!/bin/bash
# 在 pro 上執行(在家、同一個 Wi-Fi):把 mini-fix 資料夾用區網分享給 mini,免 AirDrop
cd "$(dirname "$0")/mini-fix" || exit 1
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)
echo "在 mini 的終端機貼這行,把修復腳本抓過去:"
echo
echo "  curl -fsSL http://$IP:8899/fix-mini-identity.sh -o ~/fix-mini-identity.sh && curl -fsSL http://$IP:8899/mini-tune.sh -o ~/mini-tune.sh && echo 下載完成"
echo
echo "(這個分享只在區網、只有這個資料夾;按 Ctrl+C 結束)"
python3 -m http.server 8899 --bind 0.0.0.0
