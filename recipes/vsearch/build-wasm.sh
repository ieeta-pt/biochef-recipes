git clone --depth 1 https://github.com/simd-everywhere/simde simde-vendor

autoreconf -fi

sed -i.bak \
  -e 's/auto const \* next_level = std::find/auto const next_level = std::find/' \
  -e 's/std::distance(taxonomic_fields\.data(), next_level)/std::distance(taxonomic_fields.begin(), next_level)/' \
  src/tax.cc

cat > serial-threads.inc <<'EOF'
static void serial_xpthread_create(pthread_t *, pthread_attr_t const *, void * (*start_routine)(void *), void * arg) { start_routine(arg); }
static void serial_xpthread_join(pthread_t, void **) {}
#define xpthread_create serial_xpthread_create
#define xpthread_join serial_xpthread_join
EOF
for f in src/allpairs.cc src/chimera.cc src/mask.cc src/search.cc src/search_exact.cc src/sintax.cc; do
  sed -i.bak '/^#include <pthread.h>$/r serial-threads.inc' "$f"
done

emconfigure ./configure --disable-bzip2 --disable-pdfman

sed -i.bak \
  -e 's/-march=x86-64 -mtune=generic//g' \
  -e 's/-march=armv8-a+simd -mtune=generic//g' \
  -e 's/-mcpu=powerpc64le -maltivec//g' \
  src/Makefile.am src/Makefile


emmake make -j4 LDFLAGS="$EM_FLAGS -sSTACK_SIZE=8MB" CXXFLAGS="-O2 -I../simde-vendor -msimd128 -msse4.2 -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing" 

mkdir -p out && mv bin/vsearch out/vsearch.js && mv bin/vsearch.wasm out/vsearch.wasm