# macOS APFS case-insensitivity collides VERSION with libc++'s <version>
# header; rename so clang's #include <version> resolves to libc++. On
# Linux CI this rename is harmless (filesystem already case-sensitive).
mv VERSION VERSION_FILE && sed -i.bak "s|cat VERSION|cat VERSION_FILE|g" Makefile

emmake make centrifuge-build-bin centrifuge-class centrifuge-inspect-bin CXX=em++ CC=emcc RELEASE_FLAGS="-O2 -msimd128 -msse4.2 -std=c++11" EXTRA_FLAGS="-std=c++11 $EM_FLAGS -sSTACK_SIZE=8MB" NO_TBB=1 -j4

for b in centrifuge-build-bin centrifuge-class centrifuge-inspect-bin; do mv "$b" "$b.js"; done