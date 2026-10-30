set -eo pipefail

# The release tarball of this tag adds what bootstrap generates (configure,
# Makefile.in, the gnulib files) to the files of the commit. It is checked by
# hash, and every file it shares with the commit must be identical.
curl -fsSL -o grep-3.12.tar.xz https://ftp.gnu.org/gnu/grep/grep-3.12.tar.xz
echo "2649b27c0e90e632eadcd757be06c6e9a4f48d941de51e7c0f83ff76408a07b9  grep-3.12.tar.xz" | sha256sum -c -
tar -xJf grep-3.12.tar.xz
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -f "grep-3.12/$f" ]; then
    cmp -s "$f" "grep-3.12/$f" || { echo "release tarball differs from the commit: $f" >&2; exit 1; }
  fi
done
cd grep-3.12

# Without PCRE, as the wasm build, so both accept the same patterns. It
# links against libc only.
FORCE_UNSAFE_CONFIGURE=1 ./configure --disable-nls --disable-perl-regexp CFLAGS="-O2"

make -j4 -C lib
make -j4 -C src grep
mkdir -p ../bin
cp src/grep ../bin/
