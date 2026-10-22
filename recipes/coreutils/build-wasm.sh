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

# gnulib takes the musl branch only on Linux. Emscripten's libc is musl too.
sed -i 's/defined __linux__ && HAVE_LANGINFO_H/(defined __linux__ || defined __EMSCRIPTEN__) \&\& HAVE_LANGINFO_H/' lib/getlocalename_l-unsafe.c
test "$(grep -c '(defined __linux__ || defined __EMSCRIPTEN__) && HAVE_LANGINFO_H' lib/getlocalename_l-unsafe.c)" = 2

# Both checks run a test program that never returns under node.
FORCE_UNSAFE_CONFIGURE=1 emconfigure ./configure --disable-nls --host=wasm32-unknown-emscripten \
  gl_cv_func_nanosleep=no gl_cv_func_sleep_works=no

# Emscripten sets LANG from the browser's language. Fixing the locale keeps
# the output independent of it: UTF-8 characters, byte order collation.
echo "Module.preRun = [].concat(Module.preRun || [], () => { ENV.LANG = 'C'; ENV.LC_CTYPE = 'C.UTF-8'; });" > locale.js

PROGRAMS="cat sort head tail wc cut paste tr uniq comm join fold shuf basename dirname seq echo"
BUILT=$(printf 'print:\n\t@echo $(BUILT_SOURCES)\n' | make -s -f Makefile -f - print)
TARGETS=""
for p in $PROGRAMS; do TARGETS="$TARGETS src/$p.js"; done
# wc keeps two 256 KiB buffers on the stack.
emmake make -j4 EXEEXT=.js CFLAGS="-O2" LDFLAGS="$EM_FLAGS -sSTACK_SIZE=8MB --pre-js locale.js" $BUILT $TARGETS
mkdir -p ../out
for p in $PROGRAMS; do cp "src/$p.js" "src/$p.wasm" ../out/; done
