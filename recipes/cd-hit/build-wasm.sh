set -eo pipefail

# The programs drop, without a word, the sequences they cannot read, read
# only files named .gz as compressed, and overflow their buffers on sequences
# longer than 655360 letters. This entry point, linked in front of each
# program's main, checks the options and reads the sequences strictly first,
# names the .clstr file (--bc-clusters) and puts cd-hit-div's parts in one tar
# (--bc-parts). The same entry point is in build-native.sh.
cat > biochef_main.c++ <<'SHIM_EOF'
// The entry point of the cd-hit programs: it checks the options and reads
// the sequences strictly, refusing what cd-hit would drop without a word,
// misread or crash on, then runs the program. --bc-clusters names the file
// for the .clstr file, and cd-hit-div's --bc-parts the tar its parts go in.
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <zlib.h>
#include <string>
#include <vector>

int biochef_upstream_main(int argc, char *argv[]);

// cd-hit's MAX_SEQ: longer sequences overflow its buffers.
#define LONGEST 655360

static std::vector<std::string> temporary;

static std::string parts_dir;

static void remove_temporary()
{
	for (size_t i = 0; i < temporary.size(); i++) remove(temporary[i].c_str());
	if (parts_dir.empty()) return;
	DIR *d = opendir(parts_dir.c_str());
	if (d) {
		struct dirent *e;
		while ((e = readdir(d)))
			if (strcmp(e->d_name, ".") && strcmp(e->d_name, ".."))
				remove((parts_dir + "/" + e->d_name).c_str());
		closedir(d);
	}
	rmdir(parts_dir.c_str());
}

static void fail(const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	fputs("[cd-hit] ", stderr);
	vfprintf(stderr, format, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

// A byte of the input as it can be shown in a message
static std::string shown(int c)
{
	char s[8];
	if (c >= 33 && c <= 126) snprintf(s, sizeof s, "'%c'", c);
	else snprintf(s, sizeof s, "0x%02X", c);
	return s;
}

static bool is_flag(const char *flag, const char *const *list)
{
	for (; *list; list++) if (strcmp(flag, *list) == 0) return true;
	return false;
}

static const char *const string_flags[] = { "-i", "-j", "-o", "-op", "-i2", "-j2", "-tmp", "-mask", NULL };
static const char *const real_flags[] = { "-c", "-s", "-aL", "-aS", "-uL", "-uS", "-s2", NULL };
static const char *const switch_flags[] = { "-G", "-g", "-p", "-r", "-sc", "-sf", "-B", "-bak", "-ap", "-P", NULL };
// Integers that cd-hit reads as lengths, counts or sizes
static const char *const count_flags[] = { "-M", "-l", "-b", "-n", "-d", "-t", "-S", "-S2", "-AL", "-AS", "-A", "-U", "-cx", "-cy", "-F", "-T", "-div", NULL };

static long whole(const char *flag, const char *value)
{
	char *end;
	errno = 0;
	long n = strtol(value, &end, 10);
	if (!*value || isspace((unsigned char)*value) || *end || errno || n < INT_MIN || n > INT_MAX)
		fail("%s takes a whole number, not \"%s\"", flag, value);
	return n;
}

static void check_option(const char *flag, const char *value, bool is454)
{
	if (is_flag(flag, string_flags)) {
		if (!*value) fail("%s takes a file name, not an empty one", flag);
		return;
	}
	// cd-hit-454's -D is the largest indel, the others' a distance
	if (is_flag(flag, real_flags) || (strcmp(flag, "-D") == 0 && !is454)) {
		char *end;
		errno = 0;
		double x = strtod(value, &end);
		if (!*value || isspace((unsigned char)*value) || *end || errno || !isfinite(x))
			fail("%s takes a number, not \"%s\"", flag, value);
		if (x < 0) fail("%s cannot be negative", flag);
		return;
	}
	long n = whole(flag, value);
	if (is_flag(flag, switch_flags)) {
		if (n != 0 && n != 1) fail("%s takes 0 or 1, not %s", flag, value);
	} else if (is_flag(flag, count_flags) || strcmp(flag, "-D") == 0) {
		if (n < 0) fail("%s cannot be negative", flag);
	}
	// -match, -mismatch, -gap and -gap-ext are scores, of either sign, that
	// cd-hit scales by LONGEST in an int; cd-hit rejects any other flag
	else if (strcmp(flag, "-match") == 0 || strcmp(flag, "-mismatch") == 0 || strcmp(flag, "-gap") == 0 || strcmp(flag, "-gap-ext") == 0) {
		if (n < -INT_MAX / LONGEST || n > INT_MAX / LONGEST) fail("%s must be between %d and %d", flag, -INT_MAX / LONGEST, INT_MAX / LONGEST);
	}
}

// What reading an input found
struct Input {
	bool fastq;
	long records;
	long kept;	// longer than -l
};

// The state of reading an input, line by line
struct Reader {
	const char *flag, *path;
	long shortest;
	bool limit, decided;
	Input r;
	long line, letters, part;	// part: the line of a FASTQ record, 0 to 3
	bool star;
};

static void sequence_end(Reader &s)
{
	if (s.limit && s.letters > LONGEST)
		fail("sequence %ld of %s is %ld letters long, longer than cd-hit can take (%d)", s.r.records, s.path, s.letters, LONGEST);
	if (s.letters > s.shortest) s.r.kept++;
}

// cd-hit skips one space or tab after '>' or '@', then takes the name up
// to the next space
static void check_name(Reader &s, const std::string &l)
{
	size_t i = 1;
	if (i < l.size() && (l[i] == ' ' || l[i] == '\t')) i++;
	if (i >= l.size() || isspace((unsigned char)l[i]))
		fail("record %ld of %s, on line %ld, has no name", s.r.records, s.path, s.line);
}

static void one_line(Reader &s, const std::string &l)
{
	for (size_t i = 0; i < l.size(); i++)
		if (!l[i]) fail("%s holds a NUL byte, on line %ld: it is not FASTA or FASTQ", s.path, s.line);
	if (!s.decided) {
		if (l.empty()) return;
		if (l[0] == '>') s.r.fastq = false;
		else if (l[0] == '@') s.r.fastq = true;
		else fail("%s (%s) is not FASTA or FASTQ: it starts with %s, not '>' or '@'", s.path, s.flag, shown((unsigned char)l[0]).c_str());
		s.decided = true;
	}
	if (!s.r.fastq) {
		if (!l.empty() && l[0] == '>') {
			if (s.r.records) sequence_end(s);
			s.r.records++;
			s.letters = 0, s.star = false;
			check_name(s, l);
			return;
		}
		for (size_t i = 0; i < l.size(); i++) {
			int c = (unsigned char)l[i];
			if (isalpha(c)) {
				if (s.star) fail("record %ld of %s goes on after its '*', on line %ld", s.r.records, s.path, s.line);
				s.letters++;
			} else if (c == '*' && !s.star) {
				s.star = true;
			} else if (!isspace(c)) {
				fail("record %ld of %s has %s in its sequence, on line %ld", s.r.records, s.path, shown(c).c_str(), s.line);
			}
		}
		return;
	}
	switch (s.part) {
	case 0:
		if (l.empty()) return;	// between records
		if (l[0] != '@') fail("line %ld of %s should start a FASTQ record with '@', not %s", s.line, s.path, shown((unsigned char)l[0]).c_str());
		s.r.records++;
		check_name(s, l);
		break;
	case 1:
		s.letters = 0;
		for (size_t i = 0; i < l.size(); i++) {
			if (!isalpha((unsigned char)l[i])) fail("FASTQ record %ld of %s has %s in its sequence, on line %ld", s.r.records, s.path, shown((unsigned char)l[i]).c_str(), s.line);
			s.letters++;
		}
		break;
	case 2:
		if (l.empty() || l[0] != '+') fail("line %ld of %s, in FASTQ record %ld, should be the '+' line, after one line of sequence", s.line, s.path, s.r.records);
		break;
	case 3:
		for (size_t i = 0; i < l.size(); i++) {
			int c = (unsigned char)l[i];
			if (c < 33 || c > 126) fail("FASTQ record %ld of %s has %s in its quality, on line %ld", s.r.records, s.path, shown(c).c_str(), s.line);
		}
		if ((long)l.size() != s.letters) fail("FASTQ record %ld of %s has %ld letters of sequence but %ld of quality", s.r.records, s.path, s.letters, (long)l.size());
		sequence_end(s);
		break;
	}
	s.part = (s.part + 1) % 4;
}

// Reads a FASTA or FASTQ file, compressed or not, as cd-hit would, and
// refuses what cd-hit would drop or misread. A compressed file is written
// out plainly to copy, because cd-hit only decompresses files named .gz, and
// cd-hit-div never does.
static Input read_input(const char *flag, const char *path, long shortest, bool limit, FILE *copy)
{
	gzFile in = gzopen(path, "rb");
	if (!in) fail("cannot open %s (%s)", path, strerror(errno));
	Reader s = { flag, path, shortest, limit, false, { false, 0, 0 }, 1, 0, 0, false };
	std::string l;
	static char buf[65536];
	int n;
	while ((n = gzread(in, buf, sizeof buf)) > 0) {
		if (copy && fwrite(buf, 1, n, copy) != (size_t)n) fail("cannot write a copy of %s", path);
		for (int i = 0; i < n; i++) {
			if (buf[i] != '\n') { l += buf[i]; continue; }
			if (!l.empty() && l[l.size() - 1] == '\r') l.erase(l.size() - 1);
			one_line(s, l);
			l.clear();
			s.line++;
		}
	}
	int error;
	const char *message = gzerror(in, &error);
	if (n < 0 || (error != Z_OK && error != Z_STREAM_END)) fail("cannot read %s: %s", path, message);
	gzclose(in);
	if (!l.empty()) {
		if (l[l.size() - 1] == '\r') l.erase(l.size() - 1);
		one_line(s, l);
	}
	if (s.r.fastq && s.part) fail("FASTQ record %ld of %s is cut short", s.r.records, path);
	if (!s.r.fastq && s.r.records) sequence_end(s);
	if (!s.r.records) fail("%s (%s) holds no sequences", path, flag);
	return s.r;
}

static bool gzipped(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) fail("cannot open %s (%s)", path, strerror(errno));
	unsigned char magic[2];
	bool z = fread(magic, 1, 2, f) == 2 && magic[0] == 0x1f && magic[1] == 0x8b;
	fclose(f);
	return z;
}

// Checks an input and gives the path cd-hit should read it from
static std::string prepare_input(const char *flag, const char *path, long shortest, bool limit, Input *found)
{
	if (!gzipped(path)) {
		*found = read_input(flag, path, shortest, limit, NULL);
		return path;
	}
	char name[] = "biochef-cdhit-in-XXXXXX";
	int fd = mkstemp(name);
	if (fd < 0) fail("cannot make a file to decompress %s into (%s)", path, strerror(errno));
	temporary.push_back(name);
	FILE *copy = fdopen(fd, "wb");
	if (!copy) fail("cannot write a copy of %s", path);
	*found = read_input(flag, path, shortest, limit, copy);
	if (fclose(copy)) fail("cannot write a copy of %s", path);
	return name;
}

static void put_octal(char *field, size_t width, unsigned long long value)
{
	snprintf(field, width, "%0*llo", (int)width - 1, value);
}

static void tar_member(FILE *out, const char *name, FILE *in, unsigned long long size)
{
	char header[512];
	memset(header, 0, sizeof header);
	strncpy(header, name, 100);
	put_octal(header + 100, 8, 0644);
	put_octal(header + 108, 8, 0);
	put_octal(header + 116, 8, 0);
	put_octal(header + 124, 12, size);
	put_octal(header + 136, 12, 0);
	header[156] = '0';
	memcpy(header + 257, "ustar", 6);
	memcpy(header + 263, "00", 2);
	memset(header + 148, ' ', 8);
	unsigned sum = 0;
	for (int i = 0; i < 512; i++) sum += (unsigned char)header[i];
	snprintf(header + 148, 8, "%06o", sum);
	if (fwrite(header, 1, 512, out) != 512) fail("cannot write the parts");
	static char buf[65536];
	size_t n;
	unsigned long long copied = 0;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
		if (fwrite(buf, 1, n, out) != n) fail("cannot write the parts");
		copied += n;
	}
	if (copied != size) fail("cannot read part %s", name);
	static const char zeros[512] = { 0 };
	size_t pad = (512 - size % 512) % 512;
	if (pad && fwrite(zeros, 1, pad, out) != pad) fail("cannot write the parts");
}

int main(int argc, char *argv[])
{
#ifdef BIOCHEF_DIV
	const char *own_flag = "--bc-parts";
#else
	const char *own_flag = "--bc-clusters";
#endif
#ifdef BIOCHEF_454
	bool is454 = true;
#else
	bool is454 = false;
#endif
	const char *own = NULL;
	std::vector<std::string> args;
	args.push_back(argv[0]);
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], own_flag) == 0) {
			if (i + 1 >= argc || !*argv[i + 1]) fail("%s needs a file name", own_flag);
			if (own) fail("%s is given twice", own_flag);
			own = argv[++i];
			continue;
		}
		if (argv[i][0] != '-' || !argv[i][1]) fail("unexpected argument \"%s\": options come as -flag value", argv[i]);
		if (i + 1 >= argc) fail("%s needs a value", argv[i]);
		for (size_t k = 1; k < args.size(); k += 2)
			if (args[k] == argv[i]) fail("%s is given twice", argv[i]);
		check_option(argv[i], argv[i + 1], is454);
		args.push_back(argv[i]);
		args.push_back(argv[i + 1]);
		i++;
	}
	atexit(remove_temporary);

	std::string *value_of_o = NULL;
	long shortest = 10, div = 0;
	bool has_div = false;
	for (size_t k = 1; k < args.size(); k += 2) {
		if (args[k] == "-o") value_of_o = &args[k + 1];
		else if (args[k] == "-l") shortest = atol(args[k + 1].c_str());
		else if (args[k] == "-div") div = atol(args[k + 1].c_str()), has_div = true;
	}
	// cd-hit trims after it drops the sequences of -l letters or fewer, and
	// reads past a sequence trimmed shorter than its words
	for (size_t k = 1; k < args.size(); k += 2) {
		if (args[k] != "-cx" && args[k] != "-cy") continue;
		long trim = atol(args[k + 1].c_str());
		if (trim && trim <= shortest) fail("%s must be 0, for no trimming, or more than -l (%ld)", args[k].c_str(), shortest);
	}

	Input first = { false, 0, 0 };
	bool have_first = false;
	for (size_t k = 1; k < args.size(); k += 2) {
		const std::string &flag = args[k];
		if (flag != "-i" && flag != "-j" && flag != "-i2" && flag != "-j2") continue;
		Input found;
#ifdef BIOCHEF_DIV
		args[k + 1] = prepare_input(flag.c_str(), args[k + 1].c_str(), -1, false, &found);
		if (!have_first) first = found, have_first = true;
#else
		args[k + 1] = prepare_input(flag.c_str(), args[k + 1].c_str(), shortest, true, &found);
		if (!found.kept) fail("no sequence of %s is longer than %ld letters (-l), the shortest cd-hit keeps", flag.c_str(), shortest);
#endif
	}

#ifdef BIOCHEF_DIV
	if (!own) fail("--bc-parts names the tar file to write the parts to");
	if (value_of_o) fail("-o is not taken: --bc-parts names the tar file to write the parts to");
	if (!has_div) fail("-div, the number of parts, is needed");
	if (div < 2) fail("-div must be 2 or more, not %ld", div);
	if (!have_first) fail("-i, the input, is needed");
	char dir[] = "biochef-cdhit-div-XXXXXX";
	if (!mkdtemp(dir)) fail("cannot make a directory for the parts (%s)", strerror(errno));
	std::string prefix = std::string(dir) + "/part";
	parts_dir = dir;
	args.push_back("-o");
	args.push_back(prefix);
#else
	if (own && !value_of_o) fail("-o is needed for %s", own_flag);
#endif

	std::vector<char *> v;
	for (size_t k = 0; k < args.size(); k++) v.push_back(&args[k][0]);
	v.push_back(NULL);
	int rc = biochef_upstream_main((int)args.size(), v.data());
	fflush(stdout);
	if (rc) return rc;

#ifdef BIOCHEF_DIV
	FILE *out = fopen(own, "wb");
	if (!out) fail("cannot write %s (%s)", own, strerror(errno));
	int written = 0;
	for (long p = 0;; p++) {
		std::string part = prefix + "-" + std::to_string(p);
		struct stat st;
		if (stat(part.c_str(), &st)) break;
		if (!st.st_size) continue;
		FILE *in = fopen(part.c_str(), "rb");
		if (!in) fail("cannot read %s", part.c_str());
		char name[64];
		snprintf(name, sizeof name, "part-%d.%s", ++written, first.fastq ? "fq" : "fa");
		tar_member(out, name, in, (unsigned long long)st.st_size);
		fclose(in);
	}
	static const char zeros[1024] = { 0 };
	if (fwrite(zeros, 1, 1024, out) != 1024 || fclose(out)) fail("cannot write %s", own);
	if (!written) fail("cd-hit-div wrote no parts");
#else
	if (own) {
		std::string clusters = *value_of_o + ".clstr";
		if (clusters != own && rename(clusters.c_str(), own)) fail("cannot move %s to %s (%s)", clusters.c_str(), own, strerror(errno));
	}
#endif
	return 0;
}
SHIM_EOF
sed -i -E 's/^int main\(int argc, char (\*\*argv|\*argv\[\])\) *$/int biochef_upstream_main(int argc, char *argv[])/' \
  cdhit.c++ cdhit-est.c++ cdhit-2d.c++ cdhit-est-2d.c++ cdhit-div.c++ cdhit-454.c++
[ "$(cat cdhit.c++ cdhit-est.c++ cdhit-2d.c++ cdhit-est-2d.c++ cdhit-div.c++ cdhit-454.c++ | grep -c '^int biochef_upstream_main(')" -eq 6 ]
! grep -q 'int main *(' cdhit.c++ cdhit-est.c++ cdhit-2d.c++ cdhit-est-2d.c++ cdhit-div.c++ cdhit-454.c++
# set_matrix reads a whole MAX_AA triangle from the nucleotide matrices,
# which hold only the first rows, so it read past them; the rest is never
# used, and is now zero. InitNAA's larger word counts overflow an int for the
# protein alphabet, where they are not used either; they now wrap as defined.
sed -i 's/^int BLOSUM62_na\[\] = {$/int BLOSUM62_na[MAX_AA * (MAX_AA + 1) \/ 2] = {/' cdhit-common.c++
sed -i 's/^int myBLOSUM62_na2\[\] = {$/int myBLOSUM62_na2[MAX_AA * (MAX_AA + 1) \/ 2] = {/' cdhit-454.c++
sed -i -E 's/^(\tNAA[0-9]+ *= NAAN_array\[[0-9]+\] *= )NAA([0-9]+) \* NAA([0-9]+);$/\1(int)((unsigned)NAA\2 * (unsigned)NAA\3);/' cdhit-common.c++
grep -q '^int BLOSUM62_na\[MAX_AA \* (MAX_AA + 1) / 2\] = {$' cdhit-common.c++
grep -q '^int myBLOSUM62_na2\[MAX_AA \* (MAX_AA + 1) / 2\] = {$' cdhit-454.c++
[ "$(grep -c '(int)((unsigned)NAA' cdhit-common.c++)" -eq 11 ]

emmake make CC=em++ openmp=no CXXFLAGS='-sUSE_ZLIB=1 -ffp-contract=off' cdhit-common.o cdhit-utility.o cdhit.o cdhit-est.o cdhit-2d.o cdhit-est-2d.o cdhit-div.o cdhit-454.o
FLAGS="-O2 -ffp-contract=off -DNO_OPENMP -DWITH_ZLIB -sUSE_ZLIB=1"
em++ $FLAGS -c biochef_main.c++ -o biochef_main.o
em++ $FLAGS -DBIOCHEF_DIV -c biochef_main.c++ -o biochef_main_div.o
em++ $FLAGS -DBIOCHEF_454 -c biochef_main.c++ -o biochef_main_454.o
for p in cd-hit:cdhit:biochef_main cd-hit-est:cdhit-est:biochef_main cd-hit-2d:cdhit-2d:biochef_main \
         cd-hit-est-2d:cdhit-est-2d:biochef_main cd-hit-div:cdhit-div:biochef_main_div cd-hit-454:cdhit-454:biochef_main_454; do
  IFS=: read -r bin obj shim <<< "$p"
  em++ $FLAGS $shim.o $obj.o cdhit-common.o cdhit-utility.o -o $bin.js $EM_FLAGS
done

mkdir -p out
for bin in cd-hit cd-hit-est cd-hit-2d cd-hit-est-2d cd-hit-div cd-hit-454; do mv $bin.js $bin.wasm out/; done
