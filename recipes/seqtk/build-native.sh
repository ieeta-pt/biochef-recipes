set -eo pipefail

make
mkdir -p bin
cp seqtk bin/seqtk
