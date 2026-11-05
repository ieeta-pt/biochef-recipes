set -eo pipefail

cd src
make ssw_test
mkdir -p ../bin
cp ssw_test ../bin/ssw
