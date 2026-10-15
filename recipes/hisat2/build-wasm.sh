sed -i.bak 's|^            threads\[i\] = new tthread::thread(multiseedSearchWorker_hisat2, (void\*)&tids\[i\]);$|#ifdef __EMSCRIPTEN__\n            multiseedSearchWorker_hisat2((void*)\&tids[i]);\n            threads[i] = NULL;\n#else\n&\n#endif|; s|^            threads\[i\]->join();$|            if (threads[i] != NULL) threads[i]->join();|' hisat2.cpp

emmake make \
  hisat2-align-s \
  hisat2-build-s \
  hisat2-inspect-s \
  CXX=em++ \
  CC=emcc \
  RELEASE_FLAGS="-O2 -msimd128 -msse4.2 -std=c++11" \
  EXTRA_FLAGS="-std=c++11 $EM_FLAGS -sSTACK_SIZE=8MB" \
  NO_TBB=1 \
  -j4

for b in hisat2-align-s hisat2-build-s hisat2-inspect-s; do
  mv "$b" "$b.js"
done
