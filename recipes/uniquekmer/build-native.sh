set -eo pipefail

# FastaReader refuses any name but *.fa, *.fasta or *.fna, and BioChef passes
# inputs as *.txt, so read every uncompressed name as plain FASTA.
sed -i.bak 's/else if(ends_with(mFilename, ".fasta") || ends_with(mFilename, ".fa") || ends_with(mFilename, ".fna")){/else if(!ends_with(mFilename, ".gz")){/' src/fastareader.cpp
grep -q 'else if(!ends_with(mFilename, ".gz")){' src/fastareader.cpp
make