set -eo pipefail

# gclib at the commit the gffread 0.12.9 release tarball bundles, checked
# by commit. The Makefile would clone its default branch into ../gclib;
# -o ../gclib stops it from making that directory.
git clone https://github.com/gpertea/gclib gclib
git -C gclib checkout --detach 35376c8f69889178306ce80d986a3cc09e726a22

make release -o ../gclib GCLDIR=gclib
