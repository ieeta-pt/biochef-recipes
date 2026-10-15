set -eo pipefail

cd src

# A lookup line without a tab makes lookup_accession_numbers read past the end
# of its fields and crash; skip such lines instead.
sed -i.bak 's|^    auto fields = SplitString(line, "\\t", 2);$|&\n    if (fields.size() < 2) continue;|' lookup_accession_numbers.cc
grep -q '^    if (fields.size() < 2) continue;$' lookup_accession_numbers.cc

make -j4 estimate_capacity build_db classify dump_table lookup_accession_numbers k2mask
