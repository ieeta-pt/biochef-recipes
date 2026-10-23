set -eo pipefail

# exp, pow and tgamma are called, not folded at compile time, and no step
# is fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-pow -fno-builtin-tgamma"

autoreconf -fi
emconfigure ./configure CXXFLAGS="-O2 $BIOCHEF_MATH_FLAGS"
emmake make -j4 CXXFLAGS="-O2 $BIOCHEF_MATH_FLAGS" LDFLAGS="-sSTACK_SIZE=8MB --embed-file $PWD/data@/biochef_models $EM_FLAGS"
mkdir -p out && mv src/pbsim out/pbsim.js && mv src/pbsim.wasm out/pbsim.wasm
