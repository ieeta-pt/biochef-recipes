set -eo pipefail

# cawlign drops characters it does not know without a word, aligns to the
# first sequence of a reference of several, and reads a reference that is
# not a file as a sequence. This entry point, appended to cawlign's main
# file, reads the sequences and the reference first and refuses those, and
# takes the scoring, the genetic code and the named references from the
# files cawlign ships, which go into the program. The same entry point is in
# build-native.sh.
sed -i 's/^int main (int argc, const char \* argv\[\]) {$/int biochef_upstream_main (int argc, const char * argv[]) {/' src/cawlign.cpp
grep -q '^int biochef_upstream_main (int argc, const char \* argv\[\]) {$' src/cawlign.cpp
cat >> src/cawlign.cpp <<'SHIM_EOF'

// The entry point of cawlign. It reads the sequences and the reference first
// and refuses what cawlign would drop or misread without a word, takes the
// scoring, the genetic code and the named references from the files cawlign
// ships, which are in the executable, and puts the sequences file last,
// where cawlign looks for it.
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <set>
#include <string>
#include <vector>

static void biochef_fail(const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	fputs("[cawlign] ", stderr);
	vfprintf(stderr, format, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

static std::string biochef_shown(int c)
{
	char s[8];
	if (c >= 33 && c <= 126) snprintf(s, sizeof s, "'%c'", c);
	else snprintf(s, sizeof s, "0x%02X", c);
	return s;
}

static std::string biochef_library;

const char *biochef_library_path(void)
{
	return biochef_library.c_str();
}

#ifdef __EMSCRIPTEN__
static void biochef_find_library(void)
{
	biochef_library = "/biochef_res/";
}
#else
// cawlign's res directory, a tar linked into the executable: the hub ships
// one file for a native operation
extern "C" const unsigned char biochef_res_tar[], biochef_res_tar_end[];
static std::string biochef_res_dir;

static void biochef_remove_tree(const std::string &path)
{
	struct stat st;
	if (lstat(path.c_str(), &st) != 0) return;
	if (S_ISDIR(st.st_mode)) {
		DIR *d = opendir(path.c_str());
		if (d) {
			std::vector<std::string> names;
			for (struct dirent *e; (e = readdir(d));)
				if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) names.push_back(e->d_name);
			closedir(d);
			for (size_t i = 0; i < names.size(); i++) biochef_remove_tree(path + "/" + names[i]);
		}
		rmdir(path.c_str());
	} else {
		unlink(path.c_str());
	}
}

static void biochef_remove_res(void)
{
	if (!biochef_res_dir.empty()) biochef_remove_tree(biochef_res_dir);
}

static void biochef_find_library(void)
{
	const char *tmp = getenv("TMPDIR");
	std::string base = std::string(tmp && *tmp ? tmp : "/tmp") + "/cawlign-res.XXXXXX";
	std::vector<char> templ(base.begin(), base.end());
	templ.push_back(0);
	if (!mkdtemp(&templ[0])) biochef_fail("cannot make a directory for cawlign's files (%s)", strerror(errno));
	biochef_res_dir = &templ[0];
	atexit(biochef_remove_res);
	const unsigned char *p = biochef_res_tar, *end = biochef_res_tar_end;
	while (p + 512 <= end && p[0]) {
		char name[101] = { 0 }, size[13] = { 0 };
		memcpy(name, p, 100);
		memcpy(size, p + 124, 12);
		unsigned long n = strtoul(size, NULL, 8);
		char type = (char)p[156];
		std::string rel = name;
		if (rel.empty() || rel[0] == '/' || rel.find("..") != std::string::npos || p + 512 + n > end)
			biochef_fail("cawlign's embedded files are damaged");
		std::string path = biochef_res_dir + "/" + rel;
		if (type == '5') {
			mkdir(path.c_str(), 0700);
		} else if (type == '0' || type == 0) {
			FILE *f = fopen(path.c_str(), "wb");
			if (!f || fwrite(p + 512, 1, n, f) != n || fclose(f) != 0) biochef_fail("cannot write %s (%s)", path.c_str(), strerror(errno));
		}
		p += 512 + ((n + 511) / 512) * 512;
	}
	biochef_library = biochef_res_dir + "/res/";
}
#endif

// The files of one of cawlign's resource directories
static std::set<std::string> biochef_library_files(const char *sub)
{
	std::set<std::string> names;
	DIR *d = opendir((biochef_library + sub).c_str());
	if (!d) biochef_fail("cannot read cawlign's %s", sub);
	for (struct dirent *e; (e = readdir(d));)
		if (e->d_name[0] != '.') names.insert(e->d_name);
	closedir(d);
	return names;
}

static std::string biochef_list(const std::set<std::string> &names)
{
	std::string s;
	for (std::set<std::string>::const_iterator i = names.begin(); i != names.end(); ++i) s += (s.empty() ? "" : ", ") + *i;
	return s;
}

// A FASTA file of sequences of unique names, of the characters cawlign
// reads (it drops any other without a word), and of gaps, which it drops
// too; returns the number of sequences
static size_t biochef_check_fasta(const char *path, const char *what, bool protein)
{
	FILE *f = fopen(path, "rb");
	if (!f) biochef_fail("cannot open the %s %s (%s)", what, path, strerror(errno));
	const char *valid = protein ? "ACDEFGHIKLMNPQRSTVWYBZX?" : "ACGTURYSWKMBDHVN?";
	std::set<std::string> names;
	std::string line, name;
	long number = 0, bases = 0, start = 0;
	int c;
	bool done = false;
	while (!done) {
		line.clear();
		while ((c = getc(f)) != EOF && c != '\n') {
			if (!c) biochef_fail("line %ld of the %s %s holds a NUL byte", number + 1, what, path);
			line += (char)c;
		}
		if (c == EOF) {
			done = true;
			if (line.empty()) break;
		}
		number++;
		if (!line.empty() && line[line.size() - 1] == '\r') line.erase(line.size() - 1);
		if (!line.empty() && line[0] == '>') {
			if (!name.empty() && !bases) biochef_fail("sequence %s, line %ld of the %s %s, has no bases", name.c_str(), start, what, path);
			name = line.substr(1);
			if (name.find_first_not_of(" \t") == std::string::npos) biochef_fail("line %ld of the %s %s starts a sequence with no name", number, what, path);
			if (!names.insert(name).second) biochef_fail("the %s %s has two sequences named %s", what, path, name.c_str());
			start = number, bases = 0;
			continue;
		}
		if (line.find_first_not_of(" \t") == std::string::npos) continue;
		if (name.empty()) biochef_fail("the %s %s is not FASTA: line %ld comes before any > line", what, path, number);
		for (size_t i = 0; i < line.size(); i++) {
			unsigned char b = (unsigned char)line[i];
			if (b == '-' || b == '.' || b == ' ' || b == '\t') continue;
			unsigned char u = (b >= 'a' && b <= 'z') ? b - 32 : b;
			if (!u || !strchr(valid, u))
				biochef_fail("line %ld of the %s %s has %s in sequence %s, which is not a %s", number, what, path, biochef_shown(b).c_str(), name.c_str(), protein ? "residue" : "nucleotide");
			bases++;
		}
	}
	fclose(f);
	if (!name.empty() && !bases) biochef_fail("sequence %s, line %ld of the %s %s, has no bases", name.c_str(), start, what, path);
	if (names.empty()) biochef_fail("the %s %s holds no sequence", what, path);
	return names.size();
}

static bool biochef_is_file(const char *path)
{
	struct stat st;
	return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

int main(int argc, char *argv[])
{
	biochef_find_library();
	std::set<std::string> references = biochef_library_files("references"), scorings = biochef_library_files("scoring"),
		codes = biochef_library_files("genetic_codes");
	codes.erase("ncbi-codon-map");
	std::vector<std::string> args(1, argv[0]);
	const char *input = NULL, *output = NULL, *reference = NULL, *scoring = NULL, *type = "nucleotide", *space = "quadratic", *code = NULL;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a.size() < 2 || a[0] != '-') {
			if (input) biochef_fail("takes one file of sequences, and was given \"%s\" and \"%s\"", input, argv[i]);
			input = argv[i];
			continue;
		}
		if (a == "-a" || a == "-I" || a == "-q") {
			args.push_back(a);
			continue;
		}
		static const char *const valued = "orstcfSlR";
		if (a.size() != 2 || !strchr(valued, a[1])) biochef_fail("has no option %s", a.c_str());
		if (i + 1 >= argc) biochef_fail("%s needs a value", a.c_str());
		std::string v = argv[++i];
		char o = a[1];
		struct choice { char opt; const char *values; } choices[] = {
			{ 't', "nucleotide codon" }, { 'f', "refmap refalign pairwise" }, { 'S', "quadratic linear" },
			{ 'l', "trim global local" }, { 'R', "none silent annotated" } };
		for (size_t k = 0; k < sizeof choices / sizeof choices[0]; k++) {
			if (choices[k].opt != o) continue;
			std::string list = std::string(" ") + choices[k].values + " ";
			if (v.empty() || list.find(" " + v + " ") == std::string::npos) {
				if (o == 't' && v == "protein") biochef_fail("-t protein needs a protein scoring file, and cawlign ships none");
				biochef_fail("%s should be one of %s, and is \"%s\"", a.c_str(), choices[k].values, v.c_str());
			}
		}
		if (o == 'o') {
			output = argv[i];
		} else if (o == 'r') {
			reference = argv[i];
			if (!biochef_is_file(reference)) {
				if (!references.count(v)) biochef_fail("-r %s is neither a file nor one of cawlign's references: %s", reference, biochef_list(references).c_str());
				v = biochef_library + "references/" + v;
			}
		} else if (o == 's') {
			if (!scorings.count(v)) biochef_fail("-s should be one of cawlign's scoring files, %s, and is \"%s\"", biochef_list(scorings).c_str(), v.c_str());
			scoring = argv[i];
			v = biochef_library + "scoring/" + v;
		} else if (o == 'c') {
			code = argv[i];
			bool number = v.find_first_not_of("0123456789") == std::string::npos;
			if (!number && !codes.count(v) && v != "standard" && v != "Standard" && v != "Universal")
				biochef_fail("-c should be an NCBI genetic code number or one of %s, and is \"%s\"", biochef_list(codes).c_str(), v.c_str());
			if (!number && codes.count(v)) v = biochef_library + "genetic_codes/" + v;
		} else if (o == 't') {
			type = argv[i];
		} else if (o == 'S') {
			space = argv[i];
		}
		args.push_back(a);
		args.push_back(v);
	}
	if (!input) biochef_fail("needs a FASTA file of sequences to align");
	if (!output) biochef_fail("needs -o, the file the alignment goes to");
	if (!reference) biochef_fail("needs -r, a FASTA file of the reference, or one of cawlign's references: %s", biochef_list(references).c_str());
	bool codon = !strcmp(type, "codon");
	if (codon && !scoring) biochef_fail("-t codon needs -s, a codon scoring file: BLOSUM62 or HIV_BETWEEN_F");
	if (codon && scoring && !strcmp(scoring, "NUC4.4")) biochef_fail("-s NUC4.4 scores nucleotides, and -t codon needs a codon scoring file: BLOSUM62 or HIV_BETWEEN_F");
	if (!codon && scoring && strcmp(scoring, "NUC4.4")) biochef_fail("-s %s scores codons, and -t nucleotide needs a nucleotide scoring file: NUC4.4", scoring);
	if (codon && !strcmp(space, "linear")) biochef_fail("-S linear is not implemented for -t codon, which cawlign aligns in quadratic space");
	if (code && !codon) biochef_fail("-c, the genetic code, is only used with -t codon");
	if (biochef_is_file(reference) && biochef_check_fasta(reference, "reference", false) != 1) biochef_fail("the reference %s holds more than one sequence, and cawlign aligns to the first only", reference);
	biochef_check_fasta(input, "sequence file", false);
	args.push_back(input);
	std::vector<char *> cargs;
	for (size_t i = 0; i < args.size(); i++) cargs.push_back(&args[i][0]);
	cargs.push_back(NULL);
	return biochef_upstream_main((int)cargs.size() - 1, (const char **)&cargs[0]);
}
SHIM_EOF

# In linear space, cawlign copied the sequence before the first column it
# aligned only for -f refalign and pairwise, and counted down the column
# only there, so with -f refmap, the default, it looped for ever.
sed -i -e 's/^\( *\)for (long j = last_column-1; j>s2p;) {$/\1for (long j = last_column-1; j>s2p; j--) {/' \
  -e 's/^\( *\)result2.appendChar(sequences.getChar (j--));$/\1result2.appendChar(sequences.getChar (j));/' src/cawlign.cpp
grep -q 'for (long j = last_column-1; j>s2p; j--) {' src/cawlign.cpp
grep -q 'result2.appendChar(sequences.getChar (j));' src/cawlign.cpp

# In linear space, the aligned sequences were a StringBuffer's, allocated
# with realloc, and freed with delete[]. They are now copied into new[].
sed -i -e 's/^using namespace argparse;$/&\n\nstatic char *biochef_new_copy (const char *s) {\n    if (!s) s = "";\n    size_t n = strlen (s) + 1;\n    char *c = new char [n];\n    memcpy (c, s, n);\n    return c;\n}/' \
  -e 's/^\( *\)alignedQrySeq = result2.getString();$/\1alignedQrySeq = biochef_new_copy (result2.getString());/' \
  -e 's/^\( *\)alignedRefSeq = result1.getString();$/\1alignedRefSeq = biochef_new_copy (result1.getString());/' \
  -e '/^ *result[12].detach();$/d' src/cawlign.cpp
[ "$(grep -c 'biochef_new_copy (result[12].getString())' src/cawlign.cpp)" -eq 2 ]
[ "$(grep -c 'detach()' src/cawlign.cpp)" -eq 0 ]

# Reverse-complementing a sequence of one base counted the end index down
# past 0, where it wrapped around, and read far past the sequence.
sed -i 's/^\( *\)for (unsigned long i = from, j = to; i <= j; i++, j--) {$/\1for (unsigned long i = from, j = to; i <= j \&\& j != (unsigned long)-1; i++, j--) {/' src/tn93_shared.cc
grep -q 'i <= j && j != (unsigned long)-1; i++, j--' src/tn93_shared.cc

# cawlign looks for its files under a path fixed when it is built; the
# entry point gives it where they are when it runs.
printf 'const char *biochef_library_path(void);\n' > src/biochef_library.h

# No OpenMP, whose threads write the sequences in another order in every
# run, and no -march=native, which builds for this machine only.
SOURCES="src/alignment.cpp src/stringBuffer.cc src/tn93_shared.cc src/argparse.cpp src/cawlign.cpp src/configparser.cpp src/scoring.cpp"
FLAGS="-O3 -std=c++14 -fsigned-char -funroll-loops -ffp-contract=off -Isrc -include src/biochef_library.h -DLIBRARY_PATH=biochef_library_path() -DVERSION_NUMBER=\"$(cat VERSION.txt)\""
mkdir -p out

em++ $FLAGS $SOURCES -o out/cawlign.js -sSTACK_SIZE=8MB --embed-file res@/biochef_res $EM_FLAGS
