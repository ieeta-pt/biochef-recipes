em++ -O2 -std=c++11 -Iedlib/include $EM_FLAGS -o edlib-aligner.js edlib/src/edlib.cpp apps/aligner/aligner.cpp
mkdir -p out && mv edlib-aligner.js edlib-aligner.wasm out/