set -euo pipefail

# Headers for src/lib, which also builds the parts these tools don't call.
sudo apt-get update
sudo apt-get install -y libpng-dev libssl-dev uuid-dev

# Only what the four tools link. "make topLibs" would also build jkOwnLib, which
# is under a non-commercial licence, and parasol.
make -C src/lib -j4
make -C src/htslib -j4

# MYSQLLIBS: these tools don't use MySQL, and common.mk adds -lmysqlclient when
# the variable is empty.
# L: common.mk mixes the static libssl.a with the shared -lcrypto, which doesn't
# link against OpenSSL 3. Everything but glibc is static, so the binaries also
# run where these libraries aren't installed.
libs="../../htslib/libhts.a -l:libpng.a -l:libssl.a -l:libcrypto.a -l:libz.a -lm -lpthread -ldl"

mkdir -p dist
for tool in bigBedToBed bigBedInfo bigWigToWig bigWigInfo; do
  make -C "src/utils/$tool" BINDIR="$PWD/dist" MYSQLLIBS=-lm L="$libs"
done
