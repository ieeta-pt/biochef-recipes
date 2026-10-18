set -eo pipefail

# BioChef passes the hashed reads between operations as one tar. This entry
# point, linked in place of the main of velveth and velvetg, writes that tar
# after velveth, and checks and unpacks it before velvetg. The same entry
# point is in build-native.sh.
cat > biochef_main.c <<'SHIM_EOF'
/* The build names velvet's own main velvet_tool_main, for this one to wrap */
#undef main

#include <dirent.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(BC_VELVETH) && !defined(BC_VELVETG)
#error "define BC_VELVETH or BC_VELVETG"
#endif
int velvet_tool_main(int argc, char **argv);

/* velveth writes the reads (Sequences) and where each of their k-mers was
 * first seen (Roadmaps) into a directory, and velvetg assembles them there.
 * Between operations the two files travel as one tar holding them under
 * those names, so that a single input carries them and it can be unpacked
 * outside BioChef into a directory that velvetg reads. */
#define N_MEMBERS 2
enum { SEQUENCES, ROADMAPS };
static const char *members[N_MEMBERS + 1] = { "Sequences", "Roadmaps", NULL };
#define WORK_DIR "_bc_velvet"
/* Categories of reads: two of short reads, each single or paired, long,
 * long paired, and reference */
#define REFERENCE_CATEGORY (2 * CATEGORIES + 2)

static void fail(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void fail(const char *format, ...)
{
	va_list ap;
	fputs("[velvet] ", stderr);
	va_start(ap, format);
	vfprintf(stderr, format, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static void *xmalloc(size_t size)
{
	void *p = malloc(size ? size : 1);
	if (!p) fail("out of memory");
	return p;
}

static unsigned char *read_file(const char *path, long *size)
{
	FILE *fp = fopen(path, "rb");
	unsigned char *buf;
	if (!fp) fail("cannot read %s", path);
	if (fseek(fp, 0, SEEK_END) || (*size = ftell(fp)) < 0 || fseek(fp, 0, SEEK_SET)) fail("cannot read %s", path);
	buf = (unsigned char *)xmalloc(*size + 1);
	if (fread(buf, 1, *size, fp) != (size_t)*size) fail("cannot read %s", path);
	buf[*size] = 0;
	fclose(fp);
	return buf;
}

static const char *work_file(const char *name)
{
	static char path[sizeof WORK_DIR + 1 + 256];
	snprintf(path, sizeof path, WORK_DIR "/%s", name);
	return path;
}

/* velvet reads a reference named name:start-end as that stretch of name: it
 * splits the header at : and - (and velveth also at spaces) with strtok,
 * and crashes when a name with : lacks a start or an end after it */
static int reference_name_ok(const unsigned char *p, const unsigned char *end, const char *delimiters)
{
	int tokens = 0, in = 0;
	for (; p < end && *p; ++p) {
		if (strchr(delimiters, *p)) in = 0;
		else if (!in) in = 1, ++tokens;
	}
	return tokens >= 3;
}

/* The working directory, of this run or one before it in the same file
 * system: velvetg would build on any graph it finds there */
static void cleanup(void)
{
	DIR *dir = opendir(WORK_DIR);
	struct dirent *e;
	if (!dir) return;
	while ((e = readdir(dir)))
		if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) unlink(work_file(e->d_name));
	closedir(dir);
	rmdir(WORK_DIR);
}

/* ---- tar (POSIX ustar), only regular files ---- */

static unsigned tar_checksum(const unsigned char *h)
{
	unsigned sum = 0;
	int i;
	for (i = 0; i < 512; ++i) sum += (i >= 148 && i < 156) ? ' ' : h[i];
	return sum;
}

#ifdef BC_VELVETH
/* Writes the two files as a tar with fixed owner, mode and time, so the
 * same reads always give the same bytes */
static void tar_write(const char *path)
{
	FILE *out = fopen(path, "wb");
	static unsigned char zero[1024];
	int i;
	if (!out) fail("cannot write %s", path);
	for (i = 0; members[i]; ++i) {
		unsigned char h[512];
		long size, pad;
		unsigned char *data = read_file(work_file(members[i]), &size);
		if ((long long)size >= 077777777777LL) fail("%s is too large for a tar", members[i]);
		memset(h, 0, sizeof h);
		memcpy(h, members[i], strlen(members[i]));
		memcpy(h + 100, "0000644", 7);
		memcpy(h + 108, "0000000", 7);
		memcpy(h + 116, "0000000", 7);
		snprintf((char *)h + 124, 12, "%011lo", size);
		memcpy(h + 136, "00000000000", 11);
		h[156] = '0';
		memcpy(h + 257, "ustar", 6);
		memcpy(h + 263, "00", 2);
		snprintf((char *)h + 148, 8, "%06o", tar_checksum(h));
		h[155] = ' ';
		pad = (512 - size % 512) % 512;
		if (fwrite(h, 1, 512, out) != 512 || fwrite(data, 1, size, out) != (size_t)size
		    || fwrite(zero, 1, pad, out) != (size_t)pad)
			fail("cannot write %s", path);
		free(data);
	}
	if (fwrite(zero, 1, 1024, out) != 1024 || fclose(out)) fail("cannot write %s", path);
}
#else

static const char *hash_path;

static void bad(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void bad(const char *format, ...)
{
	va_list ap;
	fprintf(stderr, "[velvet] %s is not a velveth output: ", hash_path);
	va_start(ap, format);
	vfprintf(stderr, format, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static long octal(const unsigned char *p, int len)
{
	long v = 0;
	int i = 0;
	while (i < len && p[i] == ' ') ++i;
	if (i == len || p[i] < '0' || p[i] > '7') bad("a broken tar header");
	for (; i < len && p[i] >= '0' && p[i] <= '7'; ++i) {
		if (v > (LONG_MAX - 7) / 8) bad("a member is too large");
		v = v * 8 + (p[i] - '0');
	}
	for (; i < len; ++i)
		if (p[i] != ' ' && p[i] != 0) bad("a broken tar header");
	return v;
}

/* A pax header (typeflag x or g) may carry attributes such as times or
 * extended attributes, which do not matter here. One that renames the next
 * member or changes its size would make it a different file: refused. */
static void check_pax(const unsigned char *p, long len)
{
	const unsigned char *end = p + len;
	while (p < end && *p) {
		long n = 0;
		const unsigned char *q = p, *key;
		while (q < end && *q >= '0' && *q <= '9' && n < len) n = n * 10 + (*q++ - '0');
		if (q == p || q >= end || *q != ' ' || n <= q - p + 1 || n > end - p || p[n - 1] != '\n')
			bad("a broken pax header");
		key = q + 1;
		if (!strncmp((const char *)key, "path=", 5) || !strncmp((const char *)key, "linkpath=", 9)
		    || !strncmp((const char *)key, "size=", 5) || !strncmp((const char *)key, "GNU.sparse", 10))
			bad("a pax header changes a member");
		p += n;
	}
}

struct hash { const unsigned char *data[N_MEMBERS]; long size[N_MEMBERS]; unsigned char *buf; int found; };

/* Reads a tar that must hold Sequences and Roadmaps, each once, as regular
 * files. Nothing in it names a path. */
static void tar_read(struct hash *x)
{
	long size, off = 0;
	int i;
	memset(x, 0, sizeof *x);
	x->buf = read_file(hash_path, &size);
	for (;;) {
		const unsigned char *h = x->buf + off;
		long len;
		if (off + 512 > size) bad("it ends inside a tar header");
		for (i = 0; i < 512 && !h[i]; ++i);
		if (i == 512) break;
		if (memcmp(h + 257, "ustar", 5)) bad("not a tar file");
		if (octal(h + 148, 8) != (long)tar_checksum(h)) bad("a tar header checksum is wrong");
		len = octal(h + 124, 12);
		if (len > size - off - 512) bad("%.100s is cut short", (const char *)h);
		if (h[156] == 'x' || h[156] == 'g') {
			check_pax(h + 512, len);
			off += 512 + (len + 511) / 512 * 512;
			continue;
		}
		if (h[156] != '0' && h[156] != 0) bad("it holds something other than files");
		if (h[345]) bad("a member has a path");
		/* macOS tar adds the extended attributes of a file as ._file */
		for (i = 0; members[i]; ++i)
			if (!strncmp((const char *)h, "._", 2) && !strncmp((const char *)h + 2, members[i], 98) && !h[2 + strlen(members[i])]) break;
		if (members[i]) {
			off += 512 + (len + 511) / 512 * 512;
			continue;
		}
		for (i = 0; members[i]; ++i)
			if (!strncmp((const char *)h, members[i], 100) && !h[strlen(members[i])]) break;
		if (!members[i]) bad("it holds %.100s", (const char *)h);
		if (x->found & 1 << i) bad("it holds %s twice", members[i]);
		x->found |= 1 << i;
		x->data[i] = h + 512;
		x->size[i] = len;
		off += 512 + (len + 511) / 512 * 512;
	}
	for (i = 0; members[i]; ++i)
		if (!(x->found & 1 << i)) bad("it lacks %s", members[i]);
}

/* ---- the two files ---- */

/* A whole number of at most 18 digits, with a minus sign where allowed,
 * from p up to the end of its field: returns where the field ends */
static const unsigned char *number(const unsigned char *p, const unsigned char *end, int sign, int64_t *v)
{
	int neg = 0, digits = 0;
	*v = 0;
	if (sign && p < end && *p == '-') neg = 1, ++p;
	for (; p < end && *p >= '0' && *p <= '9'; ++p) {
		if (++digits > 18) return NULL;
		*v = *v * 10 + (*p - '0');
	}
	if (!digits || (digits > 1 && p[-digits] == '0')) return NULL;
	if (neg) {
		if (!*v) return NULL;
		*v = -*v;
	}
	return p;
}

struct reads {
	int64_t count, references;
	int64_t *start;       /* where each read starts in text, and count + 1 ends */
	unsigned char *text;  /* the reads, N read as A, as velvet does */
	unsigned char *rc;    /* each read reverse complemented, at the same place */
	unsigned char *second; /* the second read of a pair, where k-mers are read reversed */
};

static unsigned char complement(unsigned char c)
{
	return c == 'A' ? 'T' : c == 'C' ? 'G' : c == 'G' ? 'C' : 'A';
}

/* Sequences: per read a header, >name, its number from 1 and its category,
 * separated by tabs, then its bases in lines. velvetg reads lines of up to
 * 4999 bytes and categories as indexes. References come first. */
static void read_sequences(const unsigned char *p, long size, struct reads *r)
{
	const unsigned char *end = p + size, *line, *eol;
	int64_t bases = 0, cap = 1024, i, category = 0, previous = 0;
	int phase = 0;
	unsigned char *categories;
	if (!size) bad("Sequences holds no reads");
	if (end[-1] != '\n') bad("Sequences is cut short");
	memset(r, 0, sizeof *r);
	r->start = (int64_t *)xmalloc(cap * sizeof *r->start);
	categories = (unsigned char *)xmalloc(cap);
	r->text = (unsigned char *)xmalloc(size);
	for (line = p; line < end; line = eol + 1) {
		eol = (const unsigned char *)memchr(line, '\n', end - line);
		if (eol - line > 4998) bad("Sequences has a line longer than velvetg reads");
		if (*line == '>') {
			const unsigned char *q = (const unsigned char *)memchr(line, '\t', eol - line);
			int64_t id;
			if (!q || !(q = number(q + 1, eol, 0, &id)) || q >= eol || *q != '\t'
			    || !(q = number(q + 1, eol, 0, &category)) || q != eol)
				bad("Sequences has a broken header: %.*s", (int)(eol - line > 80 ? 80 : eol - line), (const char *)line);
			if (id != r->count + 1) bad("Sequences numbers read %lld as %lld", (long long)r->count + 1, (long long)id);
			if (category > REFERENCE_CATEGORY) bad("Sequences has a read of category %lld", (long long)category);
			if (category == REFERENCE_CATEGORY) {
				if (r->references != r->count) bad("Sequences has a reference after the reads");
				if (memchr(line, ':', eol - line) && !reference_name_ok(line, eol, ":-\r\n"))
					bad("Sequences has a reference named with a : but no start and end: %.*s", (int)(eol - line > 80 ? 80 : eol - line), (const char *)line);
				++r->references;
			}
			if (r->count + 1 >= cap) {
				cap *= 2;
				if (!(r->start = (int64_t *)realloc(r->start, cap * sizeof *r->start)) || !(categories = (unsigned char *)realloc(categories, cap)))
					fail("out of memory");
			}
			categories[r->count] = (unsigned char)category;
			r->start[r->count++] = bases;
		} else if (*line == 'M') {
			bad("Sequences maps reads to the references, as velveth does for SAM or BAM input, which BioChef does not check");
		} else {
			if (!r->count) bad("Sequences does not start with a read");
			for (; line < eol; ++line) {
				if (*line != 'A' && *line != 'C' && *line != 'G' && *line != 'T' && *line != 'N')
					bad("Sequences has a base %c", *line);
				r->text[bases++] = *line == 'N' ? 'A' : *line;
			}
		}
	}
	if (!r->count) bad("Sequences holds no reads");
	r->start[r->count] = bases;
	r->rc = (unsigned char *)xmalloc(bases);
	for (i = 0; i < r->count; ++i) {
		int64_t a = r->start[i], b = r->start[i + 1], j;
		for (j = a; j < b; ++j) r->rc[a + b - 1 - j] = complement(r->text[j]);
	}
	/* which reads are second in a pair, as velvet works it out: the reads
	 * of a paired (odd) category go two by two */
	r->second = (unsigned char *)xmalloc(r->count);
	for (i = 0; i < r->count; ++i) {
		r->second[i] = 0;
		if (categories[i] & 1) {
			if (previous == categories[i]) {
				if (!phase) phase = 1;
				else r->second[i] = 1, phase = 0;
			} else
				phase = 1;
		}
		previous = categories[i];
	}
	free(categories);
}

/* The k-mer at read i, position x, in the direction velveth stores it:
 * returns its first base and the direction, 1 or -1 */
static const unsigned char *kmer(const struct reads *r, int64_t i, int64_t x, int k, int double_strand, int *direction)
{
	int64_t a = r->start[i], len = r->start[i + 1] - a;
	const unsigned char *forward = r->text + a + x, *reverse = r->rc + a + (len - x - k);
	if (double_strand ? memcmp(forward, reverse, k) <= 0 : !r->second[i]) {
		*direction = 1;
		return forward;
	}
	*direction = -1;
	return reverse;
}

/* Roadmaps: a header with the numbers of reads and references, k and
 * whether both strands count, then per read "ROADMAP n" and a line per run
 * of its k-mers seen before: the read they were first seen in (negative
 * when on its other strand), how many new k-mers of this read come before
 * the run, and where the run starts and ends among the new k-mers of that
 * read, counting down on the other strand, to -1 when it ends at the first
 * one. velveth built with OpenMP hashes reads in parallel, so the reads can
 * come in any order and point to reads after them. velvetg reads lines of
 * up to 99 bytes.
 *
 * velvetg follows these to build its graph, and trusts them. So each run is
 * checked against the reads, by rebuilding the k-mers velveth stored: every
 * k-mer of a run must be the one it points to. */

struct roadmaps {
	const unsigned char *data, *end;
	int k, double_strand;
	const unsigned char **block; /* where the runs of each read start */
	int64_t *novel_start;        /* where the new k-mers of each read start in novel */
	int64_t *novel_count;
	int32_t *novel;              /* by where they are in their read, negative when stored reversed */
};

/* A run: "read position start end", already checked to be four numbers */
static void run_fields(const unsigned char *line, const unsigned char *eol, int64_t *v)
{
	const unsigned char *q = line;
	int f;
	for (f = 0; f < 4; ++f) {
		q = number(q, eol, f == 0 || f == 3, &v[f]);
		++q;
	}
}

/* Walks the runs of read i: adds its new k-mers to novel when verify is 0,
 * and checks every k-mer of its runs against novel when it is 1 */
static void walk_read(const struct reads *r, struct roadmaps *m, int64_t i, int verify)
{
	const unsigned char *line, *eol;
	int64_t len = r->start[i + 1] - r->start[i], n = len >= m->k ? len - m->k + 1 : 0, x = 0, before = 0, v[4];
	int f;
	for (line = m->block[i]; line < m->end && *line != 'R'; line = eol + 1) {
		int64_t source, run, c;
		eol = (const unsigned char *)memchr(line, '\n', m->end - line);
		run_fields(line, eol, v);
		source = (v[0] < 0 ? -v[0] : v[0]) - 1;
		run = v[0] > 0 ? v[3] - v[2] : v[2] - v[3];
		if (source < 0 || source >= r->count) bad("Roadmaps points read %lld to read %lld", (long long)i + 1, (long long)source + 1);
		if (run < 1 || v[1] < before) bad("Roadmaps has a broken run in read %lld", (long long)i + 1);
		/* the new k-mers before the run */
		for (; before < v[1]; ++before, ++x) {
			if (x >= n) bad("Roadmaps runs past the end of read %lld", (long long)i + 1);
			if (!verify) {
				kmer(r, i, x, m->k, m->double_strand, &f);
				m->novel[m->novel_start[i] + m->novel_count[i]++] = (int32_t)(f * (x + 1));
			}
		}
		if (x + run > n) bad("Roadmaps runs past the end of read %lld", (long long)i + 1);
		if (verify)
			for (c = 0; c < run; ++c) {
				int64_t at = v[0] > 0 ? v[2] + c : v[2] - c, stored;
				const unsigned char *here, *there;
				int here_direction, there_direction;
				if (at < 0 || at >= m->novel_count[source])
					bad("Roadmaps points read %lld past the k-mers of read %lld", (long long)i + 1, (long long)source + 1);
				stored = m->novel[m->novel_start[source] + at];
				here = kmer(r, i, x + c, m->k, m->double_strand, &here_direction);
				there = kmer(r, source, (stored < 0 ? -stored : stored) - 1, m->k, m->double_strand, &there_direction);
				if (memcmp(here, there, m->k) || (v[0] > 0) != (here_direction == there_direction))
					bad("Roadmaps does not match the reads of Sequences, at read %lld", (long long)i + 1);
			}
		x += run;
	}
	/* the rest of the read is new */
	if (!verify)
		for (; x < n; ++x) {
			kmer(r, i, x, m->k, m->double_strand, &f);
			m->novel[m->novel_start[i] + m->novel_count[i]++] = (int32_t)(f * (x + 1));
		}
}

static void check_roadmaps(const unsigned char *p, long size, const struct reads *r)
{
	const unsigned char *end = p + size, *line, *eol, *q;
	int64_t v[4], i, kmers = 0;
	struct roadmaps m;
	int f;
	if (!size || end[-1] != '\n') bad("Roadmaps is cut short");
	eol = (const unsigned char *)memchr(p, '\n', size);
	if (eol - p > 98) bad("Roadmaps has a line longer than velvetg reads");
	for (q = p, f = 0; f < 4; ++f) {
		if (!(q = number(q, eol, 0, &v[f])) || (f < 3 ? q >= eol || *q++ != '\t' : q != eol))
			bad("Roadmaps has a broken header");
	}
	if (v[0] != r->count || v[1] != r->references)
		bad("Roadmaps is of %lld reads and %lld references, and Sequences holds %lld and %lld",
		    (long long)v[0], (long long)v[1], (long long)r->count, (long long)r->references);
	if (v[2] < 1 || v[2] > MAXKMERLENGTH || v[2] % 2 == 0) bad("Roadmaps has a k of %lld", (long long)v[2]);
	if (v[3] > 1) bad("Roadmaps has a broken header");
	m.data = p;
	m.end = end;
	m.k = (int)v[2];
	m.double_strand = (int)v[3];
	m.block = (const unsigned char **)xmalloc(r->count * sizeof *m.block);
	m.novel_start = (int64_t *)xmalloc(r->count * sizeof *m.novel_start);
	m.novel_count = (int64_t *)xmalloc(r->count * sizeof *m.novel_count);
	for (i = 0; i < r->count; ++i) {
		int64_t len = r->start[i + 1] - r->start[i];
		m.block[i] = NULL;
		m.novel_start[i] = kmers;
		m.novel_count[i] = 0;
		if (len >= m.k) kmers += len - m.k + 1;
	}
	m.novel = (int32_t *)xmalloc((kmers ? kmers : 1) * sizeof *m.novel);

	/* the lines, and where the runs of each read start */
	i = -1;
	for (line = eol + 1; line < end; line = eol + 1) {
		eol = (const unsigned char *)memchr(line, '\n', end - line);
		if (eol - line > 98) bad("Roadmaps has a line longer than velvetg reads");
		if (*line == 'R') {
			if (eol - line < 9 || memcmp(line, "ROADMAP ", 8) || !(q = number(line + 8, eol, 0, &v[0])) || q != eol)
				bad("Roadmaps has a broken line: %.*s", (int)(eol - line), (const char *)line);
			if (v[0] < 1 || v[0] > r->count) bad("Roadmaps has read %lld, and Sequences %lld reads", (long long)v[0], (long long)r->count);
			i = v[0] - 1;
			if (m.block[i]) bad("Roadmaps has read %lld twice", (long long)i + 1);
			m.block[i] = eol + 1;
			continue;
		}
		if (i < 0) bad("Roadmaps does not start with a read");
		for (q = line, f = 0; f < 4; ++f)
			if (!(q = number(q, eol, f == 0 || f == 3, &v[f])) || (f < 3 ? q >= eol || *q++ != '\t' : q != eol))
				bad("Roadmaps has a broken line: %.*s", (int)(eol - line), (const char *)line);
	}
	for (i = 0; i < r->count; ++i)
		if (!m.block[i]) bad("Roadmaps lacks read %lld", (long long)i + 1);
	for (i = 0; i < r->count; ++i) walk_read(r, &m, i, 0);
	for (i = 0; i < r->count; ++i) walk_read(r, &m, i, 1);
	free(m.block);
	free(m.novel_start);
	free(m.novel_count);
	free(m.novel);
}

/* Checks the two files and writes them into the working directory */
static void unpack(const char *path)
{
	struct hash x;
	struct reads r;
	int i;
	hash_path = path;
	tar_read(&x);
	read_sequences(x.data[SEQUENCES], x.size[SEQUENCES], &r);
	check_roadmaps(x.data[ROADMAPS], x.size[ROADMAPS], &r);
	free(r.start);
	free(r.text);
	free(r.rc);
	free(r.second);
	if (mkdir(WORK_DIR, 0755)) fail("cannot make %s", WORK_DIR);
	for (i = 0; members[i]; ++i) {
		FILE *fp = fopen(work_file(members[i]), "wb");
		if (!fp || fwrite(x.data[i], 1, x.size[i], fp) != (size_t)x.size[i] || fclose(fp))
			fail("cannot write %s", work_file(members[i]));
	}
	free(x.buf);
}

/* An output the operation declares must exist, even when velvetg had
 * nothing to write to it */
static void move_or_create(const char *name, const char *to)
{
	FILE *fp;
	if (!access(work_file(name), F_OK)) {
		long size;
		unsigned char *data;
		if (!rename(work_file(name), to)) return;
		/* to is on another file system */
		data = read_file(work_file(name), &size);
		if (!(fp = fopen(to, "wb")) || fwrite(data, 1, size, fp) != (size_t)size || fclose(fp)) fail("cannot write %s", to);
		free(data);
		return;
	}
	if (!(fp = fopen(to, "wb")) || fclose(fp)) fail("cannot write %s", to);
}
#endif

#ifdef BC_VELVETH
static int is_number(const char *s)
{
	if (!*s) return 0;
	for (; *s; ++s)
		if (*s < '0' || *s > '9') return 0;
	return 1;
}

/* --bc-out FILE        write the hashed reads here, as a tar
 * --bc-k N             the k-mer length
 * --bc-reads FILE      short reads, single unless --bc-paired or --bc-mates
 * --bc-paired          the short reads are pairs, one after the other
 * --bc-mates FILE      the second reads of pairs, for the reads of --bc-reads
 * --bc-long FILE       long reads
 * --bc-reference FILE  reference sequences
 * -strand_specific     as velveth */
int main(int argc, char *argv[])
{
	const char *out = NULL, *k = NULL, *reads = NULL, *mates = NULL, *longs = NULL, *reference = NULL;
	char *args[20];
	int i, n = 0, paired = 0, strand_specific = 0, rc;

	cleanup();
	if (atexit(cleanup)) fail("cannot register the clean-up");

	for (i = 1; i < argc; ++i) {
		const char *a = argv[i], **slot;
		if (!strcmp(a, "--bc-paired")) {
			paired = 1;
			continue;
		}
		if (!strcmp(a, "-strand_specific")) {
			strand_specific = 1;
			continue;
		}
		if (!strcmp(a, "--bc-out")) slot = &out;
		else if (!strcmp(a, "--bc-k")) slot = &k;
		else if (!strcmp(a, "--bc-reads")) slot = &reads;
		else if (!strcmp(a, "--bc-mates")) slot = &mates;
		else if (!strcmp(a, "--bc-long")) slot = &longs;
		else if (!strcmp(a, "--bc-reference")) slot = &reference;
		else fail("unknown option %s", a);
		if (i + 1 >= argc) fail("%s needs a value", a);
		if (*slot) fail("%s given twice", a);
		*slot = argv[++i];
	}
	if (!out) fail("--bc-out is needed");
	if (!k || !is_number(k) || atoi(k) < 1 || strlen(k) > 4) fail("--bc-k needs a k-mer length");
	if (!reads && !longs && !reference) fail("no reads to hash");
	if ((mates || paired) && !reads) fail("--bc-mates and --bc-paired go with --bc-reads");
	if (mates && paired) fail("--bc-paired is for pairs in one file, and --bc-mates for pairs in two");
	/* velveth takes a name that starts with - as an option */
	if ((reads && reads[0] == '-') || (mates && mates[0] == '-') || (longs && longs[0] == '-') || (reference && reference[0] == '-'))
		fail("the names of the reads cannot start with -");

	if (reference) {
		long size;
		unsigned char *data = read_file(reference, &size), *line, *eol;
		for (line = data; line < data + size; line = eol + 1) {
			if (!(eol = (unsigned char *)memchr(line, '\n', data + size - line))) eol = data + size;
			if (*line == '>' && memchr(line, ':', eol - line) && !reference_name_ok(line, eol, ":-\r\n\t "))
				fail("the reference %.*s has a : in its name but no start and end, as in name:start-end, which velveth cannot read",
				     (int)(eol - line > 80 ? 80 : eol - line), (const char *)line);
		}
		free(data);
	}

	/* velveth counts the references from the first read, so they go first */
	args[n++] = argv[0];
	args[n++] = (char *)WORK_DIR;
	args[n++] = (char *)k;
	args[n++] = (char *)"-fmtAuto";
	if (strand_specific) args[n++] = (char *)"-strand_specific";
	if (reference) {
		args[n++] = (char *)"-reference";
		args[n++] = (char *)reference;
	}
	if (reads) {
		args[n++] = (char *)(mates || paired ? "-shortPaired" : "-short");
		if (mates) args[n++] = (char *)"-separate";
		args[n++] = (char *)reads;
		if (mates) args[n++] = (char *)mates;
	}
	if (longs) {
		args[n++] = (char *)"-long";
		args[n++] = (char *)longs;
	}
	args[n] = NULL;
	rc = velvet_tool_main(n, args);
	if (rc != 0) return rc;
	if (access(work_file("Roadmaps"), F_OK)) fail("velveth wrote no Roadmaps");
	tar_write(out);
	return 0;
}
#else
/* --bc-hash FILE          the hashed reads, as velveth's operations write them
 * --bc-contigs FILE       contigs.fa
 * --bc-stats FILE         stats.txt
 * --bc-graph FILE         LastGraph
 * --bc-afg FILE           velvet_asm.afg (-amos_file yes)
 * --bc-unused FILE        UnusedReads.fa (-unused_reads yes)
 * --bc-alignments FILE    contig-alignments.psa (-alignments yes)
 * --bc-low-coverage FILE, --bc-high-coverage FILE
 *                         lowCoverageContigs.fa and highCoverageContigs.fa
 *                         (-exportFiltered yes)
 * Every other option goes to velvetg. */
int main(int argc, char *argv[])
{
	static const char *output_files[] = { "contigs.fa", "stats.txt", "LastGraph", "velvet_asm.afg", "UnusedReads.fa",
	                                      "contig-alignments.psa", "lowCoverageContigs.fa", "highCoverageContigs.fa" };
	static const char *output_options[] = { "--bc-contigs", "--bc-stats", "--bc-graph", "--bc-afg", "--bc-unused",
	                                        "--bc-alignments", "--bc-low-coverage", "--bc-high-coverage" };
	static const char *managed[] = { "-amos_file", "-unused_reads", "-alignments", "-exportFiltered", "-clean", "-very_clean", NULL };
	const char *hash = NULL, *outputs[8] = { NULL };
	char **args = (char **)calloc(argc + 12, sizeof(char *));
	int i, j, n = 0, rc;

	if (!args) fail("out of memory");
	cleanup();
	if (atexit(cleanup)) fail("cannot register the clean-up");

	args[n++] = argv[0];
	args[n++] = (char *)WORK_DIR;
	for (i = 1; i < argc; ++i) {
		const char *a = argv[i], **slot = NULL;
		if (!strcmp(a, "--bc-hash")) slot = &hash;
		for (j = 0; j < 8; ++j)
			if (!strcmp(a, output_options[j])) slot = &outputs[j];
		if (!slot) {
			for (j = 0; managed[j]; ++j)
				if (!strcmp(a, managed[j])) fail("%s is set by the outputs of the operation", a);
			args[n++] = argv[i];
			continue;
		}
		if (i + 1 >= argc) fail("%s needs a file", a);
		if (*slot) fail("%s given twice", a);
		*slot = argv[++i];
	}
	if (!hash) fail("--bc-hash is needed");
	if (!outputs[0]) fail("--bc-contigs is needed");
	if (outputs[3]) args[n++] = (char *)"-amos_file", args[n++] = (char *)"yes";
	if (outputs[4]) args[n++] = (char *)"-unused_reads", args[n++] = (char *)"yes";
	if (outputs[5]) args[n++] = (char *)"-alignments", args[n++] = (char *)"yes";
	if (outputs[6] || outputs[7]) args[n++] = (char *)"-exportFiltered", args[n++] = (char *)"yes";
	args[n] = NULL;
	unpack(hash);
	rc = velvet_tool_main(n, args);
	if (rc != 0) return rc;
	for (j = 0; j < 8; ++j)
		if (outputs[j]) move_or_create(output_files[j], outputs[j]);
	return 0;
}
#endif
SHIM_EOF

# k-mers up to 63; reads, and references, longer than 32 kb
DEF="-DMAXKMERLENGTH=63 -DCATEGORIES=2 -DLONGSEQUENCES"
MAKEVARS="MAXKMERLENGTH=63 LONGSEQUENCES=1"

# dfibHeap.h declares destroyNodeInDHeap as returning a pointer, and
# dfibHeap.c defines it as returning nothing. Natively the call works; in
# wasm a call through the wrong signature traps, as tour bus does on long
# reads.
sed -i 's/^void \*destroyNodeInDHeap(DFibHeapNode \* node, DFibHeap \* heap);$/void destroyNodeInDHeap(DFibHeapNode * node, DFibHeap * heap);/' src/dfibHeap.h
grep -q '^void destroyNodeInDHeap(DFibHeapNode \* node, DFibHeap \* heap);$' src/dfibHeap.h

for tool in velveth velvetg; do
  define=$(case $tool in velveth) echo BC_VELVETH ;; velvetg) echo BC_VELVETG ;; esac)
  emcc -Wall -O2 $DEF -D$define -c biochef_main.c -o "bc_$tool.o"
  emmake make "$tool" CC=emcc $MAKEVARS CFLAGS="-Wall -sUSE_ZLIB=1 -Dmain=velvet_tool_main" LDFLAGS="bc_$tool.o" \
    LIBS="-lm -sSTACK_SIZE=8MB $EM_FLAGS"
done

mkdir -p out
for tool in velveth velvetg; do mv "$tool" "out/$tool.js"; mv "$tool.wasm" "out/$tool.wasm"; done
