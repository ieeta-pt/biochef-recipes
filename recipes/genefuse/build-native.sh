set -eo pipefail

FLAGS="-std=c++11 -O2 -ffp-contract=off -I./inc -include src/biochef_genefuse.h"

make CC=g++ CFLAGS="$FLAGS -Wall" -j4
