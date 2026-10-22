set -eo pipefail

# The release tarball of this tag adds what bootstrap generates (configure,
# Makefile.in, the gnulib files) to the files of the commit. It is checked by
# hash, and every file it shares with the commit must be identical.
curl -fsSL -o sed-4.10.tar.xz https://ftp.gnu.org/gnu/sed/sed-4.10.tar.xz
echo "b8e72182b2ec96a3574e2998c47b7aaa64cc20ce000d8e9ac313cc07cecf28c7  sed-4.10.tar.xz" | sha256sum -c -
tar -xJf sed-4.10.tar.xz
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -f "sed-4.10/$f" ]; then
    cmp -s "$f" "sed-4.10/$f" || { echo "release tarball differs from the commit: $f" >&2; exit 1; }
  fi
done
cd sed-4.10

# Only libc: without these, configure links whatever the build machine has.
FORCE_UNSAFE_CONFIGURE=1 ./configure --disable-nls --disable-acl --without-selinux CFLAGS="-O2"

BUILT=$(printf 'print:\n\t@echo $(BUILT_SOURCES)\n' | make -s -f Makefile -f - print)
make -j4 $BUILT sed/sed
mkdir -p ../bin
cp sed/sed ../bin/
