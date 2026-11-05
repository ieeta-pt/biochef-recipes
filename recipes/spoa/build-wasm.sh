set -eo pipefail

# spoa reports what it cannot align, such as sequences too long for the
# memory there is, by catching the exceptions it throws, which wasm builds
# without -fwasm-exceptions do not catch.
mkdir -p build && cd build
embuilder build zlib
emcmake cmake -Dspoa_build_tests=OFF -Dspoa_use_simde=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-ffp-contract=off -fwasm-exceptions" -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -fwasm-exceptions" ..
emmake make -j4 spoa_exe
