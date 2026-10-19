set -eo pipefail

git submodule update --init --recursive

# Each window's sequences went into the partial order graph in an order
# std::sort gave them by start, which leaves ties in another order in
# libstdc++, here, than in libc++, in wasm, and the consensus changed with
# it. Ties now keep the order the sequences came in.
sed -i 's/^    std::sort(rank.begin() + 1, rank.end(), \[&\](uint32_t lhs, uint32_t rhs) {$/    std::stable_sort(rank.begin() + 1, rank.end(), [\&](uint32_t lhs, uint32_t rhs) {/' src/window.cpp
grep -q 'std::stable_sort(rank.begin() + 1, rank.end()' src/window.cpp

# racon reads the format of each input from its file name, and refuses any
# other; it also trusts the overlaps to name the reads and targets. This
# entry point, appended to racon's main file, reads the inputs first, refuses
# what racon would misread, and gives racon copies named by their content.
sed -i 's/^int main(int argc, char\*\* argv) {$/int biochef_upstream_main(int argc, char** argv) {/' src/main.cpp
grep -q '^int biochef_upstream_main(int argc, char\*\* argv) {$' src/main.cpp
cat >> src/main.cpp <<'BIOCHEF_EOF'

// The entry point of racon. It reads the sequences, the overlaps and the
// targets first, refuses what racon would misread or drop without a word,
// and gives racon copies of them named by their content, as racon reads the
// format of each from its file name.
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
	fputs("[racon] ", stderr);
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

// Lines of a file, plain or gzip, with NUL bytes refused and CR line ends dropped
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

static bool biochef_is_gzip(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) biochef_fail("cannot open %s (%s)", path, strerror(errno));
	unsigned char m[2] = { 0, 0 };
	size_t n = fread(m, 1, 2, f);
	fclose(f);
	return n == 2 && m[0] == 0x1f && m[1] == 0x8b;
}

// FASTA or FASTQ, as bioparser reads them, with unique names and bases of
// letters; returns each sequence's length by name, and whether it is FASTQ
static std::map<std::string, uint64_t> biochef_sequences(const char *path, const char *what, bool *fastq)
{
	biochef_lines in(path, what);
	std::map<std::string, uint64_t> lengths;
	bool have = in.next();
	long blank = 0;
	while (have && in.line.empty()) {
		if (!blank) blank = in.number;
		have = in.next();
	}
	if (!have) biochef_fail("the %s %s hold no sequence", what, path);
	// racon's parser throws, uncaught, on an empty line before the first
	// record, and in FASTQ between records
	if (blank) biochef_fail("line %ld of the %s %s is empty, before the first record", blank, what, path);
	char kind = in.line[0];
	if (kind != '>' && kind != '@')
		biochef_fail("the %s %s are neither FASTA nor FASTQ: line %ld starts with %s", what, path, in.number, biochef_shown((unsigned char)kind).c_str());
	*fastq = kind == '@';
	while (have) {
		if (in.line.empty()) {
			if (!blank) blank = in.number;
			have = in.next();
			continue;
		}
		if (blank) biochef_fail("line %ld of the %s %s is empty, between two records", blank, what, path);
		long start = in.number;
		if (in.line[0] != kind)
			biochef_fail("line %ld of the %s %s starts with %s, where a %s record starts with %c", start, what, path, biochef_shown((unsigned char)in.line[0]).c_str(), *fastq ? "FASTQ" : "FASTA", kind);
		size_t e = in.line.find_first_of(" \t", 1);
		std::string name = in.line.substr(1, e == std::string::npos ? std::string::npos : e - 1);
		if (name.empty()) biochef_fail("line %ld of the %s %s starts a sequence with no name", start, what, path);
		if (lengths.count(name)) biochef_fail("the %s %s have two sequences named %s", what, path, name.c_str());
		uint64_t bases = 0;
		while ((have = in.next()) && (in.line.empty() || (in.line[0] != kind && !(*fastq && in.line[0] == '+')))) {
			for (size_t i = 0; i < in.line.size(); i++) {
				unsigned char c = (unsigned char)in.line[i];
				if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')))
					biochef_fail("line %ld of the %s %s has %s in sequence %s", in.number, what, path, biochef_shown(c).c_str(), name.c_str());
			}
			bases += in.line.size();
		}
		if (!bases) biochef_fail("sequence %s, line %ld of the %s %s, has no bases", name.c_str(), start, what, path);
		if (*fastq) {
			if (!have) biochef_fail("read %s, line %ld of the %s %s, has no + line", name.c_str(), start, what, path);
			uint64_t quals = 0;
			while (quals < bases && (have = in.next())) {
				for (size_t i = 0; i < in.line.size(); i++) {
					unsigned char c = (unsigned char)in.line[i];
					if (c < 33 || c > 126) biochef_fail("line %ld of the %s %s has %s in the qualities of read %s", in.number, what, path, biochef_shown(c).c_str(), name.c_str());
				}
				quals += in.line.size();
			}
			if (quals != bases) biochef_fail("read %s, line %ld of the %s %s, has %llu bases and %llu qualities", name.c_str(), start, what, path, (unsigned long long)bases, (unsigned long long)quals);
			have = in.next();
		}
		if (bases > UINT32_MAX) biochef_fail("sequence %s of the %s %s is longer than %u bases", name.c_str(), what, path, UINT32_MAX);
		lengths[name] = bases;
	}
	return lengths;
}

static bool biochef_number_field(const std::string &s, uint64_t max, uint64_t *v)
{
	if (s.empty() || s.size() > 20) return false;
	uint64_t x = 0;
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] < '0' || s[i] > '9') return false;
		x = x * 10 + (uint64_t)(s[i] - '0');
	}
	if (x > max) return false;
	*v = x;
	return true;
}

static std::vector<std::string> biochef_split(const std::string &s, char sep)
{
	std::vector<std::string> f;
	size_t a = 0, b;
	while ((b = s.find(sep, a)) != std::string::npos) f.push_back(s.substr(a, b - a)), a = b + 1;
	f.push_back(s.substr(a));
	return f;
}

static void biochef_known(const char *path, long line, const char *role, const std::string &name, uint64_t len,
	const std::map<std::string, uint64_t> &in, const char *where, bool check_len)
{
	std::map<std::string, uint64_t>::const_iterator it = in.find(name);
	if (it == in.end()) biochef_fail("line %ld of the overlaps %s names the %s %s, which is not in the %s", line, path, role, name.c_str(), where);
	if (check_len && it->second != len)
		biochef_fail("line %ld of the overlaps %s gives %s %s %llu bases, and the %s %llu", line, path, role, name.c_str(), (unsigned long long)len, where, (unsigned long long)it->second);
}

// The overlaps, in PAF or SAM, each naming a sequence and a target of the
// files given, as long as they are there; returns the format
static std::string biochef_overlaps(const char *path, const std::map<std::string, uint64_t> &seqs, const std::map<std::string, uint64_t> &targets)
{
	biochef_lines in(path, "overlaps");
	std::string format;
	long records = 0;
	while (in.next()) {
		const std::string &l = in.line;
		// racon's parser throws, uncaught, on an empty line, an empty
		// column, and qualities of another length than the sequence
		if (l.empty()) biochef_fail("line %ld of the overlaps %s is empty", in.number, path);
		if (format.empty()) {
			std::vector<std::string> f = biochef_split(l, '\t');
			if (l[0] == '@') format = "sam";
			else if (f.size() >= 12 && (f[4] == "+" || f[4] == "-")) format = "paf";
			else if (f.size() >= 11) format = "sam";
			else biochef_fail("the overlaps %s are neither PAF nor SAM: line %ld has %zu tab-separated columns", path, in.number, f.size());
		}
		if (format == "sam" && l[0] == '@') continue;
		std::vector<std::string> f = biochef_split(l, '\t');
		uint64_t v[12] = { 0 };
		if (format == "paf") {
			static const char *const column[] = { "", "query length", "query start", "query end", "", "", "target length", "target start", "target end", "number of matching bases", "alignment block length", "mapping quality" };
			if (f.size() < 12) biochef_fail("line %ld of the overlaps %s has %zu tab-separated columns, and PAF has 12 or more", in.number, path, f.size());
			if (f[4] != "+" && f[4] != "-") biochef_fail("line %ld of the overlaps %s has the strand \"%s\", where PAF has + or -", in.number, path, f[4].c_str());
			for (int i = 1; i < 12; i++) {
				if (i == 4 || i == 5) continue;
				if (!biochef_number_field(f[i], i == 11 ? 255 : UINT32_MAX, &v[i]))
					biochef_fail("line %ld of the overlaps %s has the %s \"%s\", where PAF has a whole number", in.number, path, column[i], f[i].c_str());
			}
			if (v[2] > v[3] || v[3] > v[1]) biochef_fail("line %ld of the overlaps %s has the query from %llu to %llu in a sequence of %llu bases", in.number, path, (unsigned long long)v[2], (unsigned long long)v[3], (unsigned long long)v[1]);
			if (v[7] > v[8] || v[8] > v[6]) biochef_fail("line %ld of the overlaps %s has the target from %llu to %llu in a sequence of %llu bases", in.number, path, (unsigned long long)v[7], (unsigned long long)v[8], (unsigned long long)v[6]);
			biochef_known(path, in.number, "sequence", f[0], v[1], seqs, "sequences", true);
			biochef_known(path, in.number, "target", f[5], v[6], targets, "targets", true);
		} else {
			static const char *const column[] = { "read name", "flag", "reference name", "position", "mapping quality", "CIGAR", "mate's reference name", "mate's position", "template length", "sequence", "qualities" };
			if (f.size() < 11) biochef_fail("line %ld of the overlaps %s has %zu tab-separated columns, and SAM has 11 or more", in.number, path, f.size());
			for (int i = 0; i < 11; i++)
				if (f[i].find_first_not_of(" ") == std::string::npos) biochef_fail("line %ld of the overlaps %s has no %s", in.number, path, column[i]);
			uint64_t flag, pos, mapq, pnext, tlen;
			if (!biochef_number_field(f[1], 65535, &flag)) biochef_fail("line %ld of the overlaps %s has the flag \"%s\", where SAM has a whole number", in.number, path, f[1].c_str());
			if (!biochef_number_field(f[3], INT32_MAX, &pos)) biochef_fail("line %ld of the overlaps %s has the position \"%s\", where SAM has a whole number", in.number, path, f[3].c_str());
			if (!biochef_number_field(f[4], 255, &mapq)) biochef_fail("line %ld of the overlaps %s has the mapping quality \"%s\", where SAM has a whole number from 0 to 255", in.number, path, f[4].c_str());
			if (!biochef_number_field(f[7], INT32_MAX, &pnext)) biochef_fail("line %ld of the overlaps %s has the mate's position \"%s\", where SAM has a whole number", in.number, path, f[7].c_str());
			if (!biochef_number_field(f[8][0] == '-' ? f[8].substr(1) : f[8], INT32_MAX, &tlen)) biochef_fail("line %ld of the overlaps %s has the template length \"%s\", where SAM has a whole number", in.number, path, f[8].c_str());
			if (f[10] != "*" && (f[9] == "*" || f[10].size() != f[9].size()))
				biochef_fail("line %ld of the overlaps %s has %zu qualities for %s bases, where SAM has one per base or *", in.number, path, f[10].size(), f[9] == "*" ? "no" : std::to_string(f[9].size()).c_str());
			if (flag & 4) continue;
			biochef_known(path, in.number, "sequence", f[0], 0, seqs, "sequences", false);
			biochef_known(path, in.number, "target", f[2], 0, targets, "targets", false);
			uint64_t target_len = targets.find(f[2])->second, seq_len = seqs.find(f[0])->second;
			if (pos == 0 || pos > target_len) biochef_fail("line %ld of the overlaps %s places %s at %llu, outside its target %s", in.number, path, f[0].c_str(), (unsigned long long)pos, f[2].c_str());
			if (f[5] == "*") biochef_fail("line %ld of the overlaps %s maps %s with no CIGAR", in.number, path, f[0].c_str());
			uint64_t n = 0, q = 0, t = 0, aligned = 0;
			bool digits = false;
			for (size_t i = 0; i < f[5].size(); i++) {
				char c = f[5][i];
				if (c >= '0' && c <= '9') {
					n = n * 10 + (uint64_t)(c - '0');
					digits = true;
					if (n > UINT32_MAX) biochef_fail("line %ld of the overlaps %s has the CIGAR \"%s\", with an operation longer than %u", in.number, path, f[5].c_str(), UINT32_MAX);
					continue;
				}
				if (!digits || !strchr("MIDNSHP=X", c)) biochef_fail("line %ld of the overlaps %s has the CIGAR \"%s\", where SAM has lengths each followed by one of MIDNSHP=X", in.number, path, f[5].c_str());
				if (strchr("MIS=XH", c)) q += n;
				if (strchr("MDN=X", c)) t += n;
				if (strchr("M=X", c)) aligned += n;
				n = 0, digits = false;
			}
			if (digits) biochef_fail("line %ld of the overlaps %s has the CIGAR \"%s\", where SAM has lengths each followed by one of MIDNSHP=X", in.number, path, f[5].c_str());
			if (!aligned) biochef_fail("line %ld of the overlaps %s has the CIGAR \"%s\", which aligns no base of %s", in.number, path, f[5].c_str(), f[0].c_str());
			if (q != seq_len) biochef_fail("line %ld of the overlaps %s has a CIGAR of %llu bases for %s, and the sequences %llu", in.number, path, (unsigned long long)q, f[0].c_str(), (unsigned long long)seq_len);
			if (pos - 1 + t > target_len) biochef_fail("line %ld of the overlaps %s aligns %s up to %llu, past the end of its target %s of %llu bases", in.number, path, f[0].c_str(), (unsigned long long)(pos - 1 + t), f[2].c_str(), (unsigned long long)target_len);
		}
		records++;
	}
	if (!records) biochef_fail("the overlaps %s hold no overlap", path);
	return format;
}

static std::string biochef_copy(const char *from, const std::string &name)
{
	std::string to = biochef_dir + "/" + name;
	FILE *in = fopen(from, "rb"), *out = fopen(to.c_str(), "wb");
	if (!in || !out) biochef_fail("cannot copy %s (%s)", from, strerror(errno));
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0)
		if (fwrite(buf, 1, n, out) != n) biochef_fail("cannot write %s (%s)", to.c_str(), strerror(errno));
	fclose(in);
	if (fclose(out) != 0) biochef_fail("cannot write %s (%s)", to.c_str(), strerror(errno));
	return to;
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

static double biochef_number(const char *opt, const char *s, double min, double max)
{
	char *end;
	errno = 0;
	double v = strtod(s, &end);
	if (end == s || *end || errno || !(v >= min && v <= max) || strchr(" \t", *s))
		biochef_fail("%s should be a number from %g to %g, and is \"%s\"", opt, min, max, s);
	return v;
}

int main(int argc, char *argv[])
{
	std::vector<std::string> args(1, argv[0]), files;
	std::map<std::string, std::string> longs = { { "--include-unpolished", "-u" }, { "--fragment-correction", "-f" }, { "--no-trimming", "--no-trimming" },
		{ "--window-length", "-w" }, { "--quality-threshold", "-q" }, { "--error-threshold", "-e" }, { "--match", "-m" }, { "--mismatch", "-x" }, { "--gap", "-g" } };
	std::set<std::string> seen;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i], v;
		if (a.size() < 2 || a[0] != '-') {
			files.push_back(a);
			continue;
		}
		size_t eq = a.find('=');
		if (a.compare(0, 2, "--") == 0 && eq != std::string::npos) v = a.substr(eq + 1), a = a.substr(0, eq);
		if (longs.count(a)) a = longs[a];
		if (seen.count(a)) biochef_fail("%s is given twice", a.c_str());
		seen.insert(a);
		if (a == "-u" || a == "-f" || a == "--no-trimming") {
			args.push_back(a);
			continue;
		}
		if (a != "-w" && a != "-q" && a != "-e" && a != "-m" && a != "-x" && a != "-g") biochef_fail("has no option %s here", argv[i]);
		if (v.empty()) {
			if (i + 1 >= argc) biochef_fail("%s needs a value", a.c_str());
			v = argv[++i];
		}
		// spoa allocates 20 bytes per base squared of a window up front: past
		// 10000 bases wasm runs out of memory, and past 29000 the size
		// overflows 32 bits. It also throws on a gap score above 0.
		if (a == "-w") biochef_whole("-w", v.c_str(), 1, 10000);
		else if (a == "-q") biochef_number("-q", v.c_str(), 0, 93);
		else if (a == "-e") biochef_number("-e", v.c_str(), 0, 1);
		else if (a == "-g") biochef_whole("-g", v.c_str(), -128, 0);
		else biochef_whole(a.c_str(), v.c_str(), -128, 127);
		args.push_back(a);
		args.push_back(v);
	}
	if (files.size() != 3) biochef_fail("takes the sequences, their overlaps and the targets, three files, and was given %zu", files.size());
	const char *tmp = getenv("TMPDIR");
	std::string base = std::string(tmp && *tmp ? tmp : "/tmp") + "/racon.XXXXXX";
	std::vector<char> t(base.begin(), base.end());
	t.push_back(0);
	if (!mkdtemp(&t[0])) biochef_fail("cannot make a temporary directory (%s)", strerror(errno));
	biochef_dir = &t[0];
	atexit(biochef_remove_dir);
	bool seq_fastq, target_fastq;
	std::map<std::string, uint64_t> seqs = biochef_sequences(files[0].c_str(), "sequences", &seq_fastq);
	std::map<std::string, uint64_t> targets = biochef_sequences(files[2].c_str(), "targets", &target_fastq);
	// racon keeps one copy of a sequence that is also a target, and stops
	// if the two differ in length or in having qualities
	for (std::map<std::string, uint64_t>::const_iterator it = seqs.begin(); it != seqs.end(); ++it) {
		std::map<std::string, uint64_t>::const_iterator t = targets.find(it->first);
		if (t == targets.end()) continue;
		if (t->second != it->second)
			biochef_fail("%s is in the sequences, of %llu bases, and in the targets, of %llu", it->first.c_str(), (unsigned long long)it->second, (unsigned long long)t->second);
		if (seq_fastq != target_fastq)
			biochef_fail("%s is in the sequences, in %s, and in the targets, in %s", it->first.c_str(), seq_fastq ? "FASTQ" : "FASTA", target_fastq ? "FASTQ" : "FASTA");
	}
	std::string format = biochef_overlaps(files[1].c_str(), seqs, targets);
	const char *gz[3];
	for (int k = 0; k < 3; k++) gz[k] = biochef_is_gzip(files[k].c_str()) ? ".gz" : "";
	args.push_back("-t");
	args.push_back("1");
	args.push_back(biochef_copy(files[0].c_str(), std::string("sequences") + (seq_fastq ? ".fastq" : ".fasta") + gz[0]));
	args.push_back(biochef_copy(files[1].c_str(), "overlaps." + format + gz[1]));
	args.push_back(biochef_copy(files[2].c_str(), std::string("targets") + (target_fastq ? ".fastq" : ".fasta") + gz[2]));
	std::vector<char *> cargs;
	for (size_t i = 0; i < args.size(); i++) cargs.push_back(&args[i][0]);
	cargs.push_back(NULL);
	return biochef_upstream_main((int)cargs.size() - 1, &cargs[0]);
}
BIOCHEF_EOF


mkdir -p build && cd build
cmake -Dracon_build_tests=OFF -Dracon_enable_cuda=OFF -Dspoa_optimize_for_native=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-ffp-contract=off" ..
make -j4 racon
