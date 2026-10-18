set -eo pipefail

# dwgsim takes the reference and a prefix for the files it writes, gzipped,
# under fixed names. This entry point, linked in front of dwgsim's main,
# checks the options and reads the reference strictly first, runs dwgsim in a
# directory of its own, and moves each file it writes to the name asked for
# it. The same entry point is in build-native.sh.
cat > biochef_main.c <<'SHIM_EOF'
/* The entry point of dwgsim: it checks the options and reads the reference
 * strictly, refusing what dwgsim would skip without a word, misread or crash
 * on, then runs dwgsim in a directory of its own and moves each file it
 * writes to the name asked for it: --bc-read1, --bc-read2 and --bc-vcf.
 * --bc-amplicons 1 is -a. */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

int biochef_upstream_main(int argc, char *argv[]);

/* dwgsim's calls to log, renamed by the build: fdlibm's log, so that the
 * insert sizes and qualities come out the same natively and in wasm */
static uint64_t bits(double x) { uint64_t u; memcpy(&u, &x, 8); return u; }
static double from_bits(uint64_t u) { double x; memcpy(&x, &u, 8); return x; }

double biochef_log(double x)
{
	static const double ln2_hi = 6.93147180369123816490e-01, ln2_lo = 1.90821492927058770002e-10,
		Lg1 = 6.666666666666735130e-01, Lg2 = 3.999999999940941908e-01,
		Lg3 = 2.857142874366239149e-01, Lg4 = 2.222219843214978396e-01,
		Lg5 = 1.818357216161805012e-01, Lg6 = 1.531383769920937332e-01,
		Lg7 = 1.479819860511658591e-01;
	uint64_t u = bits(x);
	double hfsq, f, s, z, R, w, t1, t2, dk;
	uint32_t hx = (uint32_t)(u >> 32);
	int k = 0;

	if (hx < 0x00100000 || hx >> 31) {
		if (u << 1 == 0) return -1 / (x * x); /* log(0) = -inf */
		if (hx >> 31) return (x - x) / 0.0;   /* log(-x) = NaN */
		k -= 54, x *= 0x1p54; /* subnormal */
		u = bits(x);
		hx = (uint32_t)(u >> 32);
	} else if (hx >= 0x7ff00000) {
		return x;
	} else if (hx == 0x3ff00000 && u << 32 == 0) {
		return 0;
	}
	/* x into [sqrt(2)/2, sqrt(2)] */
	hx += 0x3ff00000 - 0x3fe6a09e;
	k += (int)(hx >> 20) - 0x3ff;
	hx = (hx & 0x000fffff) + 0x3fe6a09e;
	x = from_bits((uint64_t)hx << 32 | (u & 0xffffffff));
	f = x - 1.0;
	hfsq = 0.5 * f * f;
	s = f / (2.0 + f);
	z = s * s;
	w = z * z;
	t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
	t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
	R = t2 + t1;
	dk = k;
	return s * (hfsq + R) + dk * ln2_lo - hfsq + f + dk * ln2_hi;
}

/* dwgsim reads names into 1024 bytes */
#define LONGEST_NAME 1000

static char work[64];

static void remove_work(void)
{
	DIR *d;
	struct dirent *e;
	char path[1100];
	if (!work[0] || !(d = opendir(work))) return;
	while ((e = readdir(d)))
		if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) {
			snprintf(path, sizeof path, "%s/%s", work, e->d_name);
			remove(path);
		}
	closedir(d);
	rmdir(work);
}

static void fail(const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	fputs("[dwgsim] ", stderr);
	vfprintf(stderr, format, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

/* A byte as it can be shown in a message */
static const char *shown(int c)
{
	static char s[8];
	if (c >= 33 && c <= 126) snprintf(s, sizeof s, "'%c'", c);
	else snprintf(s, sizeof s, "0x%02X", c);
	return s;
}

static long whole(char flag, const char *value, long low, long high)
{
	char *end;
	long long n;
	errno = 0;
	n = strtoll(value, &end, 10);
	if (!*value || isspace((unsigned char)*value) || *end || errno)
		fail("-%c takes a whole number, not \"%s\"", flag, value);
	if (n < low || n > high) fail("-%c must be from %ld to %ld, not %s", flag, low, high, value);
	return (long)n;
}

static double real(char flag, const char *value, double low, double high)
{
	char *end;
	double x;
	errno = 0;
	x = strtod(value, &end);
	if (!*value || isspace((unsigned char)*value) || *end || errno || !isfinite(x))
		fail("-%c takes a number, not \"%s\"", flag, value);
	if (x < low || x > high) fail("-%c must be from %g to %g, not %s", flag, low, high, value);
	return x;
}

/* -e and -E: a rate, or the rates at the first and last base, as a,b or a-b */
static void error_rates(char flag, const char *value)
{
	char a[64], *sep;
	if (strlen(value) >= sizeof a) fail("-%c takes a rate or two, not \"%s\"", flag, value);
	strcpy(a, value);
	sep = strpbrk(a + 1, ",-");
	if (sep) {
		*sep = 0;
		real(flag, sep + 1, 0, 1);
	}
	real(flag, a, 0, 1);
}

static int is_nucleotide(int c)
{
	return c && strchr("ACGTNRYKMSWBDHVacgtnrykmswbdhv", c) != NULL;
}

/* The reference's sequences, in order: their names and bases */
static char **names;
static char **bases;
static long *lengths;
static size_t n_names, cap_names;
static char *current;
static size_t current_len, current_cap;

static int compare_names(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static void add_name(const char *name, size_t len, long record, long line)
{
	if (!len) fail("sequence %ld of the reference, on line %ld, has no name", record, line);
	if (n_names == cap_names) {
		cap_names = cap_names ? 2 * cap_names : 64;
		names = realloc(names, cap_names * sizeof *names);
		bases = realloc(bases, cap_names * sizeof *bases);
		lengths = realloc(lengths, cap_names * sizeof *lengths);
		if (!names || !bases || !lengths) fail("out of memory");
	}
	if (!(names[n_names] = strdup(name))) fail("out of memory");
	bases[n_names] = NULL, lengths[n_names] = 0;
	n_names++;
}

/* The bases read so far become those of the last name */
static void end_sequence(void)
{
	if (!n_names) return;
	bases[n_names - 1] = current, lengths[n_names - 1] = (long)current_len;
	current = NULL, current_len = current_cap = 0;
}

static void add_base(int c)
{
	if (current_len + 1 >= current_cap) {
		current_cap = current_cap ? 2 * current_cap : 4096;
		if (!(current = realloc(current, current_cap))) fail("out of memory");
	}
	current[current_len++] = (char)toupper(c);
	current[current_len] = 0;
}

static long find_name(const char *name)
{
	size_t k;
	for (k = 0; k < n_names; k++)
		if (!strcmp(names[k], name)) return (long)k;
	return -1;
}

/* Reads the reference, plain or gzipped, as dwgsim would, refuses what it
 * would skip, misread or crash on, and writes it plainly to copy, which
 * dwgsim reads instead: dwgsim reads no gzip. */
static void read_reference(const char *path, FILE *copy)
{
	gzFile in = gzopen(path, "rb");
	static char buf[65536];
	char name[LONGEST_NAME + 1];
	size_t name_len = 0;
	long line = 1, records = 0, letters = 0, usable = 0;
	int n, line_start = 1, in_header = 0, in_name = 0, cr = 0;

	if (!in) fail("cannot open the reference %s (%s)", path, strerror(errno));
	while ((n = gzread(in, buf, sizeof buf)) > 0) {
		int i;
		if (fwrite(buf, 1, n, copy) != (size_t)n) fail("cannot copy the reference");
		for (i = 0; i < n; i++) {
			int c = (unsigned char)buf[i];
			if (!c) fail("the reference holds a NUL byte, on line %ld: it is not FASTA", line);
			if (cr && c != '\n') fail("the reference has a carriage return inside line %ld", line);
			cr = 0;
			if (c == '\r') { cr = 1; continue; }
			if (line_start && c == '>') {
				if (records && !letters) fail("sequence %ld of the reference, %s, has no bases", records, names[n_names - 1]);
				end_sequence();
				records++, letters = 0;
				in_header = in_name = 1, name_len = 0;
				line_start = 0;
				continue;
			}
			line_start = 0;
			if (c == '\n') {
				if (in_name) add_name(name, name_len, records, line);
				in_header = in_name = 0;
				line++, line_start = 1;
				continue;
			}
			if (in_header) {
				if (!in_name) continue;
				/* dwgsim takes the name up to the first space or tab */
				if (c == ' ' || c == '\t') {
					add_name(name, name_len, records, line);
					in_name = 0;
					continue;
				}
				if (name_len == LONGEST_NAME) fail("the name of sequence %ld of the reference is longer than %d characters", records, LONGEST_NAME);
				name[name_len++] = (char)c;
				name[name_len] = 0;
				continue;
			}
			if (!records) fail("the reference is not FASTA: it starts with %s, not '>'", shown(c));
			if (is_nucleotide(c)) {
				letters++;
				add_base(c);
				if (strchr("ACGTacgt", c)) usable++;
			} else if (c != ' ' && c != '\t') {
				fail("sequence %ld of the reference, %s, has %s, which is not a base, on line %ld", records, names[n_names - 1], shown(c), line);
			}
		}
	}
	{
		int error;
		const char *message = gzerror(in, &error);
		if (n < 0 || (error != Z_OK && error != Z_STREAM_END)) fail("cannot read the reference: %s", message);
	}
	gzclose(in);
	if (cr) fail("the reference ends in a carriage return");
	if (in_name) add_name(name, name_len, records, line);
	if (!records) fail("the reference holds no sequences");
	if (!letters) fail("sequence %ld of the reference, %s, has no bases", records, names[n_names - 1]);
	end_sequence();
	if (!usable) fail("the reference has no A, C, G or T to simulate reads from");
	{
		char **sorted = malloc(n_names * sizeof *sorted);
		size_t k;
		if (!sorted) fail("out of memory");
		memcpy(sorted, names, n_names * sizeof *sorted);
		qsort(sorted, n_names, sizeof *sorted, compare_names);
		for (k = 1; k < n_names; k++)
			if (!strcmp(sorted[k - 1], sorted[k])) fail("the reference has two sequences named %s", sorted[k]);
		free(sorted);
	}
}

/* The lines of a file given to -v or -x, as dwgsim splits them: at a
 * newline or a carriage return, with the fields split at whitespace */
static char *slurp(char flag, const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	char *data = NULL;
	size_t cap = 0, n;
	*len = 0;
	if (!f) fail("cannot open %s, given to -%c (%s)", path, flag, strerror(errno));
	do {
		if (*len + 65536 + 1 > cap) {
			cap = 2 * cap + 65536 + 1;
			if (!(data = realloc(data, cap))) fail("out of memory");
		}
		n = fread(data + *len, 1, 65536, f);
		*len += n;
	} while (n);
	if (ferror(f)) fail("cannot read %s, given to -%c", path, flag);
	fclose(f);
	data[*len] = 0;
	if (strlen(data) != *len) fail("%s, given to -%c, holds a NUL byte: it is not text", path, flag);
	return data;
}

#define MAX_FIELDS 6
static int split_fields(char *line, char **fields)
{
	int n = 0;
	char *p = line;
	while (*p && n < MAX_FIELDS) {
		while (*p && isspace((unsigned char)*p)) p++;
		if (!*p) break;
		fields[n++] = p;
		while (*p && !isspace((unsigned char)*p)) p++;
		if (*p) *p++ = 0;
	}
	return n;
}

static long position(char flag, const char *what, const char *value, long line)
{
	char *end;
	long long n;
	errno = 0;
	n = strtoll(value, &end, 10);
	if (!isdigit((unsigned char)*value) || *end || errno || n > INT32_MAX)
		fail("line %ld of the file given to -%c has %s \"%s\", not a position", line, flag, what, value);
	return (long)n;
}

static int all_bases(const char *s)
{
	return strspn(s, "ACGTacgt") == strlen(s);
}

/* The candidate mutations (-v): VCF records sorted along the reference, each
 * with one ALT of A, C, G and T (or . for none), a REF that is the
 * reference's bases there, and no two over the same bases. dwgsim checks
 * little of this, and asserts, crashes or writes outside a sequence when it
 * does not hold. */
static void check_vcf(const char *path)
{
	size_t len;
	char *data = slurp('v', path, &len), *p = data, *fields[MAX_FIELDS];
	long line = 0, contig = 0, last_end = 0, records = 0;
	while (p < data + len) {
		char *eol = p + strcspn(p, "\r\n");
		int n;
		long k, pos, ref_l, alt_l, j;
		const char *ref, *alt;
		line++;
		if (*eol) *eol = 0, eol++;
		else eol = data + len;
		if (!*p || *p == '#') { p = eol; continue; }
		n = split_fields(p, fields);
		p = eol;
		if (!n) continue;
		if (n < 5) fail("line %ld of the VCF given to -v has %d fields, not the 5 of CHROM, POS, ID, REF and ALT", line, n);
		k = find_name(fields[0]);
		if (k < 0) fail("line %ld of the VCF given to -v is on %s, which is not in the reference", line, fields[0]);
		if (k < contig) fail("line %ld of the VCF given to -v is on %s, before the sequence of the line above it in the reference: the VCF must be sorted as the reference", line, fields[0]);
		if (k > contig) contig = k, last_end = 0;
		pos = position('v', "POS", fields[1], line);
		ref = strcmp(fields[3], ".") ? fields[3] : "";
		alt = strcmp(fields[4], ".") ? fields[4] : "";
		ref_l = (long)strlen(ref), alt_l = (long)strlen(alt);
		if (!ref_l && !alt_l) fail("line %ld of the VCF given to -v has neither REF nor ALT", line);
		if (strchr(alt, ',')) fail("line %ld of the VCF given to -v has more than one ALT, which dwgsim cannot simulate", line);
		if (!all_bases(ref) || !all_bases(alt)) fail("line %ld of the VCF given to -v has a REF or ALT that is not of A, C, G and T", line);
		if (ref_l > 1023 || alt_l > 1024) fail("line %ld of the VCF given to -v has a REF or ALT longer than dwgsim reads", line);
		if (pos < 1 || pos > lengths[k]) fail("line %ld of the VCF given to -v is at %s:%ld, outside the sequence", line, fields[0], pos);
		if (pos - 1 + ref_l > lengths[k]) fail("line %ld of the VCF given to -v has a REF that runs past the end of %s", line, fields[0]);
		for (j = 0; j < ref_l; j++)
			if (toupper((unsigned char)ref[j]) != bases[k][pos - 1 + j])
				fail("line %ld of the VCF given to -v has REF %s, but the reference has %.*s at %s:%ld", line, ref, (int)ref_l, bases[k] + pos - 1, fields[0], pos);
		if (pos <= last_end) fail("line %ld of the VCF given to -v is at %s:%ld, over the bases of the record above it", line, fields[0], pos);
		if (ref_l == alt_l) {
			for (j = 0; j < ref_l; j++)
				if (toupper((unsigned char)alt[j]) == bases[k][pos - 1 + j])
					fail("line %ld of the VCF given to -v has ALT %s, which leaves the base at %s:%ld as it is", line, alt, fields[0], pos + j);
		} else {
			/* dwgsim skips the bases REF and ALT start with */
			for (j = 0; j < ref_l && j < alt_l && toupper((unsigned char)ref[j]) == toupper((unsigned char)alt[j]); j++);
			if (ref_l < alt_l && pos + j > lengths[k]) fail("line %ld of the VCF given to -v inserts after the end of %s", line, fields[0]);
			if (ref_l > alt_l && j == ref_l) fail("line %ld of the VCF given to -v deletes no bases", line);
		}
		last_end = pos - 1 + (ref_l ? ref_l : 1);
		records++;
	}
	free(data);
	(void)records;
}

/* The regions (-x): BED lines of a sequence of the reference, a start and an
 * end within it, sorted along the reference */
static void check_bed(const char *path)
{
	size_t len;
	char *data = slurp('x', path, &len), *p = data, *fields[MAX_FIELDS];
	long line = 0, contig = 0, last_start = -1, regions = 0;
	while (p < data + len) {
		char *eol = p + strcspn(p, "\r\n");
		int n;
		long k, start, end;
		line++;
		if (*eol) *eol = 0, eol++;
		else eol = data + len;
		n = split_fields(p, fields);
		p = eol;
		if (!n) continue;
		if (n < 3) fail("line %ld of the BED given to -x has %d fields, not the 3 of a sequence, a start and an end", line, n);
		k = find_name(fields[0]);
		if (k < 0) fail("line %ld of the BED given to -x is on %s, which is not in the reference", line, fields[0]);
		if (k < contig) fail("line %ld of the BED given to -x is on %s, before the sequence of the line above it in the reference: the BED must be sorted as the reference", line, fields[0]);
		if (k > contig) contig = k, last_start = -1;
		start = position('x', "start", fields[1], line);
		end = position('x', "end", fields[2], line);
		if (end > lengths[k]) fail("line %ld of the BED given to -x ends at %ld, past the end of %s (%ld)", line, end, fields[0], lengths[k]);
		if (end < start) fail("line %ld of the BED given to -x ends before it starts", line);
		if (start < last_start) fail("line %ld of the BED given to -x starts before the line above it: the BED must be sorted", line);
		last_start = start;
		regions++;
	}
	free(data);
	if (!regions) fail("the BED given to -x holds no regions");
}

/* The build makes dwgsim call these as it looks for a place for a read pair,
 * and when it has found one: dwgsim would look for ever when none fits */
#define MOST_TRIES 10000000L
static long tries;

void biochef_try(void)
{
	if (++tries > MOST_TRIES)
		fail("dwgsim found no place for a read pair in %ld tries: no place in the sequence%s fits a fragment of about -d bases (-s) holding reads of -1 and -2 bases", MOST_TRIES, "s (or their regions, -x)");
}

void biochef_placed(void)
{
	tries = 0;
}

/* And this as Ion Torrent errors lengthen a read: at high error rates every
 * empty flow adds bases that add empty flows, and a read grows for ever */
static long longest_read = 70;

void biochef_grown(int len)
{
	if (len > 64 * longest_read + 1024)
		fail("the Ion Torrent error rates (-e and -E) are so high that a read grows without end: lower them");
}

static void move(const char *from, const char *to)
{
	if (rename(from, to)) fail("cannot move %s to %s (%s)", from, to, strerror(errno));
}

static long size_of(const char *path)
{
	struct stat st;
	return stat(path, &st) ? -1 : (long)st.st_size;
}

int main(int argc, char *argv[])
{
	const char *read1 = NULL, *read2 = NULL, *vcf = NULL, *reference = NULL;
	const char *seen[128] = { 0 }, *value[128] = { 0 };
	char **args, path[128], prefix[96];
	int i, n = 0, amplicons = 0;

	args = calloc((size_t)argc + 8, sizeof *args);
	if (!args) fail("out of memory");
	args[n++] = argv[0];
	for (i = 1; i < argc; i++) {
		const char *a = argv[i], *v;
		char f;
		if (!strcmp(a, "--bc-read1") || !strcmp(a, "--bc-read2") || !strcmp(a, "--bc-vcf") || !strcmp(a, "--bc-amplicons")) {
			const char **slot = a[5] == 'r' ? (a[9] == '1' ? &read1 : &read2) : a[5] == 'v' ? &vcf : NULL;
			if (i + 1 >= argc || !*argv[i + 1]) fail("%s needs a value", a);
			v = argv[++i];
			if (!slot) {
				if (amplicons) fail("%s is given twice", a);
				amplicons = (int)whole('a', v, 0, 1) + 1;
				continue;
			}
			if (*slot) fail("%s is given twice", a);
			*slot = v;
			continue;
		}
		if (a[0] != '-' || !a[1]) {
			if (reference) fail("unexpected argument \"%s\": the reference is %s", a, reference);
			reference = a;
			continue;
		}
		if (a[2]) fail("unknown option %s", a);
		f = a[1];
		if (f == 'M' || f == 'o') fail("-%c is set by the outputs asked for", f);
		if (!strchr("iBHadsNC12eErFRXIcSAnyfzvxPqQ", f)) fail("unknown option -%c", f);
		if (seen[(unsigned char)f]) fail("-%c is given twice", f);
		seen[(unsigned char)f] = a;
		args[n++] = (char *)a;
		if (strchr("iBHa", f)) continue;
		if (i + 1 >= argc) fail("-%c needs a value", f);
		v = argv[++i];
		args[n++] = (char *)v;
		value[(unsigned char)f] = v;
		switch (f) {
		/* so that the fragment and reads stay within an int */
		case 'd': whole(f, v, 0, 1L << 28); break;
		case 's': real(f, v, 0, 1 << 24); break;
		case 'N': whole(f, v, -1, INT32_MAX); break;
		case 'C': real(f, v, -1, INT32_MAX); break;
		case '1': whole(f, v, 1, 1L << 28); break;
		case '2': whole(f, v, 0, 1L << 28); break;
		case 'e': case 'E': error_rates(f, v); break;
		case 'r': case 'F': case 'R': case 'y': real(f, v, 0, 1); break;
		/* an indel extended with probability 1 never ends */
		case 'X': if (real(f, v, 0, 1) >= 1) fail("-X must be below 1, or every indel goes on for ever"); break;
		/* dwgsim grows every indel to at least -I bases */
		case 'I': whole(f, v, 1, 10000); break;
		case 'c': case 'S': case 'A': whole(f, v, 0, 2); break;
		case 'n': whole(f, v, 0, INT32_MAX); break;
		case 'z': whole(f, v, -1, INT32_MAX); break;
		case 'Q': real(f, v, 0, INT32_MAX); break;
		case 'f':
			/* dwgsim skips flows until the base it reads, for ever for a
			 * base the order lacks */
			if (!*v || strspn(v, "ACGTacgt") != strlen(v) || !strpbrk(v, "Aa") || !strpbrk(v, "Cc") || !strpbrk(v, "Gg") || !strpbrk(v, "Tt"))
				fail("-f takes a flow order of A, C, G and T, with each of them, not \"%s\"", v);
			break;
		case 'P': {
			const char *p;
			if (!*v) fail("-P takes a prefix for the read names, not an empty one");
			for (p = v; *p; p++)
				if (*p < 33 || *p > 126) fail("-P takes a prefix for the read names, without %s", shown((unsigned char)*p));
			break;
		}
		case 'q':
			if (strlen(v) != 1 || v[0] < 33 || v[0] > 126) fail("-q takes one quality character, from '!' to '~', not \"%s\"", v);
			break;
		}
	}
	/* Ion Torrent errors repeat while a draw is below the rate: at 1, for
	 * ever. dwgsim marks the flows in an array as long as a read. */
	if (value['c'] && !strcmp(value['c'], "2")) {
		long l1 = value['1'] ? atol(value['1']) : 70, l2 = value['2'] ? atol(value['2']) : 70;
		long shortest = l2 && l2 < l1 ? l2 : l1;
		if (value['f'] && (long)strlen(value['f']) > shortest)
			fail("-f, the flow order, cannot be longer than the reads (-1 and -2) for Ion Torrent data (-c 2)");
		const char *e[2] = { value['e'], value['E'] };
		int k;
		for (k = 0; k < 2; k++)
			if (e[k] && (atof(e[k]) >= 1 || (strpbrk(e[k] + 1, ",-") && atof(strpbrk(e[k] + 1, ",-") + 1) >= 1)))
				fail("-%c must be below 1 for Ion Torrent data (-c 2)", k ? 'E' : 'e');
	}
	if (seen['N'] && seen['C']) fail("-N and -C cannot both be given: -N sets the number of pairs, -C the coverage");
	if (amplicons == 2) {
		if (seen['a']) fail("-a is given twice");
		args[n++] = "-a";
	}
	{
		long l1 = value['1'] ? atol(value['1']) : 70, l2 = value['2'] ? atol(value['2']) : 70;
		longest_read = l1 > l2 ? l1 : l2;
	}
	if (!reference) fail("the reference is needed");
	if (!read1 && !read2 && !vcf) fail("no output is asked for: --bc-read1, --bc-read2 or --bc-vcf");
	if (read2 && value['2'] && !strcmp(value['2'], "0")) fail("there are no second reads to write: -2 is 0");

	/* dwgsim always simulates both the mutations and the reads, one read
	 * end per file, so that a seed gives the same of each whichever outputs
	 * are asked for. (With -M 1, dwgsim writes the header of a mutations
	 * file it has not opened, and crashes.) */
	args[n++] = "-M", args[n++] = "0";
	args[n++] = "-o", args[n++] = "1";

	strcpy(work, "biochef-dwgsim-XXXXXX");
	if (!mkdtemp(work)) { work[0] = 0; fail("cannot make a directory to work in (%s)", strerror(errno)); }
	atexit(remove_work);
	snprintf(path, sizeof path, "%s/reference.fa", work);
	{
		FILE *copy = fopen(path, "wb");
		if (!copy) fail("cannot copy the reference (%s)", strerror(errno));
		read_reference(reference, copy);
		if (fclose(copy)) fail("cannot copy the reference");
	}
	if (value['v']) check_vcf(value['v']);
	if (value['x']) check_bed(value['x']);
	snprintf(prefix, sizeof prefix, "%s/out", work);
	args[n++] = path;
	args[n++] = prefix;
	args[n] = NULL;

	optind = 1;
	i = biochef_upstream_main(n, args);
	fflush(stdout);
	if (i) return i;

	if (read1 || read2) {
		snprintf(path, sizeof path, "%s.bwa.read1.fastq.gz", prefix);
		if (size_of(path) <= 0) fail("dwgsim simulated no reads: it skipped every sequence, as it says above");
		if (read1) move(path, read1);
		snprintf(path, sizeof path, "%s.bwa.read2.fastq.gz", prefix);
		if (read2) move(path, read2);
	}
	if (vcf) {
		snprintf(path, sizeof path, "%s.mutations.vcf", prefix);
		move(path, vcf);
	}
	return 0;
}
SHIM_EOF
sed -i 's/^int main(int argc, char \*argv\[\])$/int biochef_upstream_main(int argc, char *argv[])/' src/dwgsim.c
grep -q '^int biochef_upstream_main(int argc, char \*argv\[\])$' src/dwgsim.c
# The reads are written plain, not gzipped, for BioChef to read as FASTQ.
sed -i 's/gzopen(fn_tmp, "w")/gzopen(fn_tmp, "wT")/' src/dwgsim.c
[ "$(grep -c 'gzopen(fn_tmp, "wT")' src/dwgsim.c)" -eq 3 ]
# log is the entry point's, and the numbers of pairs are counted in double,
# not long double, which is 80 bits natively and 128 in wasm: so a seed
# gives the same reads natively and in wasm. No step is fused into an FMA.
sed -i -E 's/\blog\(/biochef_log(/g; s/\(long double\)/(double)/g' src/dwgsim.c
[ "$(grep -o 'biochef_log(' src/dwgsim.c | wc -l)" -eq 5 ]
! grep -Eq '\blog\(|long double' src/*.c
# The VCF of candidate mutations (-v) is read through 1 MB on the stack, more
# than wasm's stack holds, and scanned as a string that may not end inside it.
sed -i 's/^  char buffer\[BUFFER_L\];$/  static char buffer[BUFFER_L + 1];/' src/mut_vcf.c
grep -q '^  static char buffer\[BUFFER_L + 1\];$' src/mut_vcf.c
# dwgsim reads the base before a region that starts at 0 (BED is half-open
# and 0-based): it counts the region's bases from start + 1 to end instead.
sed -i 's/^\( *\)for(m=regions_bed->start\[i\];m<=regions_bed->end\[i\];m++) {/\1for(m=regions_bed->start[i]+1;m<=regions_bed->end[i];m++) {/' src/dwgsim.c
grep -q 'for(m=regions_bed->start\[i\]+1;m<=regions_bed->end\[i\];m++) {' src/dwgsim.c
# dwgsim looks for a place for each read pair until one fits, for ever when
# none does: the entry point counts the tries and gives up.
sed -i 's|do { // avoid boundary failure|do { biochef_try(); // avoid boundary failure|; s|^\( *\)// generate the read sequences$|\1biochef_placed(); // generate the read sequences|' src/dwgsim.c
[ "$(grep -c 'biochef_try();' src/dwgsim.c)" -eq 2 ] && [ "$(grep -c 'biochef_placed();' src/dwgsim.c)" -eq 1 ]
# The lengths of long insertions are stored at odd addresses through
# uint16_t and uint32_t pointers; they are copied byte by byte instead.
sed -i -e 's/^\( *\)(\*n) = (uint32_t)(((uint16_t\*)(ins+1))\[0\]);$/\1{ uint16_t v; memcpy(\&v, ins+1, sizeof v); (*n) = v; }/' \
  -e 's/^\( *\)(\*n) = (uint32_t)(((uint32_t\*)(ins+1))\[0\]);$/\1memcpy(n, ins+1, sizeof *n);/' \
  -e 's/^\( *\)(\*((uint16_t\*)(ins+1))) = (uint16_t)n;$/\1{ uint16_t v = (uint16_t)n; memcpy(ins+1, \&v, sizeof v); }/' \
  -e 's/^\( *\)(\*((uint32_t\*)(ins+1))) = n;$/\1memcpy(ins+1, \&n, sizeof n);/' src/mut.c
! grep -Eq '\(uint(16|32)_t ?\*\)' src/mut.c
[ "$(grep -c 'memcpy(' src/mut.c)" -ge 4 ]
sed -i 's/^\( *\)len += n_err;$/\1len += n_err; biochef_grown(len);/' src/dwgsim.c
[ "$(grep -c 'biochef_grown(len);' src/dwgsim.c)" -eq 2 ]
FLAGS="-O2 -ffp-contract=off"
DFLAGS='-D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE -DPACKAGE_VERSION=\"0.1.17\" -include biochef_dwgsim.h'
printf 'double biochef_log(double x);\nvoid biochef_try(void);\nvoid biochef_placed(void);\nvoid biochef_grown(int len);\n' > biochef_dwgsim.h
OBJS="src/dwgsim_opt.o src/mut.o src/contigs.o src/regions_bed.o src/mut_txt.o src/mut_bed.o src/mut_vcf.o src/mut_input.o src/dwgsim.o"

emmake make CC=emcc CFLAGS="$FLAGS -Wall -sUSE_ZLIB=1" DFLAGS="$DFLAGS" INCLUDES="-I. -Isrc" $OBJS
emcc $FLAGS -Wall -sUSE_ZLIB=1 -c biochef_main.c -o biochef_main.o
emcc $FLAGS -o dwgsim.js biochef_main.o $OBJS -lm $EM_FLAGS

mkdir -p out && mv dwgsim.js dwgsim.wasm out/
