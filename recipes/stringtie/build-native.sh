set -e

# stringtie took a read error from htslib for the end of the file, and
# htslib also reads FASTA and FASTQ, as unaligned records, so input that is
# not SAM, BAM or CRAM, or a truncated BAM, gave an empty assembly and exit
# 0. Fail on another format, a missing header and read errors (below -1; -1
# is the end of the file).
grep -q 'hdr=sam_hdr_read(hts_file);' gclib/GSam.h
grep -q 'if (sam_read1(hts_file, hdr, b) >= 0) {' gclib/GSam.h
grep -q 'if (sam_read1(hts_file, hdr, b_next) >= 0) {' gclib/GSam.h
sed -i.bak \
  -e 's|hdr=sam_hdr_read(hts_file);|hdr=sam_hdr_read(hts_file); if (hdr==NULL or (hts_file->format.format!=sam and hts_file->format.format!=bam and hts_file->format.format!=cram)) GError("Error: %s is not a valid SAM, BAM or CRAM file\\n", filename);|' \
  -e 's|if (sam_read1(hts_file, hdr, b) >= 0) {|int rd=sam_read1(hts_file, hdr, b); if (rd < -1) GError("Error: could not read an alignment from %s (invalid or truncated)\\n", fname); if (rd >= 0) {|' \
  -e 's|if (sam_read1(hts_file, hdr, b_next) >= 0) {|int rd=sam_read1(hts_file, hdr, b_next); if (rd < -1) GError("Error: could not read an alignment from %s (invalid or truncated)\\n", fname); if (rd >= 0) {|' \
  gclib/GSam.h
grep -q 'is not a valid SAM, BAM or CRAM file' gclib/GSam.h
[ "$(grep -c 'invalid or truncated' gclib/GSam.h)" = 2 ]

# stringtie removes its tmp_XXXXXX directory only when it finishes, so an
# error left the directory, with the partial output or the merge's
# intermediate files, next to the output. Empty and remove it at exit too;
# stringtie made it with mkdtemp, so all it holds is stringtie's.
grep -q 'bool keepTempFiles = false; //--keeptmp' stringtie.cpp
grep -q '     tmp_path=ctempl;' stringtie.cpp
sed -i.bak \
  -e 's|bool keepTempFiles = false; //--keeptmp|&\n#include <dirent.h>\nstatic void removeTempDir() { if (keepTempFiles or tmp_path.is_empty()) return; GStr d(tmp_path); d.chomp(\x27/\x27); DIR* dp=opendir(d.chars()); if (dp) { struct dirent* e; while ((e=readdir(dp))) { if (strcmp(e->d_name, ".") and strcmp(e->d_name, "..")) { GStr f(tmp_path); f+=e->d_name; remove(f.chars()); } } closedir(dp); } rmdir(d.chars()); }|' \
  -e 's|     tmp_path=ctempl;|& atexit(removeTempDir);|' \
  stringtie.cpp
grep -q 'atexit(removeTempDir);' stringtie.cpp
grep -q 'static void removeTempDir()' stringtie.cpp

# Build the vendored htslib as a static library with the same minimal
# config.h as the wasm build: only zlib, so both builds read the same files.
cd htslib

printf "#ifndef _XOPEN_SOURCE\n#define _XOPEN_SOURCE 600\n#endif\n#define HAVE_DRAND48 1\n" > config.h

make \
  CFLAGS="-O2 -Wall -fvisibility=hidden -Wno-unused-function -Wno-unused-but-set-variable" \
  CPPFLAGS="-I." \
  lib-static

cd ..

# rlink.cpp uses printCovMutex unconditionally but stringtie.cpp only
# defines it under #ifndef NOTHREADS: replace the extern declaration with an
# anonymous-struct no-op stub so the lock/unlock calls compile out.
sed -i.bak 's|extern GFastMutex printCovMutex;|struct{void lock(){}void unlock(){}}printCovMutex;|' rlink.cpp

# Build stringtie release linking against that libhts.a, single-threaded as
# in wasm.
make release \
  LIBDEFLATE= \
  LIBBZ2= \
  LIBLZMA= \
  LIBS="./htslib/libhts.a -lz -lm" \
  NOTHREADS=1

mkdir -p out && mv stringtie out/stringtie
