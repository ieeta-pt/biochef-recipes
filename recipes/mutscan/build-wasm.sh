set -eo pipefail

f=src/scanner-impl.h
sed -i.bak "s|^    std::thread producer(std::bind(&Self::producerTask, this));\$|#ifdef __EMSCRIPTEN__\n    producerTask();\n    mThreadNum = 0;\n#else\n&\n#endif|; s|^    producer.join();\$|#ifndef __EMSCRIPTEN__\n&\n#endif|; s|^void Scanner<ReadData, Self>::producePack(ReadPack<ReadData>\* pack){\$|&\n#ifdef __EMSCRIPTEN__\n    static_cast<Self*>(this)->scanNextEnd(pack);\n    return;\n#endif|" $f
test "$(grep -c '__EMSCRIPTEN__' $f)" -eq 3

sed -i.bak 's/^typedef long int64;$/typedef int64_t int64;/; s/^typedef unsigned long uint64;$/typedef uint64_t uint64;/' src/common.h
sed -i.bak -E 's/\blong\b/int64_t/g' src/htmlreporter.cpp src/mutscan.cpp src/rollinghash.cpp src/rollinghash.h src/scanner-impl.h
sed -i.bak -E 's/\b1L\b/1LL/g' src/editdistance.cpp
sed -i.bak -E 's/\b50L\b/50LL/; s/\b1024L\b/1024LL/g' src/mutscan.cpp
sed -i.bak 's|time used: %ld seconds\\n", MUTSCAN_VER, (t2-t1));|time used: %ld seconds\\n", MUTSCAN_VER, (long)(t2-t1));|' src/main.cpp
grep -q '(long)(t2-t1)' src/main.cpp
test "$(cat src/common.h src/editdistance.cpp src/htmlreporter.cpp src/mutscan.cpp src/rollinghash.cpp src/rollinghash.h src/scanner-impl.h | grep -cwE 'long|1L|50L|1024L')" -eq 0

sed -i.bak "s|-lz -lpthread|${EM_FLAGS} -sSTACK_SIZE=8MB|" Makefile

emmake make CC=em++ CFLAGS="-std=c++11 -O2 -include stdint.h -I./inc -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing" -j4

mv mutscan mutscan.js
