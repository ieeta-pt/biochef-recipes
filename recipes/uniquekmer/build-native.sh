set -eo pipefail

make -j4
mkdir -p out && mv uniquekmer out/uniquekmer
