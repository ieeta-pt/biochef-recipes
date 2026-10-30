set -eo pipefail

# The release tarball of this tag adds what bootstrap generates (configure,
# Makefile.in, the gnulib files) to the files of the commit. It is checked by
# hash, and every file it shares with the commit must be identical.
curl -fsSL -o coreutils-9.12.tar.xz https://ftp.gnu.org/gnu/coreutils/coreutils-9.12.tar.xz
echo "a480198559733e9b3da999e90543ac6f888a2caa544d8d664c5a1f17e528e210  coreutils-9.12.tar.xz" | sha256sum -c -
tar -xJf coreutils-9.12.tar.xz
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -f "coreutils-9.12/$f" ]; then
    cmp -s "$f" "coreutils-9.12/$f" || { echo "release tarball differs from the commit: $f" >&2; exit 1; }
  fi
done
cd coreutils-9.12

# Only libc: without these, configure links whatever the build machine has.
FORCE_UNSAFE_CONFIGURE=1 ./configure --disable-nls --without-openssl --without-libgmp --without-selinux CFLAGS="-O2"

PROGRAMS="cat sort head tail wc cut paste tr uniq comm join fold shuf basename dirname seq echo"
BUILT=$(printf 'print:\n\t@echo $(BUILT_SOURCES)\n' | make -s -f Makefile -f - print)
TARGETS=""
for p in $PROGRAMS; do TARGETS="$TARGETS src/$p"; done
make -j4 $BUILT $TARGETS
mkdir -p ../bin
for p in $PROGRAMS; do cp "src/$p" ../bin/; done
