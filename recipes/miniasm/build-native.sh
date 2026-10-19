set -eo pipefail

# miniasm skips PAF lines it cannot read, keeps the first length given for a
# read, and fills with N the bases of reads missing from -f; minidot writes
# an empty plot of no defined height when no alignment passes its filters.
# This entry point, linked in front of both mains, reads the overlaps and the
# reads first and refuses those, and checks the option values, which both
# read with atoi and atof. The same entry point is in build-wasm.sh.
cat > biochef_main.c <<'SHIM_EOF'

// The entry point of miniasm and minidot: it reads the overlaps, and for
// miniasm the reads, before the tool does and refuses what the tool would
// skip, misread or fill with N without a word, and it refuses option values
// the tool would read as 0 or ignore.
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "khash.h"

#ifdef BIOCHEF_MINIDOT
#define BIOCHEF_TOOL "minidot"
#else
#define BIOCHEF_TOOL "miniasm"
#endif

KHASH_MAP_INIT_STR(biochef_len, uint32_t)

int biochef_upstream_main(int argc, char *argv[]);

static void biochef_fail(const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	fputs("[" BIOCHEF_TOOL "] ", stderr);
	vfprintf(stderr, format, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

typedef struct {
	gzFile f;
	const char *path;
	unsigned char buf[1 << 16];
	int n, at, eof;
	char *line;
	size_t cap;
} biochef_reader_t;

// Reads a whole line of any length, without its line ending; returns -1 at
// the end of the file
static long biochef_getline(biochef_reader_t *r)
{
	size_t n = 0;
	int any = 0;
	for (;;) {
		if (r->at == r->n) {
			if (r->eof) break;
			r->n = gzread(r->f, r->buf, sizeof r->buf), r->at = 0;
			if (r->n < 0) {
				int err;
				biochef_fail("cannot read %s (%s)", r->path, gzerror(r->f, &err));
			}
			if (r->n == 0) {
				r->eof = 1;
				break;
			}
		}
		any = 1;
		unsigned char c = r->buf[r->at++];
		if (c == '\n') break;
		if (!c) biochef_fail("%s holds a NUL byte", r->path);
		if (n + 2 > r->cap) r->cap = r->cap ? r->cap << 1 : 1 << 16, r->line = (char*)realloc(r->line, r->cap);
		r->line[n++] = (char)c;
	}
	if (!any) return -1;
	if (!r->cap) r->cap = 1 << 16, r->line = (char*)malloc(r->cap);
	if (n && r->line[n - 1] == '\r') n--;
	r->line[n] = 0;
	return (long)n;
}

static void biochef_open(biochef_reader_t *r, const char *path, const char *what)
{
	if (!strcmp(path, "-")) biochef_fail("reads the %s from a file, not from standard input", what);
	memset(r, 0, sizeof *r);
	r->path = path;
	r->f = gzopen(path, "r");
	if (!r->f) biochef_fail("cannot open the %s %s (%s)", what, path, strerror(errno));
}

static void biochef_close(biochef_reader_t *r)
{
	gzclose(r->f);
	free(r->line);
}

// A whole number from 0 to max
static long biochef_whole(const char *opt, const char *s, long min, long max)
{
	char *end;
	errno = 0;
	long v = strtol(s, &end, 10);
	if (!*s || *end || errno || v < min || v > max || isspace((unsigned char)*s))
		biochef_fail("%s should be a whole number from %ld to %ld, and is \"%s\"", opt, min, max, s);
	return v;
}

static double biochef_number(const char *opt, const char *s, double min, double max, char **rest)
{
	char *end;
	errno = 0;
	double v = strtod(s, &end);
	if (end == s || errno || !(v >= min && v <= max) || isspace((unsigned char)*s) || (!rest && *end))
		biochef_fail("%s should be a number from %g to %g, and is \"%s\"", opt, min, max, s);
	if (rest) *rest = end;
	return v;
}

static int biochef_field_number(const char *s, uint32_t max, uint32_t *v)
{
	if (!*s) return 0;
	uint64_t x = 0;
	for (; *s; s++) {
		if (*s < '0' || *s > '9') return 0;
		x = x * 10 + (uint64_t)(*s - '0');
		if (x > max) return 0;
	}
	*v = (uint32_t)x;
	return 1;
}

static void biochef_name_length(khash_t(biochef_len) *h, const char *path, long line, const char *name, uint32_t len)
{
	int absent;
	khint_t k = kh_put(biochef_len, h, name, &absent);
	if (absent) {
		kh_key(h, k) = strdup(name);
		kh_val(h, k) = len;
	} else if (kh_val(h, k) != len) {
		biochef_fail("line %ld of the overlaps %s gives read %s %u bases, and an earlier line %u", line, path, name, len, kh_val(h, k));
	}
}

// Reads a PAF file as the tool does, refusing the lines it would skip and
// the coordinates it would misread; returns the length of every read named
static khash_t(biochef_len) *biochef_check_paf(const char *path)
{
	static const char *const column[] = { "query name", "query length", "query start", "query end", "strand",
		"target name", "target length", "target start", "target end", "number of matching bases",
		"alignment block length", "mapping quality" };
	khash_t(biochef_len) *names = kh_init(biochef_len);
	static biochef_reader_t f;
	long number = 0, records = 0, n;
	biochef_open(&f, path, "overlaps");
	while ((n = biochef_getline(&f)) >= 0) {
		char *field[12], *p = f.line;
		uint32_t v[12];
		int i;
		number++;
		if (!n) continue;
		for (i = 0; i < 12; i++) {
			field[i] = p;
			p = strchr(p, '\t');
			if (!p) {
				if (i < 11) biochef_fail("line %ld of the overlaps %s has %d tab-separated columns, and PAF has 12 or more", number, path, i + 1);
				break;
			}
			*p++ = 0;
		}
		for (i = 0; i < 12; i++) {
			if (i == 0 || i == 5) {
				const char *c;
				if (!*field[i]) biochef_fail("line %ld of the overlaps %s has no %s", number, path, column[i]);
				for (c = field[i]; *c; c++)
					if (isspace((unsigned char)*c) || iscntrl((unsigned char)*c))
						biochef_fail("line %ld of the overlaps %s has a space or control character in the %s \"%s\"", number, path, column[i], field[i]);
			} else if (i == 4) {
				if (strcmp(field[i], "+") && strcmp(field[i], "-"))
					biochef_fail("line %ld of the overlaps %s has the strand \"%s\", where PAF has + or -", number, path, field[i]);
			} else if (!biochef_field_number(field[i], i == 11 ? 255 : i == 9 ? INT32_MAX : INT32_MAX, &v[i])) {
				biochef_fail("line %ld of the overlaps %s has the %s \"%s\", where PAF has a whole number from 0 to %d", number, path, column[i], field[i], i == 11 ? 255 : INT32_MAX);
			}
		}
		if (!v[1] || !v[6]) biochef_fail("line %ld of the overlaps %s gives a read 0 bases", number, path);
		if (v[2] > v[3] || v[3] > v[1])
			biochef_fail("line %ld of the overlaps %s has the query from %u to %u in a read of %u bases", number, path, v[2], v[3], v[1]);
		if (v[7] > v[8] || v[8] > v[6])
			biochef_fail("line %ld of the overlaps %s has the target from %u to %u in a read of %u bases", number, path, v[7], v[8], v[6]);
		if (v[9] > v[10])
			biochef_fail("line %ld of the overlaps %s has %u matching bases in an alignment of %u", number, path, v[9], v[10]);
		biochef_name_length(names, path, number, field[0], v[1]);
		biochef_name_length(names, path, number, field[5], v[6]);
		records++;
	}
	biochef_close(&f);
	if (!records) biochef_fail("the overlaps %s hold no overlap", path);
	return names;
}

#ifndef BIOCHEF_MINIDOT
// Reads FASTA or FASTQ as kseq does, and refuses what it would read into the
// assembly without a word; checks each read the overlaps name is there, as
// long as they say
static void biochef_check_reads(const char *path, khash_t(biochef_len) *overlaps)
{
	khash_t(biochef_len) *reads = kh_init(biochef_len);
	static biochef_reader_t f;
	char *buf, *name = NULL;
	long number = 0, n, start = 0;
	uint64_t len = 0;
	int fastq = 0, state = 0; // 0: before a record, 1: bases, 2: qualities
	uint64_t qual = 0;
	khint_t k;
	biochef_open(&f, path, "reads");
	for (;;) {
		n = biochef_getline(&f);
		buf = f.line;
		if (n >= 0) number++;
		int header = n > 0 && ((state != 2 && (buf[0] == '>' || buf[0] == '@')) || (state == 2 && qual >= len && (buf[0] == '>' || buf[0] == '@')));
		if (n < 0 || header) {
			if (name) {
				if (!len) biochef_fail("read %s, line %ld of the reads %s, has no bases", name, start, path);
				if (fastq && (state != 2 || qual != len))
					biochef_fail("read %s, line %ld of the reads %s, has %llu bases and %llu qualities", name, start, path, (unsigned long long)len, (unsigned long long)qual);
				if (len > INT32_MAX) biochef_fail("read %s of the reads %s is longer than %d bases", name, path, INT32_MAX);
				int absent;
				k = kh_put(biochef_len, reads, name, &absent);
				if (!absent) biochef_fail("the reads %s have two reads named %s", path, name);
				kh_val(reads, k) = (uint32_t)len;
				name = NULL;
			}
			if (n < 0) break;
			fastq = buf[0] == '@';
			size_t e = strcspn(buf + 1, " \t\v\f");
			if (!e) biochef_fail("line %ld of the reads %s starts a read with no name", number, path);
			name = strndup(buf + 1, e);
			start = number, len = qual = 0, state = 1;
			continue;
		}
		if (!n && state != 2) continue;
		if (!state) biochef_fail("the reads %s are neither FASTA nor FASTQ: line %ld starts with neither > nor @", path, number);
		if (state == 1 && fastq && buf[0] == '+') {
			state = 2;
			continue;
		}
		if (state == 2) {
			long i;
			for (i = 0; i < n; i++)
				if (buf[i] < 33 || buf[i] > 126)
					biochef_fail("line %ld of the reads %s has 0x%02X in the qualities of read %s", number, path, (unsigned char)buf[i], name);
			qual += (uint64_t)n;
			if (qual > len) biochef_fail("read %s, line %ld of the reads %s, has %llu bases and more qualities", name, start, path, (unsigned long long)len);
			continue;
		}
		long i;
		for (i = 0; i < n; i++) {
			unsigned char c = (unsigned char)buf[i];
			if (!isalpha(c) || c > 127) {
				if (c >= 33 && c <= 126) biochef_fail("line %ld of the reads %s has '%c' in read %s", number, path, c, name);
				biochef_fail("line %ld of the reads %s has 0x%02X in read %s", number, path, c, name);
			}
		}
		len += (uint64_t)n;
	}
	biochef_close(&f);
	if (!kh_size(reads)) biochef_fail("the reads %s hold no read", path);
	for (k = kh_begin(overlaps); k != kh_end(overlaps); ++k) {
		if (!kh_exist(overlaps, k)) continue;
		khint_t r = kh_get(biochef_len, reads, kh_key(overlaps, k));
		if (r == kh_end(reads)) biochef_fail("read %s of the overlaps is not in the reads %s", kh_key(overlaps, k), path);
		if (kh_val(reads, r) != kh_val(overlaps, k))
			biochef_fail("read %s has %u bases in the reads %s, and %u in the overlaps", kh_key(overlaps, k), kh_val(reads, r), path, kh_val(overlaps, k));
	}
}
#endif

int main(int argc, char *argv[])
{
#ifdef BIOCHEF_MINIDOT
	const char *flags = "Ld", *values = "miswft";
#else
	const char *flags = "12VBRb", *values = "nmscidgohIrfepF";
	const char *reads = NULL, *format = "ug";
	int no_first = 0, no_second = 0;
#endif
	const char *overlaps = NULL;
	// The options go before the PAF file: glibc's getopt reads options after
	// it too, and musl's, in wasm, stops at it
	char **args = (char**)calloc((size_t)argc + 1, sizeof(char*));
	int i, n = 0;
	args[n++] = argv[0];
	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (a[0] != '-' || !a[1]) {
			if (overlaps) biochef_fail("takes one PAF file of overlaps, and was given \"%s\" and \"%s\"", overlaps, a);
			overlaps = a;
			continue;
		}
		if (!strcmp(a, "--")) biochef_fail("does not take --");
		args[n++] = argv[i];
		for (const char *c = a + 1; *c; c++) {
#ifndef BIOCHEF_MINIDOT
			if (*c == '1') no_first = 1;
			if (*c == '2') no_second = 1;
#endif
			if (strchr(flags, *c)) continue;
			if (!strchr(values, *c)) biochef_fail("has no option -%c", *c);
			char opt[3] = { '-', *c, 0 };
			const char *v = c[1] ? c + 1 : (i + 1 < argc ? argv[++i] : NULL);
			if (!v) biochef_fail("%s needs a value", opt);
			if (!c[1]) args[n++] = argv[i];
			switch (*c) {
#ifdef BIOCHEF_MINIDOT
			case 'm': case 's': biochef_whole(opt, v, 0, INT32_MAX); break;
			case 'w': biochef_whole(opt, v, 1, 100000); break;
			case 'f': biochef_whole(opt, v, 1, 1000); break;
			case 'i': biochef_number(opt, v, 0, 1, NULL); break;
			case 't': biochef_number(opt, v, 0, 100, NULL); break;
#else
			case 'm': case 's': case 'o': case 'h': case 'd': case 'g': case 'e':
				biochef_whole(opt, v, 0, INT32_MAX); break;
			case 'c': biochef_whole(opt, v, 1, INT32_MAX); break;
			case 'n': biochef_whole(opt, v, 0, 1000); break;
			case 'i': case 'I': case 'F': biochef_number(opt, v, 0, 1, NULL); break;
			case 'r': {
				char *rest;
				biochef_number(opt, v, 0, 1, &rest);
				if (*rest == ',') biochef_number(opt, rest + 1, 0, 1, NULL);
				else if (*rest) biochef_fail("-r should be one or two numbers from 0 to 1, as 0.7 or 0.7,0.5, and is \"%s\"", v);
				break;
			}
			case 'p':
				if (strcmp(v, "ug") && strcmp(v, "sg") && strcmp(v, "bed") && strcmp(v, "paf"))
					biochef_fail("-p should be ug, sg, bed or paf, and is \"%s\"", v);
				format = v;
				break;
			case 'f': reads = v; break;
#endif
			}
			break;
		}
	}
	if (!overlaps) biochef_fail("needs a PAF file of overlaps");
	khash_t(biochef_len) *names = biochef_check_paf(overlaps);
#ifndef BIOCHEF_MINIDOT
	// -p bed and paf print the regions of the reads the selection kept,
	// which there are none of when -1 and -2 skip both passes
	if (no_first && no_second && (!strcmp(format, "bed") || !strcmp(format, "paf")))
		biochef_fail("-p %s prints the parts of the reads the selection keeps, and -1 and -2 together skip the selection", format);
	if (reads && strcmp(format, "ug")) biochef_fail("reads only go into unitigs, -p ug; -p %s does not use -f", format);
	if (reads) {
		if (!strcmp(reads, "-")) biochef_fail("reads the reads from a file, not from standard input");
		biochef_check_reads(reads, names);
	}
#endif
	(void)names;
	args[n++] = (char*)overlaps;
	args[n] = NULL;
	return biochef_upstream_main(n, args);
}
SHIM_EOF
sed -i 's/^int main(int argc, char \*argv\[\])$/int biochef_upstream_main(int argc, char *argv[])/' main.c dotter.c
[ "$(cat main.c dotter.c | grep -c '^int biochef_upstream_main(int argc, char \*argv\[\])$')" -eq 2 ]
sed -i -e 's|^miniasm:$(OBJS) main.o$|& biochef_main.o|' -e 's|^minidot:paf.o sdict.o dotter.o$|& biochef_minidot.o|' Makefile
printf '\nbiochef_minidot.o:biochef_main.c\n\t$''(CC) -c $''(CFLAGS) $''(CPPFLAGS) $''(INCLUDES) -DBIOCHEF_MINIDOT $< -o $@\n' >> Makefile
grep -q '^miniasm:$(OBJS) main.o biochef_main.o$' Makefile
grep -q '^minidot:paf.o sdict.o dotter.o biochef_minidot.o$' Makefile

# With -n 1, the drop ratio of the one round divided by 0 rounds, and the
# NaN it gave was converted to an integer. One round now takes the lower
# ratio, as the first of several does.
sed -i 's|^\(\t*\)float r = opt.min_ovlp_drop_ratio + (opt.max_ovlp_drop_ratio - opt.min_ovlp_drop_ratio) / opt.n_rounds \* i;$|\1float r = opt.n_rounds > 0? opt.min_ovlp_drop_ratio + (opt.max_ovlp_drop_ratio - opt.min_ovlp_drop_ratio) / opt.n_rounds * i : opt.min_ovlp_drop_ratio;|' main.c
grep -q 'float r = opt.n_rounds > 0? ' main.c

# minidot divided by the length of no sequence when no alignment passed its
# filters, and by a weight of 0 for alignments of fewer than 7 matching
# bases; a plot too tall for an int was converted to one anyway; and read
# names went into PostScript strings unescaped, so a parenthesis in one
# broke the file.
cat > biochef_eps.h <<'EPS_EOF'
static void biochef_eps_Mstr(FILE *fp, double x, double y, const char *s)
{
	fprintf(fp, "%g %g (", (float)x, (float)y);
	for (; *s; ++s) {
		if (*s == '(' || *s == ')' || *s == '\\') fputc('\\', fp);
		fputc(*s, fp);
	}
	fputs(") MS\n", fp);
}
EPS_EOF
sed -i -e 's|^#include "eps.h"$|&\n#include "biochef_eps.h"|' \
  -e 's|eps_Mstr(stdout, |biochef_eps_Mstr(stdout, |' \
  -e 's|^\tpaf_close(f);$|&\n\tif (h.n == 0) {\n\t\tfprintf(stderr, "[E::%s] no alignment in %s is %d bases long on both sequences (-s) with %d matching bases (-m) and an identity of %g (-i)\\n", __func__, argv[optind], min_span, min_match, min_iden);\n\t\treturn 1;\n\t}|' \
  -e 's|for (j = 0; j < n; ++j) b\[j\].tot /= b\[j\].w;|for (j = 0; j < n; ++j) if (b[j].w) b[j].tot /= b[j].w;|' \
  -e 's|^\theight = (int)((double)width / totlen\[0\] \* totlen\[1\] + .499);$|\tif ((double)width / totlen[0] * totlen[1] + .499 > 1e7) {\n\t\tfprintf(stderr, "[E::%s] the queries are %g times as long as the targets: a plot %d wide would be too tall\\n", __func__, (double)totlen[1] / totlen[0], width);\n\t\treturn 1;\n\t}\n&|' dotter.c
[ "$(grep -c 'biochef_eps_Mstr(stdout, ' dotter.c)" -eq 2 ]
grep -q '^#include "biochef_eps.h"$' dotter.c
grep -q 'no alignment in %s is %d bases long' dotter.c
grep -q 'if (b\[j\].w) b\[j\].tot /= b\[j\].w;' dotter.c
grep -q 'a plot %d wide would be too tall' dotter.c

# Renamed, the mains would give their messages as biochef_upstream_main's.
sed -i 's/__func__/"main"/g' main.c dotter.c
[ "$(cat main.c dotter.c | grep -c '__func__')" -eq 0 ]

make CFLAGS="-g -Wall -O2 -Wc++-compat -ffp-contract=off" -j4
