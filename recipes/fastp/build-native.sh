set -eo pipefail

make -j4
mkdir -p bin
cp fastp bin/fastp
