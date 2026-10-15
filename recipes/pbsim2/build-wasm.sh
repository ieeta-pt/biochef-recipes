autoreconf -fi
emconfigure ./configure
emmake make -j4 CXXFLAGS="-O2 -sSTACK_SIZE=8MB $EM_FLAGS"
mkdir -p out && mv src/pbsim out/pbsim.js && mv src/pbsim.wasm out/pbsim.wasm