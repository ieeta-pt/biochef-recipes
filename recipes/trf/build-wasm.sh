cd src

emcc -O2 -I. \
  '-DPACKAGE_VERSION="4.10.0"' \
  '-DTARGET_NAME="wasm32"' \
  -fno-align-functions \
  -fno-align-loops \
  $EM_FLAGS \
  trf.c \
  -o trf.js

mkdir -p out && mv trf.js trf.wasm out/