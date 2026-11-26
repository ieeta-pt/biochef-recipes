mkdir -p build_wasm
cd build_wasm

emcmake cmake -DBUILD_WASM=ON -DPYTHON_BINDINGS=OFF -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS" ..

cmake --build .

find src -name "*.js" -exec cp {} . \;
find src -name "*.wasm" -exec cp {} . \;