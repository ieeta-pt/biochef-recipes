git submodule update --init --recursive

cd src

emmake make \
  CC=emcc \
  CFLAGS="-O2 -sUSE_ZLIB=1 -Wno-implicit-function-declaration -D_FILE_OFFSET_BITS=64 -DPACKAGE_VERSION=\\\"0.1.17\\\"" \
  -j4 \
  dwgsim_opt.o mut.o contigs.o regions_bed.o mut_txt.o \
  mut_bed.o mut_vcf.o mut_input.o dwgsim.o

emcc -O2 $EM_FLAGS \
  dwgsim_opt.o mut.o contigs.o regions_bed.o mut_txt.o \
  mut_bed.o mut_vcf.o mut_input.o dwgsim.o \
  -lm -lz -o dwgsim.js