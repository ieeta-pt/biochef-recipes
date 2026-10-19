set -eo pipefail

ROOT="$PWD"

# A compilation error at this commit.
sed -i 's|o\.sz_link\[i\]\.load()|o.unitig_cs_link[i].load()|' ext/bifrost/src/DataStorage.tcc
grep -q 'o.unitig_cs_link\[i\].load()' ext/bifrost/src/DataStorage.tcc

# Bifrost wrote a k-mer's bases as 0x1 << ((v - 1) << 1), which for A shifts
# -1 and then by a negative amount, undefined, and gives A only because both
# runtimes mask the shift. It now looks the base up.
sed -i -e 's/^\( *\)\*s = 0x40 | (v + 1) | (0x1 << ((v - 1) << 1));$/\1*s = "ACGT"[v \& 0x3];/' \
  -e 's/^\( *\)return (0x40 | (v + 1) | (0x1 << ((v - 1) << 1)));$/\1return "ACGT"[v \& 0x3];/' ext/bifrost/src/Kmer.cpp
[ "$(grep -c '"ACGT"\[v & 0x3\];' ext/bifrost/src/Kmer.cpp)" -eq 3 ]
[ "$(grep -c '0x1 << ((v - 1) << 1)' ext/bifrost/src/Kmer.cpp)" -eq 0 ]

# The hash of an equivalence class shifted a 32-bit value by 64 - i and by
# i up to 63, undefined, and taken modulo 32 by both runtimes. It now masks
# the shifts as they do, and gives the same hashes.
sed -i -e 's/^\( *\)t = (x>>i) | (x<<(64-i));$/\1t = (x>>(i \& 31)) | (uint32_t)(x<<((64-i) \& 31));/' src/KmerIndex.h
grep -q 't = (x>>(i & 31)) | (uint32_t)(x<<((64-i) & 31));' src/KmerIndex.h

# Learning the sequence bias (--bias), kallisto read six bases from the
# unitig at a read's end without checking they were there, and read past it.
# A hexamer past the unitig's end is now skipped, as one before its start is.
sed -i -e 's/^\( *\)hex = hexamerToInt(um.referenceUnitigToString().c_str() + (contig_start + pos - p - pre), true);$/\1{ const std::string biochef_u = um.referenceUnitigToString(); const size_t biochef_o = contig_start + pos - p - pre; hex = biochef_o + 6 <= biochef_u.size() ? hexamerToInt(biochef_u.c_str() + biochef_o, true) : -1; }/' \
  -e 's/^\( *\)hex = hexamerToInt(um.referenceUnitigToString().c_str() + (contig_start + pos_), false);$/\1{ const std::string biochef_u = um.referenceUnitigToString(); const size_t biochef_o = contig_start + pos_; hex = biochef_o + 6 <= biochef_u.size() ? hexamerToInt(biochef_u.c_str() + biochef_o, false) : -1; }/' src/MinCollector.cpp
[ "$(grep -c 'biochef_o + 6 <= biochef_u.size()' src/MinCollector.cpp)" -eq 2 ]

# The k-mers of a D-list belong to an id one past the last transcript, and
# with --bias kallisto wrote their blocks into that transcript's sequence,
# past the end of its list, and crashed. They are skipped.
sed -i '/^void KmerIndex::loadTranscriptSequences() const {$/,/^}$/ s/^\(      for (const auto& tr : trs) {\)$/\1\n        if (tr >= target_seqs.size()) continue;/' src/KmerIndex.cpp
grep -q '^        if (tr >= target_seqs.size()) continue;$' src/KmerIndex.cpp

# Bifrost seeded its Bloom filter and colour hashes from std::random_device,
# so the same transcripts gave another index in every run. The seeds are now
# fixed, and drawn from mt19937_64 itself: std::uniform_int_distribution and
# std::default_random_engine are the C++ library's own, and libstdc++, here,
# and libc++, in wasm, give other numbers from them.
sed -i -e 's/^\( *\)std::mt19937_64 gen(rd());$/\1std::mt19937_64 gen(42);/' -e 's/^\( *\)seed1 = distribution(gen);$/\1seed1 = gen();/' -e 's/^\( *\)seed2 = distribution(gen);$/\1seed2 = gen();/' ext/bifrost/src/BlockedBloomFilter.cpp
sed -i -e 's/^\( *\)std::default_random_engine generator(rd());.*$/\1std::mt19937_64 generator(42);/' -e 's/seeds\[i\] = distribution(generator);/seeds[i] = generator();/' ext/bifrost/src/DataStorage.tcc
[ "$(grep -c 'gen(42)\|seed[12] = gen();' ext/bifrost/src/BlockedBloomFilter.cpp)" -eq 3 ]
[ "$(grep -c 'std::mt19937_64 generator(42);' ext/bifrost/src/DataStorage.tcc)" -eq 3 ]
[ "$(grep -c 'seeds\[i\] = generator();' ext/bifrost/src/DataStorage.tcc)" -eq 3 ]

# The bootstrap drew from std::discrete_distribution over
# std::default_random_engine, the library's own too. It now draws from the
# counts with integers only.
cat > src/Multinomial.hpp <<'BIOCHEF_EOF'
#ifndef KALLISTO_MULTINOMIAL_H
#define KALLISTO_MULTINOMIAL_H

#include <algorithm>
#include <cstdint>
#include <random>
#include <stdexcept>
#include <vector>

// Draws from the counts with integers only, from mt19937_64, whose numbers
// the standard fixes: std::default_random_engine and std::discrete_distribution
// are the library's own, and libstdc++ and libc++ draw other samples from them.
class Multinomial {
 public:
  Multinomial(const std::vector<uint32_t>& counts, uint64_t seed = 42)
      : counts_(counts), gen_(seed), n_(0) {
    uint64_t total = 0;
    for (auto c : counts_) {
      n_ += c;
      total += c;
      cumulative_.push_back(total);
    }
  }

  std::vector<uint32_t> sample(int nsamp) {
    if (nsamp < 1) {
      throw std::domain_error("nsamp must be -1 or >=1");
    }
    std::vector<uint32_t> samp(counts_.size(), 0);
    const uint64_t total = cumulative_.empty() ? 0 : cumulative_.back();
    if (total == 0) {
      return samp;
    }
    const uint64_t limit = UINT64_MAX - UINT64_MAX % total;
    for (auto i = 0; i < nsamp; ++i) {
      uint64_t r;
      do {
        r = gen_();
      } while (r >= limit);
      r %= total;
      ++samp[std::upper_bound(cumulative_.begin(), cumulative_.end(), r) - cumulative_.begin()];
    }
    return samp;
  }

  std::vector<uint32_t> sample() {
    return sample(n_);
  }

  int n() const {
    return n_;
  }
  const std::vector<uint32_t>& counts() {
    return counts_;
  }

 private:
  const std::vector<uint32_t>& counts_;
  std::vector<uint64_t> cumulative_;
  std::mt19937_64 gen_;
  int n_;
};

#endif
BIOCHEF_EOF

# exp, log and pow are called, not folded at compile time, and no step is
# fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-log -fno-builtin-pow"

# Bifrost is built on its own, with the flags of the rest, rather than by
# kallisto's CMake.
sed -i '/^ExternalProject_Add(bifrost/,/^)/c\
ExternalProject_Add(bifrost PREFIX ${PROJECT_SOURCE_DIR}/ext/bifrost SOURCE_DIR ${PROJECT_SOURCE_DIR}/ext/bifrost BUILD_IN_SOURCE 1 CONFIGURE_COMMAND "" BUILD_COMMAND "" INSTALL_COMMAND "")' CMakeLists.txt
grep -q 'CONFIGURE_COMMAND "" BUILD_COMMAND "" INSTALL_COMMAND ""' CMakeLists.txt

# wasm has no threads here, and kallisto and Bifrost start workers even for
# one thread. A thread now runs its function when it is made: they only
# start workers and wait for them, so the workers run one after the other.
cat > biochef_thread.h <<'BIOCHEF_EOF'
// wasm has no threads here: a thread runs its function when it is made,
// and joining it does nothing. kallisto and Bifrost only start workers and
// wait for them, so the workers run one after the other.
#ifndef BIOCHEF_THREAD_H
#define BIOCHEF_THREAD_H
#ifdef __cplusplus
#include <functional>
#include <type_traits>
#include <utility>
namespace biochef {
class thread {
public:
	thread() noexcept {}
	template <class F, class... A, class = typename std::enable_if<!std::is_same<typename std::decay<F>::type, thread>::value>::type>
	explicit thread(F &&f, A &&...a) { std::bind(std::forward<F>(f), std::forward<A>(a)...)(); }
	thread(thread &&) noexcept {}
	thread &operator=(thread &&) noexcept { return *this; }
	thread(const thread &) = delete;
	thread &operator=(const thread &) = delete;
	void join() {}
	void detach() {}
	bool joinable() const noexcept { return false; }
	static unsigned int hardware_concurrency() noexcept { return 1; }
};
}
#endif
#endif
BIOCHEF_EOF
grep -rlE 'std::thread\b' src ext/bifrost/src | xargs sed -i -E 's/std::thread\b/biochef::thread/g'
sed -i -E -e 's/pthread_create \(&tab_threads\[ii\], NULL, +(thread_processLevel<[^;]*>), &t_arg\);/\1(\&t_arg);/' -e 's/^( *)pthread_join\(tab_threads\[ii\], NULL\);/\1;/' ext/bifrost/src/BooPHF.h
[ "$(grep -c 'pthread_create\|pthread_join' ext/bifrost/src/BooPHF.h)" -eq 0 ]

# Bifrost keeps a unitig's id and a position in one size_t, shifted by 32
# bits, and pointers or bits in one uintptr_t; kallisto writes sizes into the
# index as size_t. In wasm32 both are 32-bit, so the ids overflowed and the
# index differed. They are 64-bit here, as natively, and the index is the same
# file in both runtimes. robin_hood's and CRoaring's size_t are about memory,
# and stay.
grep -rlE '\bsize_t\b' ext/bifrost/src src | grep -v 'src/robin_hood.h$\|/roaring\.' | xargs sed -i -E 's/(^|[^:_A-Za-z0-9])size_t\b/\1uint64_t/g'
grep -rlE '\buintptr_t\b' ext/bifrost/src | grep -v '/roaring\.' | xargs sed -i -E 's/(^|[^:_A-Za-z0-9])uintptr_t\b/\1uint64_t/g'
sed -i -E 's/std::min\((start \+ slice, v_(blocks|unitigs)\.size\(\))\)/std::min<uint64_t>(\1)/' ext/bifrost/src/KmerCovIndex.tcc ext/bifrost/src/CompactedDBG.tcc
sed -i 's/std::min(filename_seq_in.size(), tv_nb_max_elem)/std::min<uint64_t>(filename_seq_in.size(), tv_nb_max_elem)/' ext/bifrost/src/ColoredCDBG.tcc
[ "$(cat ext/bifrost/src/KmerCovIndex.tcc ext/bifrost/src/CompactedDBG.tcc ext/bifrost/src/ColoredCDBG.tcc | grep -c 'std::min<uint64_t>')" -eq 3 ]

# The entry point, appended to kallisto's main file.
sed -i 's/^int main(int argc, char \*argv\[\]) {$/int biochef_upstream_main(int argc, char *argv[]) {/' src/main.cpp
grep -q '^int biochef_upstream_main(int argc, char \*argv\[\]) {$' src/main.cpp
cat >> src/main.cpp <<'BIOCHEF_EOF'

// The entry point of kallisto. It reads the transcripts, the reads and the
// index first and refuses what kallisto would misread, keeps the options to
// those of index, quant, bus and inspect, and writes the files quant and bus
// put in an output directory to the files --bc-* name, from a temporary
// directory it removes.
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>
#include <map>
#include <set>
#include <string>
#include <vector>

static void biochef_fail(const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	fputs("[kallisto] ", stderr);
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

static std::string biochef_dir;

static void biochef_remove(const std::string &path)
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
			for (size_t i = 0; i < names.size(); i++) biochef_remove(path + "/" + names[i]);
		}
		rmdir(path.c_str());
	} else {
		unlink(path.c_str());
	}
}

static void biochef_remove_dir(void)
{
	if (!biochef_dir.empty()) biochef_remove(biochef_dir);
}

static void biochef_make_dir(void)
{
	const char *tmp = getenv("TMPDIR");
	std::string base = std::string(tmp && *tmp ? tmp : "/tmp") + "/kallisto.XXXXXX";
	std::vector<char> t(base.begin(), base.end());
	t.push_back(0);
	if (!mkdtemp(&t[0])) biochef_fail("cannot make a temporary directory (%s)", strerror(errno));
	biochef_dir = &t[0];
	if (biochef_dir[0] != '/') {
		char cwd[PATH_MAX];
		if (!getcwd(cwd, sizeof cwd)) biochef_fail("cannot get the working directory (%s)", strerror(errno));
		biochef_dir = std::string(cwd) + "/" + biochef_dir;
	}
	atexit(biochef_remove_dir);
}

// Lines of a file, plain or gzip, as kallisto's reader takes it, with NUL
// bytes refused and CR line ends dropped
struct biochef_lines {
	gzFile f;
	const char *path, *what;
	long number;
	std::string line;
	char buf[65536];
	int len, at;
	bool eof;
	biochef_lines(const char *p, const char *w) : path(p), what(w), number(0), len(0), at(0), eof(false) {
		f = gzopen(p, "rb");
		if (!f) biochef_fail("cannot open the %s %s (%s)", w, p, strerror(errno));
	}
	~biochef_lines() { gzclose(f); }
	bool next() {
		line.clear();
		bool any = false;
		for (;;) {
			if (at == len) {
				if (eof) break;
				len = gzread(f, buf, sizeof buf), at = 0;
				if (len < 0) {
					int err;
					biochef_fail("cannot read the %s %s (%s)", what, path, gzerror(f, &err));
				}
				if (len == 0) {
					eof = true;
					break;
				}
			}
			any = true;
			char c = buf[at++];
			if (c == '\n') break;
			if (!c) biochef_fail("line %ld of the %s %s holds a NUL byte", number + 1, what, path);
			line += c;
		}
		if (!any) return false;
		number++;
		if (!line.empty() && line[line.size() - 1] == '\r') line.erase(line.size() - 1);
		return true;
	}
};

static const char *const biochef_nucleotides = "ACGTUNRYSWKMBDHV";
static const char *const biochef_residues = "ACDEFGHIKLMNPQRSTVWYBZXJUO*";

// FASTA of sequences of letters, with unique names unless kallisto makes them
// unique; returns how many
static size_t biochef_check_fasta(const char *path, const char *what, bool aa, bool unique)
{
	biochef_lines in(path, what);
	std::set<std::string> names;
	std::string name;
	long start = 0, bases = 0;
	const char *valid = aa ? biochef_residues : biochef_nucleotides;
	while (in.next()) {
		const std::string &l = in.line;
		if (!l.empty() && l[0] == '>') {
			if (!name.empty() && !bases) biochef_fail("sequence %s, line %ld of the %s %s, has no %s", name.c_str(), start, what, path, aa ? "residues" : "bases");
			size_t e = l.find_first_of(" \t", 1);
			name = l.substr(1, e == std::string::npos ? std::string::npos : e - 1);
			if (name.empty()) biochef_fail("line %ld of the %s %s starts a sequence with no name", in.number, what, path);
			if (!names.insert(name).second && unique)
				biochef_fail("the %s %s has two sequences named %s; --make-unique would rename them", what, path, name.c_str());
			start = in.number, bases = 0;
			continue;
		}
		if (l.find_first_not_of(" \t") == std::string::npos) continue;
		if (name.empty()) biochef_fail("the %s %s is not FASTA: line %ld comes before any > line", what, path, in.number);
		for (size_t i = 0; i < l.size(); i++) {
			unsigned char c = (unsigned char)l[i];
			unsigned char u = (c >= 'a' && c <= 'z') ? c - 32 : c;
			if (!u || !strchr(valid, u))
				biochef_fail("line %ld of the %s %s has %s in sequence %s, which is not %s", in.number, what, path, biochef_shown(c).c_str(), name.c_str(), aa ? "an amino acid" : "a nucleotide");
			bases++;
		}
	}
	if (!name.empty() && !bases) biochef_fail("sequence %s, line %ld of the %s %s, has no %s", name.c_str(), start, what, path, aa ? "residues" : "bases");
	if (names.empty()) biochef_fail("the %s %s holds no sequence", what, path);
	return names.size();
}

// FASTQ, as kseq reads it: a header, bases over one or more lines, a + line,
// and as many qualities
static size_t biochef_check_fastq(const char *path)
{
	biochef_lines in(path, "reads");
	size_t reads = 0;
	bool have = in.next();
	while (have) {
		if (in.line.empty()) {
			have = in.next();
			continue;
		}
		long start = in.number;
		if (in.line[0] != '@') biochef_fail("the reads %s are not FASTQ: line %ld starts with %s, not @", path, start, biochef_shown((unsigned char)in.line[0]).c_str());
		std::string name = in.line.substr(1, in.line.find_first_of(" \t") == std::string::npos ? std::string::npos : in.line.find_first_of(" \t") - 1);
		if (name.empty()) biochef_fail("line %ld of the reads %s starts a read with no name", start, path);
		size_t bases = 0, quals = 0;
		while ((have = in.next()) && (in.line.empty() || in.line[0] != '+')) {
			for (size_t i = 0; i < in.line.size(); i++) {
				unsigned char c = (unsigned char)in.line[i];
				if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')))
					biochef_fail("line %ld of the reads %s has %s in read %s", in.number, path, biochef_shown(c).c_str(), name.c_str());
			}
			bases += in.line.size();
		}
		if (!have) biochef_fail("read %s, line %ld of the reads %s, has no + line", name.c_str(), start, path);
		if (!bases) biochef_fail("read %s, line %ld of the reads %s, has no bases", name.c_str(), start, path);
		while (quals < bases && (have = in.next())) {
			for (size_t i = 0; i < in.line.size(); i++) {
				unsigned char c = (unsigned char)in.line[i];
				if (c < 33 || c > 126) biochef_fail("line %ld of the reads %s has %s in the qualities of read %s", in.number, path, biochef_shown(c).c_str(), name.c_str());
			}
			quals += in.line.size();
		}
		if (quals != bases) biochef_fail("read %s, line %ld of the reads %s, has %zu bases and %zu qualities", name.c_str(), start, path, bases, quals);
		reads++;
		have = in.next();
	}
	if (!reads) biochef_fail("the reads %s hold no read", path);
	return reads;
}

// A kallisto index starts with its version, 13 for kallisto 0.50 and later
static void biochef_check_index(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) biochef_fail("cannot open the index %s (%s)", path, strerror(errno));
	unsigned char v[8];
	size_t n = fread(v, 1, 8, f);
	fclose(f);
	uint64_t version = 0;
	for (int i = 7; i >= 0 && n == 8; i--) version = version << 8 | v[i];
	if (n != 8 || version != 13)
		biochef_fail("%s is not a kallisto index of version 13, which kallisto index 0.50 and later write", path);
}

// A copy of a FASTA with its sequences in upper case: kallisto index
// --distinguish loops for ever on a sequence that mixes cases
static std::string biochef_upper_copy(const char *path)
{
	biochef_lines in(path, "transcripts");
	std::string out = biochef_dir + "/transcripts.fa";
	FILE *f = fopen(out.c_str(), "wb");
	if (!f) biochef_fail("cannot write %s (%s)", out.c_str(), strerror(errno));
	while (in.next()) {
		std::string l = in.line;
		if (l.empty() || l[0] != '>')
			for (size_t i = 0; i < l.size(); i++)
				if (l[i] >= 'a' && l[i] <= 'z') l[i] -= 32;
		fprintf(f, "%s\n", l.c_str());
	}
	if (fclose(f) != 0) biochef_fail("cannot write %s (%s)", out.c_str(), strerror(errno));
	return out;
}

static long biochef_whole(const char *opt, const char *s, long min, long max)
{
	char *end;
	errno = 0;
	long v = strtol(s, &end, 10);
	if (!*s || *end || errno || v < min || v > max || strchr(" \t+", *s))
		biochef_fail("%s should be a whole number from %ld to %ld, and is \"%s\"", opt, min, max, s);
	return v;
}

static double biochef_number(const char *opt, const char *s)
{
	char *end;
	errno = 0;
	double v = strtod(s, &end);
	if (end == s || *end || errno || !(v > 0) || v > 1e9 || strchr(" \t", *s))
		biochef_fail("%s should be a number above 0, and is \"%s\"", opt, s);
	return v;
}

static void biochef_copy(const std::string &from, const char *to)
{
	FILE *in = fopen(from.c_str(), "rb");
	if (!in) biochef_fail("kallisto wrote no %s", from.substr(from.rfind('/') + 1).c_str());
	FILE *out = fopen(to, "wb");
	if (!out) biochef_fail("cannot write %s (%s)", to, strerror(errno));
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0)
		if (fwrite(buf, 1, n, out) != n) biochef_fail("cannot write %s (%s)", to, strerror(errno));
	fclose(in);
	if (fclose(out) != 0) biochef_fail("cannot write %s (%s)", to, strerror(errno));
}

int main(int argc, char *argv[])
{
	if (argc < 2) biochef_fail("needs a command: index, quant, bus or inspect");
	std::string cmd = argv[1];
	if (cmd != "index" && cmd != "quant" && cmd != "bus" && cmd != "inspect")
		biochef_fail("has no command %s here: index, quant, bus or inspect", argv[1]);
	// Options that take a value, and flags, for each command
	std::map<std::string, std::string> values, flags;
	if (cmd == "index") {
		values = { { "-i", "--index" }, { "-k", "--kmer-size" }, { "-m", "--min-size" }, { "-e", "--ec-max-size" }, { "-d", "--d-list" } };
		flags = { { "--make-unique", "" }, { "--aa", "" }, { "--distinguish", "" } };
	} else if (cmd == "quant") {
		values = { { "-i", "--index" }, { "-l", "--fragment-length" }, { "-s", "--sd" }, { "--bc-abundance", "" }, { "--bc-run-info", "" } };
		flags = { { "--single", "" }, { "--single-overhang", "" }, { "--fr-stranded", "" }, { "--rf-stranded", "" }, { "--bias", "" } };
	} else if (cmd == "bus") {
		values = { { "-i", "--index" }, { "-x", "--technology" }, { "--bc-bus", "" }, { "--bc-ec", "" }, { "--bc-transcripts", "" }, { "--bc-run-info", "" } };
		flags = { { "--paired", "" }, { "--fr-stranded", "" }, { "--rf-stranded", "" }, { "--unstranded", "" }, { "--aa", "" } };
	} else {
		values = { { "--gfa", "-G" } };
	}
	std::map<std::string, std::string> got;
	std::set<std::string> set;
	std::vector<std::string> files;
	for (int i = 2; i < argc; i++) {
		std::string a = argv[i];
		if (a.size() < 2 || a[0] != '-') {
			files.push_back(a);
			continue;
		}
		std::string key, v;
		size_t eq = a.find('=');
		std::string name = a.substr(0, eq);
		for (std::map<std::string, std::string>::iterator it = values.begin(); it != values.end(); ++it)
			if (name == it->first || (!it->second.empty() && name == it->second)) key = it->first;
		if (!key.empty()) {
			if (eq != std::string::npos) v = a.substr(eq + 1);
			else if (i + 1 < argc) v = argv[++i];
			else biochef_fail("%s needs a value", name.c_str());
			if (got.count(key)) biochef_fail("%s is given twice", name.c_str());
			got[key] = v;
			continue;
		}
		if (flags.count(a)) {
			set.insert(a);
			continue;
		}
		biochef_fail("kallisto %s has no option %s here", cmd.c_str(), a.c_str());
	}
	std::vector<std::string> args;
	args.push_back(argv[0]);
	args.push_back(cmd);
	biochef_make_dir();
	if (cmd == "index") {
		if (!got.count("-i")) biochef_fail("index needs -i, the file the index goes to");
		long k = got.count("-k") ? biochef_whole("-k", got["-k"].c_str(), 3, 31) : 31;
		if (k % 2 == 0) biochef_fail("-k should be odd, and is %ld", k);
		if (got.count("-m")) {
			long m = biochef_whole("-m", got["-m"].c_str(), 3, k - 2);
			if (m % 2 == 0) biochef_fail("-m should be odd, and is %ld", m);
		}
		if (got.count("-e")) biochef_whole("-e", got["-e"].c_str(), 0, INT_MAX);
		if (files.size() != 1) biochef_fail("index takes one FASTA file of transcripts, and was given %zu", files.size());
		bool aa = set.count("--aa");
		biochef_check_fasta(files[0].c_str(), "transcripts", aa, !set.count("--make-unique"));
		if (got.count("-d")) biochef_check_fasta(got["-d"].c_str(), "D-list", false, false);
		if (set.count("--distinguish")) files[0] = biochef_upper_copy(files[0].c_str());
		for (std::map<std::string, std::string>::iterator it = got.begin(); it != got.end(); ++it) args.push_back(it->first), args.push_back(it->second);
		args.push_back("-t"), args.push_back("1");
		args.push_back("-T"), args.push_back(biochef_dir + "/tmp");
	} else if (cmd == "quant") {
		if (!got.count("-i")) biochef_fail("quant needs -i, the index");
		if (!got.count("--bc-abundance") || !got.count("--bc-run-info")) biochef_fail("quant needs --bc-abundance and --bc-run-info, the files its abundances and run information go to");
		biochef_check_index(got["-i"].c_str());
		bool single = set.count("--single");
		if (single != (files.size() == 1) || files.size() > 2 || files.empty())
			biochef_fail("quant takes two FASTQ files of paired reads, or one with --single, and was given %zu", files.size());
		if (single && (!got.count("-l") || !got.count("-s"))) biochef_fail("--single needs -l and -s, the mean and standard deviation of the fragment length");
		if (!single && (got.count("-l") || got.count("-s"))) biochef_fail("-l and -s are for --single: for paired reads kallisto estimates the fragment length");
		if (!single && (set.count("--fr-stranded") || set.count("--rf-stranded") || set.count("--single-overhang")))
			biochef_fail("--fr-stranded, --rf-stranded and --single-overhang are for --single");
		if (set.count("--fr-stranded") && set.count("--rf-stranded")) biochef_fail("--fr-stranded and --rf-stranded exclude each other");
		if (got.count("-l")) biochef_number("-l", got["-l"].c_str());
		if (got.count("-s")) biochef_number("-s", got["-s"].c_str());
		std::vector<size_t> counts;
		for (size_t i = 0; i < files.size(); i++) counts.push_back(biochef_check_fastq(files[i].c_str()));
		if (counts.size() == 2 && counts[0] != counts[1])
			biochef_fail("the paired reads %s and %s hold %zu and %zu reads", files[0].c_str(), files[1].c_str(), counts[0], counts[1]);
		args.push_back("-i"), args.push_back(got["-i"]);
		if (got.count("-l")) args.push_back("-l"), args.push_back(got["-l"]), args.push_back("-s"), args.push_back(got["-s"]);
		args.push_back("-o"), args.push_back(biochef_dir + "/out");
		args.push_back("-t"), args.push_back("1");
	} else if (cmd == "bus") {
		if (!got.count("-i")) biochef_fail("bus needs -i, the index");
		if (!got.count("-x")) biochef_fail("bus needs -x, the technology");
		static const char *const outs[] = { "--bc-bus", "--bc-ec", "--bc-transcripts", "--bc-run-info" };
		for (int o = 0; o < 4; o++)
			if (!got.count(outs[o])) biochef_fail("bus needs --bc-bus, --bc-ec, --bc-transcripts and --bc-run-info, the files its output goes to");
		biochef_check_index(got["-i"].c_str());
		if (files.empty()) biochef_fail("bus needs FASTQ files of reads");
		int stranded = (int)set.count("--fr-stranded") + (int)set.count("--rf-stranded") + (int)set.count("--unstranded");
		if (stranded > 1) biochef_fail("--fr-stranded, --rf-stranded and --unstranded exclude each other");
		for (size_t i = 0; i < files.size(); i++) biochef_check_fastq(files[i].c_str());
		args.push_back("-i"), args.push_back(got["-i"]);
		args.push_back("-x"), args.push_back(got["-x"]);
		args.push_back("-o"), args.push_back(biochef_dir + "/out");
		args.push_back("-t"), args.push_back("1");
	} else {
		if (files.size() != 1) biochef_fail("inspect takes one index, and was given %zu files", files.size());
		biochef_check_index(files[0].c_str());
		if (got.count("--gfa")) args.push_back("--gfa"), args.push_back(got["--gfa"]);
	}
	for (std::set<std::string>::iterator it = set.begin(); it != set.end(); ++it) args.push_back(*it);
	for (size_t i = 0; i < files.size(); i++) args.push_back(files[i]);
	std::vector<char *> cargs;
	for (size_t i = 0; i < args.size(); i++) cargs.push_back(&args[i][0]);
	cargs.push_back(NULL);
	int rc = biochef_upstream_main((int)cargs.size() - 1, &cargs[0]);
	if (rc) return rc;
	std::string out = biochef_dir + "/out/";
	if (cmd == "quant") {
		biochef_copy(out + "abundance.tsv", got["--bc-abundance"].c_str());
		biochef_copy(out + "run_info.json", got["--bc-run-info"].c_str());
	} else if (cmd == "bus") {
		biochef_copy(out + "output.bus", got["--bc-bus"].c_str());
		biochef_copy(out + "matrix.ec", got["--bc-ec"].c_str());
		biochef_copy(out + "transcripts.txt", got["--bc-transcripts"].c_str());
		biochef_copy(out + "run_info.json", got["--bc-run-info"].c_str());
	}
	return 0;
}
BIOCHEF_EOF

# bifrost calls find_package(ZLIB REQUIRED), which only resolves once the
# emscripten zlib port has been built into the sysroot.
embuilder build zlib

# clang rejects -mno-avx2 for wasm32.
sed -i 's|-mno-avx2||g' ext/bifrost/CMakeLists.txt

WASM_FLAGS="-O2 $BIOCHEF_MATH_FLAGS -sUSE_ZLIB=1 -include $ROOT/biochef_thread.h -Wno-c++11-narrowing -Wno-narrowing -Wno-c++11-narrowing-const-reference -Wno-shift-count-overflow"

mkdir -p ext/bifrost/build && cd ext/bifrost/build
emcmake cmake .. -DMAX_KMER_SIZE=32 -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="$WASM_FLAGS -Wno-subobject-linkage"
emmake make bifrost_static -j4
cd "$ROOT"

mkdir -p build && cd build
emcmake cmake .. -DUSE_HDF5=OFF -DUSE_BAM=OFF -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="$WASM_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sSTACK_SIZE=8MB"
emmake make kallisto -j4
cd "$ROOT"

mkdir -p out && mv build/src/kallisto.js out/kallisto.js && mv build/src/kallisto.wasm out/kallisto.wasm
