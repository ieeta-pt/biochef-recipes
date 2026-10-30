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

# Emscripten's libc declares splice but does not implement it. grep only
# uses it to drain a pipe into /dev/null, and falls back to read.
sed -i 's/^#ifdef SPLICE_F_MOVE$/#if defined SPLICE_F_MOVE \&\& !defined __EMSCRIPTEN__/' src/grep.c
test "$(grep -c '^#if defined SPLICE_F_MOVE && !defined __EMSCRIPTEN__$' src/grep.c)" = 1

# Both checks run a test program that never returns under node. No PCRE
# port exists for emscripten, so -P is left out.
FORCE_UNSAFE_CONFIGURE=1 emconfigure ./configure --disable-nls --disable-perl-regexp \
  --host=wasm32-unknown-emscripten gl_cv_func_nanosleep=no gl_cv_func_sleep_works=no

# Emscripten sets LANG from the browser's language. Fixing the locale keeps
# the output independent of it: UTF-8 characters, byte order collation.
echo "Module.preRun = [].concat(Module.preRun || [], () => { ENV.LANG = 'C'; ENV.LC_CTYPE = 'C.UTF-8'; });" > locale.js

emmake make -j4 -C lib CFLAGS="-O2"
emmake make -j4 -C src EXEEXT=.js CFLAGS="-O2" LDFLAGS="$EM_FLAGS --pre-js $PWD/locale.js" grep.js
mkdir -p ../out
cp src/grep.js src/grep.wasm ../out/
