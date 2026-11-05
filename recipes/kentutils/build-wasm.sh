set -eo pipefail

# Headers only, searched last so that emscripten's own come first. Nothing here
# links the host's libraries.
sudo apt-get update
sudo apt-get install -y libpng-dev libssl-dev uuid-dev
host_headers="-idirafter /usr/include -idirafter /usr/include/$(gcc -dumpmachine)"

# As in build-native.sh, only what the four tools link. MACHTYPE is the directory
# jkweb.a lands in, which would otherwise depend on the host.
emmake make -C src/lib -j4 MACHTYPE=x86_64 COPT="-O2 -sUSE_ZLIB=1 $host_headers"
emmake make -C src/htslib -j4 MACHTYPE=x86_64 COPT="-O2 -sUSE_ZLIB=1"

# These tools read local files, so they never reach OpenSSL, which is only for
# http(s) URLs. Its symbols and pthread_kill stay undefined.
mkdir -p out
for tool in bigBedToBed bigBedInfo bigWigToWig bigWigInfo; do
  emcc -O2 -std=c99 -Isrc/inc -Isrc/htslib \
    -D_LARGEFILE_SOURCE -D_GNU_SOURCE -DMACHTYPE_x86_64 \
    "src/utils/$tool/$tool.c" -c -o "$tool.o"
  emcc -O2 "$tool.o" src/lib/x86_64/jkweb.a src/htslib/libhts.a -lm \
    -o "out/$tool.js" -s ERROR_ON_UNDEFINED_SYMBOLS=0 $EM_FLAGS
done
