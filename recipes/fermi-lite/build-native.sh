set -eo pipefail

make CFLAGS="-O2 -Wno-unused-function" -j4

mkdir -p out && mv fml-asm out/fml-asm
