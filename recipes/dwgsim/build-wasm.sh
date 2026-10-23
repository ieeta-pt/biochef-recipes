set -eo pipefail

FLAGS="-O2 -ffp-contract=off"
DFLAGS='-D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE -DPACKAGE_VERSION=\"0.1.17\" -include biochef_dwgsim.h'
OBJS="src/dwgsim_opt.o src/mut.o src/contigs.o src/regions_bed.o src/mut_txt.o src/mut_bed.o src/mut_vcf.o src/mut_input.o src/dwgsim.o"

emmake make CC=emcc CFLAGS="$FLAGS -Wall -sUSE_ZLIB=1" DFLAGS="$DFLAGS" INCLUDES="-I. -Isrc" $OBJS
emcc $FLAGS -Wall -sUSE_ZLIB=1 -c biochef_main.c -o biochef_main.o
emcc $FLAGS -o dwgsim.js biochef_main.o $OBJS -lm $EM_FLAGS

mkdir -p out && mv dwgsim.js dwgsim.wasm out/
