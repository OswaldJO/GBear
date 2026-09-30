#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
pthread="$(x86_64-w64-mingw32-g++ -print-file-name=libwinpthread.a)"
x86_64-w64-mingw32-windres GBearGuest.rc -O coff -o build/GBearGuest.res
x86_64-w64-mingw32-g++ \
  -O2 -std=c++17 -municode -mwindows -static \
  -static-libgcc -static-libstdc++ \
  -o build/GBearGuest.exe \
  GBearGuest.cpp GBearWinHost.cpp third_party/ViGEmClient/src/ViGEmClient.cpp build/GBearGuest.res \
  -Ithird_party/ViGEmClient/include -Ithird_party/ViGEmClient/src \
  "$pthread" \
  -lwinhttp -lws2_32 -lmfplat -lmfuuid -lole32 -loleaut32 -lwinmm -lxinput -lgdi32 -luser32 \
  -ld3d11 -ldxgi -ldxguid -luuid -lsetupapi -liphlpapi -lstrmiids \
  -lgdiplus -ldwmapi -luxtheme -lcomctl32
echo "built $(pwd)/build/GBearGuest.exe"
