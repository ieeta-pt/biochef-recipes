emmake make \
  CC=emcc \
  CXX=em++ \
  CXXFLAGS="-O3 -msse4.2 -msimd128 -sUSE_ZLIB=1 -Wno-implicit-function-declaration -Wno-unused-function -Wno-narrowing" \
  CFLAGS="-O3 -msse4.2 -msimd128 -sUSE_ZLIB=1 -Wno-implicit-function-declaration -Wno-unused-function" \
  -j4

em++ -O3 $EM_FLAGS -sINITIAL_MEMORY=128MB \
  CommandLines.o Process_Read.o Assembly.o Hash_Table.o POA.o Correct.o \
  Levenshtein_distance.o Overlaps.o Trio.o kthread.o Purge_Dups.o htab.o \
  hist.o sketch.o anchor.o extract.o sys.o hic.o rcut.o horder.o ecovlp.o \
  tovlp.o inter.o kalloc.o gfa_ut.o gchain_map.o main.o \
  -o hifiasm.js -lz -lm

mkdir -p out && mv hifiasm.js hifiasm.wasm out/
