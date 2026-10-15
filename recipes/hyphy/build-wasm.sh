sed -i.bak 's/^    postMessage({$/    if (typeof postMessage === "function") postMessage({/' src/utils/hyphyunixutils.cpp src/mains/unix.cpp

emcmake cmake -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sEXPORTED_RUNTIME_METHODS=['callMain','FS','PROXYFS','WORKERFS','AsciiToString'] -sSTACK_SIZE=2MB -fwasm-exceptions --embed-file res@/hyphy"
emmake make -j4 hyphy

mkdir -p out && mv hyphy.js hyphy.wasm out/
