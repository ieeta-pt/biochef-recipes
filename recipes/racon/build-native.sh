set -eo pipefail

git submodule update --init --recursive

mkdir -p build && cd build
cmake -Dracon_build_tests=OFF -Dracon_enable_cuda=OFF -Dspoa_optimize_for_native=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-ffp-contract=off" ..
make -j4 racon
