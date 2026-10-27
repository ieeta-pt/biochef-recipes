set -eo pipefail

# The compilation upstream documents at the top of FastTree.c. The
# repository also carries prebuilt binaries, which are not used.
mkdir -p out
emcc -O3 -finline-functions -funroll-loops $EM_FLAGS FastTree.c -lm -o out/fasttree.js
