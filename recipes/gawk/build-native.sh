set -eo pipefail

# The repository carries configure, Makefile.in and awkgram.c. bootstrap.sh
# touches them in order, so make does not try to regenerate them.
sh ./bootstrap.sh

# The same features as the wasm build, linked against libc and libm only.
./configure --disable-nls --disable-extensions --disable-mpfr --without-readline CFLAGS="-O2"

make -j4 -C support
make -j4 gawk
mkdir -p bin
cp gawk bin/
