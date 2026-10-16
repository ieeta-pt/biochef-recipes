set -eo pipefail

for f in pe:PairEnd se:SingleEnd; do
    file=src/${f%%:*}scanner.cpp; cls=${f#*:}
    sed -i.bak "s|^    std::thread producer(std::bind(&${cls}Scanner::producerTask, this));\$|#ifdef __EMSCRIPTEN__\n    producerTask();\n    mThreadNum = 0;\n#else\n&\n#endif|; s|^    producer.join();\$|#ifndef __EMSCRIPTEN__\n&\n#endif|; s|^void ${cls}Scanner::producePack(.*){\$|&\n#ifdef __EMSCRIPTEN__\n    scan${cls}(pack);\n    return;\n#endif|" $file
    test "$(grep -c '__EMSCRIPTEN__' $file)" -eq 3
done
sed -i.bak 's|time used: %ld seconds\\n", FUSIONSCAN_VER, (t2-t1));|time used: %ld seconds\\n", FUSIONSCAN_VER, (long)(t2-t1));|' src/main.cpp
grep -q '(long)(t2-t1)' src/main.cpp

sed -i.bak 's/^typedef long int64;$/typedef int64_t int64;/; s/^typedef unsigned long uint64;$/typedef uint64_t uint64;/' src/common.h
sed -i.bak -E 's/\blong\b/int64_t/g' src/editdistance.cpp src/fusionresult.cpp src/htmlreporter.cpp src/indexer.h src/indexer.cpp src/matcher.h src/matcher.cpp
sed -i.bak -E 's/\b1L\b/1LL/g' src/editdistance.cpp
test "$(cat src/common.h src/editdistance.cpp src/fusionresult.cpp src/htmlreporter.cpp src/indexer.h src/indexer.cpp src/matcher.h src/matcher.cpp | grep -cwE 'long|1L')" -eq 0

sed -i.bak "s|-lz -lpthread|${EM_FLAGS} -sSTACK_SIZE=8MB|" Makefile

emmake make CC=em++ CFLAGS="-std=c++11 -O2 -include stdint.h -I./inc -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing" -j4

mv genefuse genefuse.js
