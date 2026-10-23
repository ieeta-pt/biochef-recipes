set -eo pipefail

mkdir -p build && cd build
cmake -Dspoa_build_tests=OFF -Dspoa_use_simde=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-ffp-contract=off" ..
make -j4 spoa_exe
