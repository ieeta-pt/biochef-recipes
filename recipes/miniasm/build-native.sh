set -eo pipefail

make CFLAGS="-g -Wall -O2 -Wc++-compat -ffp-contract=off" -j4
