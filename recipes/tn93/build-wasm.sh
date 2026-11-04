mkdir -p build && cd build

emcmake cmake -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS" ..

emmake make -j4 tn93
