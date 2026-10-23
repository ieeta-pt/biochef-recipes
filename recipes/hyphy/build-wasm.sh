set -eo pipefail

# exp, log, pow and the others are called, not folded at compile time, and
# no step is fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-log -fno-builtin-pow -fno-builtin-sin -fno-builtin-cos -fno-builtin-tan -fno-builtin-atan -fno-builtin-log10 -fno-builtin-log2"

emcmake cmake -DCMAKE_CXX_FLAGS="$BIOCHEF_MATH_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sEXPORTED_RUNTIME_METHODS=['callMain','FS','PROXYFS','WORKERFS','AsciiToString'] -sSTACK_SIZE=2MB -fwasm-exceptions --embed-file res@/hyphy"
emmake make -j4 hyphy

mkdir -p out && mv hyphy.js hyphy.wasm out/
