set -eo pipefail

# The compilation upstream documents at the top of FastTree.c. The
# repository also carries prebuilt binaries, which are not used.
mkdir -p bin
gcc -O3 -finline-functions -funroll-loops FastTree.c -lm -o bin/fasttree
