emmake make CPP=em++ -j4

em++ -O3 $EM_FLAGS samblaster.o sbhash.o -o samblaster.js

mkdir -p out && mv samblaster.js samblaster.wasm out/