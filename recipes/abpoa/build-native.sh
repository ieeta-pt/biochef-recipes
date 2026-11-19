set -eo pipefail

git submodule update --init --recursive

# On x86_64 upstream's Makefile builds every SIMD level and picks one at run time.
make -j4

mkdir -p out && cp bin/abpoa out/abpoa
