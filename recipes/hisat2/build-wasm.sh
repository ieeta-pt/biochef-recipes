set -eo pipefail

# BioChef passes the index between operations as one tar. This entry point,
# linked in place of hisat2's own main in each program, writes that tar after
# hisat2-build, and checks and unpacks it before hisat2-align and
# hisat2-inspect. The same entry point is in build-native.sh.
cat > biochef_main.cpp <<'SHIM_EOF'
/* The build names hisat2's own main hisat2_tool_main, for this one to wrap */
#undef main

#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(BC_ALIGN) || defined(BC_BUILD)
typedef const char **tool_argv;
#elif defined(BC_INSPECT)
typedef char **tool_argv;
#else
#error "define BC_ALIGN, BC_BUILD or BC_INSPECT"
#endif
int hisat2_tool_main(int argc, tool_argv argv);

/* A HISAT2 index is eight files sharing a prefix, .1.ht2 to .8.ht2. Between
 * operations it travels as one tar holding them under the prefix "ref", so
 * that a single input carries the whole index and it can be unpacked
 * outside BioChef. */
#define N_MEMBERS 8
static const char *members[N_MEMBERS + 1] = { "ref.1.ht2", "ref.2.ht2", "ref.3.ht2", "ref.4.ht2", "ref.5.ht2",
                                              "ref.6.ht2", "ref.7.ht2", "ref.8.ht2", NULL };
#define PREFIX "_bc_ht2"

static void fail(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void fail(const char *format, ...)
{
	va_list ap;
	fputs("[hisat2] ", stderr);
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

static const char *member_file(int i)
{
	static char name[64];
	snprintf(name, sizeof name, PREFIX "%s", members[i] + 3);
	return name;
}

/* ---- tar (POSIX ustar), only regular files ---- */

static unsigned tar_checksum(const unsigned char *h)
{
	unsigned sum = 0;
	int i;
	for (i = 0; i < 512; ++i) sum += (i >= 148 && i < 156) ? ' ' : h[i];
	return sum;
}

#ifdef BC_BUILD
/* Writes the index files as a tar with fixed owner, mode and time, so the
 * same index always gives the same bytes. */
static void tar_write(const char *path)
{
	FILE *out = fopen(path, "wb");
	static unsigned char zero[1024];
	int i;
	if (!out) fail("cannot write %s", path);
	for (i = 0; members[i]; ++i) {
		unsigned char h[512];
		long size, pad;
		unsigned char *data = read_file(member_file(i), &size);
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

static long octal(const unsigned char *p, int len, const char *path)
{
	long v = 0;
	int i = 0;
	while (i < len && p[i] == ' ') ++i;
	if (i == len || p[i] < '0' || p[i] > '7') fail("%s is not a HISAT2 index: a broken tar header", path);
	for (; i < len && p[i] >= '0' && p[i] <= '7'; ++i) {
		if (v > (LONG_MAX - 7) / 8) fail("%s is not a HISAT2 index: a member is too large", path);
		v = v * 8 + (p[i] - '0');
	}
	for (; i < len; ++i)
		if (p[i] != ' ' && p[i] != 0) fail("%s is not a HISAT2 index: a broken tar header", path);
	return v;
}

/* A pax header (typeflag x or g) may carry attributes such as times or
 * extended attributes, which do not matter here. One that renames the next
 * member or changes its size would make it a different file: refused. */
static void check_pax(const unsigned char *p, long len, const char *path)
{
	const unsigned char *end = p + len;
	while (p < end && *p) {
		long n = 0;
		const unsigned char *q = p, *key;
		while (q < end && *q >= '0' && *q <= '9' && n < len) n = n * 10 + (*q++ - '0');
		if (q == p || q >= end || *q != ' ' || n <= q - p + 1 || n > end - p || p[n - 1] != '\n')
			fail("%s is not a HISAT2 index: a broken pax header", path);
		key = q + 1;
		if (!strncmp((const char *)key, "path=", 5) || !strncmp((const char *)key, "linkpath=", 9)
		    || !strncmp((const char *)key, "size=", 5) || !strncmp((const char *)key, "GNU.sparse", 10))
			fail("%s is not a HISAT2 index: a pax header changes a member", path);
		p += n;
	}
}

struct index { const unsigned char *data[N_MEMBERS]; uint64_t size[N_MEMBERS]; unsigned char *buf; int found; };

/* Reads a tar that must hold the eight index files, each once, as regular
 * files. Nothing in it names a path. */
static void tar_read(const char *path, struct index *x)
{
	long size, off = 0;
	int i;
	memset(x, 0, sizeof *x);
	x->buf = read_file(path, &size);
	for (;;) {
		const unsigned char *h = x->buf + off;
		long len;
		if (off + 512 > size) fail("%s is not a HISAT2 index: it ends inside a tar header", path);
		for (i = 0; i < 512 && !h[i]; ++i);
		if (i == 512) break;
		if (memcmp(h + 257, "ustar", 5)) fail("%s is not a HISAT2 index: not a tar file", path);
		if (octal(h + 148, 8, path) != (long)tar_checksum(h)) fail("%s is not a HISAT2 index: a tar header checksum is wrong", path);
		len = octal(h + 124, 12, path);
		if (len > size - off - 512) fail("%s is not a HISAT2 index: %.100s is cut short", path, (const char *)h);
		if (h[156] == 'x' || h[156] == 'g') {
			check_pax(h + 512, len, path);
			off += 512 + (len + 511) / 512 * 512;
			continue;
		}
		if (h[156] != '0' && h[156] != 0) fail("%s is not a HISAT2 index: it holds something other than files", path);
		if (h[345]) fail("%s is not a HISAT2 index: a member has a path", path);
		/* macOS tar adds the extended attributes of a file as ._file */
		for (i = 0; members[i]; ++i)
			if (!strncmp((const char *)h, "._", 2) && !strncmp((const char *)h + 2, members[i], 98) && !h[2 + strlen(members[i])]) break;
		if (members[i]) {
			off += 512 + (len + 511) / 512 * 512;
			continue;
		}
		for (i = 0; members[i]; ++i)
			if (!strncmp((const char *)h, members[i], 100) && !h[strlen(members[i])]) break;
		if (!members[i]) fail("%s is not a HISAT2 index: it holds %.100s", path, (const char *)h);
		if (x->found & 1 << i) fail("%s is not a HISAT2 index: it holds %s twice", path, members[i]);
		x->found |= 1 << i;
		x->data[i] = h + 512;
		x->size[i] = len;
		off += 512 + (len + 511) / 512 * 512;
	}
	for (i = 0; members[i]; ++i)
		if (!(x->found & 1 << i)) fail("%s is not a HISAT2 index: it lacks %s", path, members[i]);
}

/* ---- the index files ---- */

static const char *index_path;

static void bad(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void bad(const char *format, ...)
{
	va_list ap;
	fprintf(stderr, "[hisat2] %s is not a HISAT2 index: ", index_path);
	va_start(ap, format);
	vfprintf(stderr, format, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

/* A reader over one member, which refuses to read past its end */
struct rd { const unsigned char *p; uint64_t n, o; const char *name; };

static void rd_init(struct rd *r, const struct index *x, int i)
{
	r->p = x->data[i];
	r->n = x->size[i];
	r->o = 0;
	r->name = members[i];
}

static void need(struct rd *r, uint64_t n)
{
	if (n > r->n - r->o) bad("%s is cut short", r->name);
}

static uint32_t at32(const unsigned char *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint32_t at16(const unsigned char *p)
{
	return p[0] | p[1] << 8;
}

static uint64_t at_w(const unsigned char *p, int w)
{
	return w == 4 ? at32(p) : at16(p);
}

static uint32_t u32(struct rd *r)
{
	need(r, 4);
	r->o += 4;
	return at32(r->p + r->o - 4);
}

static uint32_t u16(struct rd *r)
{
	need(r, 2);
	r->o += 2;
	return at16(r->p + r->o - 2);
}

/* Returns where an array of n w-byte numbers starts, and skips it */
static const unsigned char *arr(struct rd *r, uint64_t w, uint64_t n)
{
	const unsigned char *p = r->p + r->o;
	if (n > (r->n - r->o) / w) bad("%s is cut short", r->name);
	r->o += w * n;
	return p;
}

/* Every HISAT2 index file starts with 1, which says it is little-endian */
static void start(struct rd *r, const struct index *x, int i)
{
	rd_init(r, x, i);
	if (u32(r) != 1) bad("%s is not a HISAT2 index file of this byte order", r->name);
}

/* The sizes that follow from a GFM header, as hisat2 computes them
 * (GFMParams::init). w is the width of its numbers: 4 for the global index,
 * 2 for the local ones. */
struct gfm {
	uint64_t len, gbwt_len, nodes, tot_len, offs_len, ftab_len, side_len;
	int linear, line_rate, off_rate;
};

static void gfm_params(struct gfm *g, uint64_t len, uint64_t gbwt_len, uint64_t nodes, int32_t line_rate,
                       int32_t off_rate, int32_t ftab_chars, int w, const char *name)
{
	uint64_t side, side_bytes, gbwt_sz;
	if (line_rate < 5 || line_rate > 24 || off_rate < 0 || off_rate > 31 || ftab_chars < 1 || ftab_chars > 15)
		bad("%s has broken parameters", name);
	g->linear = gbwt_len == 0 || gbwt_len == len + 1;
	g->len = len;
	g->gbwt_len = gbwt_len ? gbwt_len : len + 1;
	g->nodes = nodes ? nodes : len + 1;
	if (g->gbwt_len < len + 1 || g->nodes > g->gbwt_len) bad("%s has broken sizes", name);
	gbwt_sz = g->linear ? g->gbwt_len / 4 + 1 : g->gbwt_len / 2 + 1;
	side = (uint64_t)1 << line_rate;
	side_bytes = side - w * (g->linear ? 4 : 6);
	g->side_len = side_bytes * 4;
	g->tot_len = (gbwt_sz + side_bytes - 1) / side_bytes * side;
	g->offs_len = (g->nodes + ((uint64_t)1 << off_rate) - 1) >> off_rate;
	g->ftab_len = ((uint64_t)1 << 2 * ftab_chars) + 1;
	g->line_rate = line_rate;
	g->off_rate = off_rate;
}

/* The reference, from .4: two bits a base, the first in the low bits */
static const unsigned char *ref_bits;

static int base(uint64_t i)
{
	return ref_bits[i >> 2] >> (i & 3) * 2 & 3;
}

static void count_bases(uint64_t from, uint64_t n, uint64_t c[4])
{
	uint64_t i;
	c[0] = c[1] = c[2] = c[3] = 0;
	for (i = from; i < from + n; ++i) ++c[base(i)];
}

/* fchr holds where each base starts among the sorted rows. In a linear
 * index, its counts are those of the text; a graph also has the bases of its
 * variants. */
static void check_fchr(const struct gfm *g, const uint64_t f[5], uint64_t from, const char *name)
{
	uint64_t c[4];
	int i;
	if (f[0] != 0 || f[4] != (g->linear ? g->len : g->gbwt_len - 1)) bad("%s has broken counts", name);
	for (i = 0; i < 4; ++i)
		if (f[i] > f[i + 1]) bad("%s has broken counts", name);
	count_bases(from, g->len, c);
	for (i = 0; i < 4; ++i)
		if (g->linear ? c[i] != f[i + 1] - f[i] : c[i] > f[i + 1] - f[i]) bad("%s is not of the sequence in ref.4.ht2", name);
}

/* Whether the suffix of text[from, from + n) at a sorts before the one at b,
 * the end sorting after every base. Suffixes that agree for more than 4096
 * bases are taken as in order. */
static int suffix_before(uint64_t from, uint64_t n, uint64_t a, uint64_t b)
{
	uint64_t k;
	for (k = 0; k < 4096; ++k) {
		if (a + k == n) return 0;
		if (b + k == n) return 1;
		if (base(from + a + k) != base(from + b + k)) return base(from + a + k) < base(from + b + k);
	}
	return 1;
}

static int cmp_u64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return x < y ? -1 : x > y;
}

/* The BWT is cut into sides, each ending with the counts of the bases in
 * the sides before it, and in a graph of the nodes marked M, which hisat2
 * uses to find rows. They must be those of the BWT, whose bases add up to
 * fchr. The rows in zoffs hold the end of the text, stored as an A. */
static void check_bwt(const struct gfm *g, const unsigned char *bwt, const unsigned char *zoffs, uint64_t n_z,
                      const uint64_t f[5], int w, const char *name)
{
	uint64_t side = (uint64_t)1 << g->line_rate, data = side - w * (g->linear ? 4 : 6);
	uint64_t rows = g->linear ? data * 4 : data * 2, cnt[4] = { 0, 0, 0, 0 }, m = 0, s, i, row = 0, zi = 0;
	uint64_t *z = (uint64_t *)xmalloc((n_z ? n_z : 1) * sizeof(uint64_t));
	for (i = 0; i < n_z; ++i) z[i] = at_w(zoffs + w * i, w);
	qsort(z, n_z, sizeof(uint64_t), cmp_u64);
	for (s = 0; s < g->tot_len / side; ++s) {
		const unsigned char *sd = bwt + s * side, *c = sd + data;
		if (!g->linear) {
			if (at_w(c + w, w) != m) bad("%s has broken counts", name);
			c += 2 * w;
		}
		for (i = 0; i < 4; ++i)
			if (at_w(c + w * i, w) != cnt[i]) bad("%s has broken counts", name);
		for (i = 0; i < rows && row < g->gbwt_len; ++i, ++row) {
			if (!g->linear) m += sd[data / 2 + data / 4 + i / 8] >> (i & 7) & 1;
			while (zi < n_z && z[zi] < row) ++zi;
			if (zi < n_z && z[zi] == row) continue;
			++cnt[sd[i / 4] >> (i & 3) * 2 & 3];
		}
	}
	free(z);
	for (i = 0; i < 4; ++i)
		if (cnt[i] != f[i + 1] - f[i]) bad("%s has broken counts", name);
	if (!g->linear && m != g->nodes) bad("%s has broken counts", name);
}

/* ftab gives the first row of each prefix of ftabChars bases; an entry
 * beyond the rows names a pair of rows in eftab instead */
static void check_ftab(const struct gfm *g, const unsigned char *ftab, const unsigned char *eftab, uint64_t eftab_len,
                       int w, const char *name)
{
	uint64_t bound = g->linear ? g->len : g->gbwt_len, ones = w == 4 ? UINT32_MAX : UINT16_MAX, i, v;
	for (i = 0; i < g->ftab_len; ++i)
		if ((v = at_w(ftab + w * i, w)) > bound && (v ^ ones) * 2 + 1 >= eftab_len) bad("%s has broken prefix tables", name);
	for (i = 0; i < eftab_len; ++i)
		if (at_w(eftab + w * i, w) > g->gbwt_len) bad("%s has broken prefix tables", name);
}

/* In a linear index, offs samples the suffix array every 2^offRate rows:
 * the samples are suffixes of the text in sorted order, and the BWT holds the
 * base before each. In a graph, rows are nodes of the graph, which only the
 * bounds of the samples are checked against: a sample is a position in the
 * text, or all ones for a node that has none. */
static void check_samples(const struct gfm *g, const unsigned char *bwt, const unsigned char *offs, int w,
                          uint64_t from, const char *name, const char *offs_name)
{
	uint64_t k, none = w == 4 ? UINT32_MAX : UINT16_MAX;
#define SAMPLE(k) (w == 4 ? at32(offs + 4 * (k)) : at16(offs + 2 * (k)))
	for (k = 0; k < g->offs_len; ++k)
		if (SAMPLE(k) > g->len && (g->linear || SAMPLE(k) != none)) bad("%s is not of %s", offs_name, name);
	if (!g->linear) return;
	for (k = 1; k < g->offs_len; ++k)
		if (!suffix_before(from, g->len, SAMPLE(k - 1), SAMPLE(k))) bad("%s is not of the sequence in ref.4.ht2", offs_name);
	for (k = 0; k < g->offs_len; ++k) {
		uint64_t p = SAMPLE(k), row = k << g->off_rate, side = row / g->side_len, i = row % g->side_len;
		if (p && (bwt[side * ((uint64_t)1 << g->line_rate) + i / 4] >> (i & 3) * 2 & 3) != base(from + p - 1))
			bad("%s is not of the sequence in ref.4.ht2", name);
	}
#undef SAMPLE
}

/* The files must belong together, as hisat2 assumes when it reads them:
 * .3 lays out the sequences that .1 indexes and .4 holds, .2 samples the
 * suffix array of .1, the local indexes in .5 and .6 cover those sequences
 * in windows, and .7 and .8 describe the same variants. */
static void check_index(const struct index *x)
{
	struct rd r;
	struct gfm g;
	const unsigned char *plen, *rstarts, *bwt, *names, *offs, *zoffs, *ftab, *eftab;
	uint64_t n_pat, n_frag, n_recs, n_z, f[5], k, i, n_alts, joined = 0, frag = 0;
	uint64_t *ref_plen, *ref_unambig, *ref_start, *covered, n_refs = 0;
	uint32_t len, gbwt_len, nodes, eftab_len;
	int32_t line_rate, off_rate, ftab_chars;

	/* .1: the global index of the joined sequences */
	start(&r, x, 0);
	u32(&r);
	len = u32(&r);
	gbwt_len = u32(&r);
	nodes = u32(&r);
	line_rate = (int32_t)u32(&r);
	u32(&r);
	off_rate = (int32_t)u32(&r);
	ftab_chars = (int32_t)u32(&r);
	eftab_len = u32(&r);
	u32(&r);
	if (len < 1) bad("ref.1.ht2 indexes no sequence");
	gfm_params(&g, len, gbwt_len, nodes, line_rate, off_rate, ftab_chars, 4, "ref.1.ht2");
	n_pat = u32(&r);
	plen = arr(&r, 4, n_pat);
	n_frag = u32(&r);
	rstarts = arr(&r, 12, n_frag);
	bwt = arr(&r, 1, g.tot_len);
	n_z = u32(&r);
	zoffs = arr(&r, 4, n_z);
	for (i = 0; i < n_z; ++i)
		if (at32(zoffs + 4 * i) >= g.gbwt_len) bad("ref.1.ht2 has broken offsets");
	for (i = 0; i < 5; ++i) f[i] = u32(&r);
	ftab = arr(&r, 4, g.ftab_len);
	eftab = arr(&r, 4, eftab_len);
	check_bwt(&g, bwt, zoffs, n_z, f, 4, "ref.1.ht2");
	check_ftab(&g, ftab, eftab, eftab_len, 4, "ref.1.ht2");
	/* then the names of the sequences, a line each, and a NUL */
	names = r.p + r.o;
	for (i = k = 0; r.o + i + 1 < r.n; ++i) {
		if (!names[i]) bad("ref.1.ht2 has broken sequence names");
		k += names[i] == '\n';
	}
	if (r.o == r.n || names[r.n - r.o - 1] || (r.n - r.o > 1 && names[r.n - r.o - 2] != '\n') || k != n_pat)
		bad("ref.1.ht2 has broken sequence names");

	/* .3: the stretches of each sequence that are not N */
	start(&r, x, 2);
	n_recs = u32(&r);
	if (n_recs < 1 || r.n != 8 + 9 * n_recs) bad("ref.3.ht2 is not whole");
	ref_plen = (uint64_t *)xmalloc(n_recs * 4 * sizeof(uint64_t));
	ref_unambig = ref_plen + n_recs;
	ref_start = ref_unambig + n_recs;
	covered = ref_start + n_recs;
	for (k = 0; k < n_recs; ++k) {
		const unsigned char *p = r.p + 8 + 9 * k;
		uint64_t off = at32(p), n = at32(p + 4);
		if (p[8] > 1 || (k == 0 && !p[8])) bad("ref.3.ht2 is not whole");
		if (p[8]) {
			if (n_refs == n_pat) bad("ref.3.ht2 is not of ref.1.ht2");
			ref_plen[n_refs] = ref_unambig[n_refs] = covered[n_refs] = 0;
			ref_start[n_refs++] = joined;
		}
		if (n) {
			const unsigned char *s = rstarts + 12 * frag;
			if (frag == n_frag || at32(s) != joined || at32(s + 4) != n_refs - 1 || at32(s + 8) != ref_plen[n_refs - 1] + off)
				bad("ref.3.ht2 is not of ref.1.ht2");
			++frag;
		}
		ref_plen[n_refs - 1] += off + n;
		ref_unambig[n_refs - 1] += n;
		joined += n;
	}
	if (n_refs != n_pat || frag != n_frag || joined != len) bad("ref.3.ht2 is not of ref.1.ht2");
	for (k = 0; k < n_pat; ++k)
		if (ref_plen[k] != at32(plen + 4 * k)) bad("ref.3.ht2 is not of ref.1.ht2");

	/* .4: those stretches, joined */
	if (x->size[3] != (len + 3) / 4) bad("ref.4.ht2 is not of ref.3.ht2");
	ref_bits = x->data[3];
	check_fchr(&g, f, 0, "ref.1.ht2");

	/* .2: the suffix array samples of .1 */
	start(&r, x, 1);
	if (r.n - r.o != 4 * g.offs_len) bad("ref.2.ht2 is not of ref.1.ht2");
	offs = arr(&r, 4, g.offs_len);
	check_samples(&g, bwt, offs, 4, 0, "ref.1.ht2", "ref.2.ht2");

	/* .5 and .6: the local indexes, in windows of each sequence */
	{
		struct rd r6;
		uint64_t n_local, prev = 0;
		int32_t l_line, l_off, l_ftab;
		start(&r, x, 4);
		start(&r6, x, 5);
		n_local = u32(&r);
		l_line = (int32_t)u32(&r);
		u32(&r);
		l_off = (int32_t)u32(&r);
		l_ftab = (int32_t)u32(&r);
		u32(&r);
		for (k = 0; k < n_local; ++k) {
			struct gfm lg;
			uint64_t t = u32(&r), lo = u32(&r), jo = u32(&r), l_len, l_gbwt, l_nodes, l_eftab, lf[5];
			const unsigned char *l_bwt, *l_offs;
			l_len = u16(&r);
			l_gbwt = u16(&r);
			l_nodes = u16(&r);
			l_eftab = u16(&r);
			if (t >= n_pat || (k && t < prev) || lo > covered[t] || lo + l_len > ref_unambig[t] || jo != ref_start[t] + lo)
				bad("ref.5.ht2 is not of ref.3.ht2");
			prev = t;
			if (lo + l_len > covered[t]) covered[t] = lo + l_len;
			if (!l_len) continue;
			gfm_params(&lg, l_len, l_gbwt, l_nodes, l_line, l_off, l_ftab, 2, "ref.5.ht2");
			arr(&r, 2, u16(&r));
			arr(&r, 6, u16(&r));
			l_bwt = arr(&r, 1, lg.tot_len);
			n_z = u16(&r);
			zoffs = arr(&r, 2, n_z);
			for (i = 0; i < n_z; ++i)
				if (at16(zoffs + 2 * i) >= lg.gbwt_len) bad("ref.5.ht2 has broken offsets");
			for (i = 0; i < 5; ++i) lf[i] = u16(&r);
			check_fchr(&lg, lf, jo, "ref.5.ht2");
			ftab = arr(&r, 2, lg.ftab_len);
			eftab = arr(&r, 2, l_eftab);
			check_bwt(&lg, l_bwt, zoffs, n_z, lf, 2, "ref.5.ht2");
			check_ftab(&lg, ftab, eftab, l_eftab, 2, "ref.5.ht2");
			if (lg.offs_len > (r6.n - r6.o) / 2) bad("ref.6.ht2 is not of ref.5.ht2");
			l_offs = arr(&r6, 2, lg.offs_len);
			check_samples(&lg, l_bwt, l_offs, 2, jo, "ref.5.ht2", "ref.6.ht2");
		}
		if (r.o + 1 != r.n || r.p[r.o]) bad("ref.5.ht2 is not whole");
		if (r6.o != r6.n) bad("ref.6.ht2 is not of ref.5.ht2");
		for (k = 0; k < n_pat; ++k)
			if (covered[k] != ref_unambig[k]) bad("ref.5.ht2 does not cover the sequences of ref.3.ht2");
	}
	free(ref_plen);

	/* .7: the variants (SNPs, splice sites and exons) and haplotypes; .8:
	 * their names */
	start(&r, x, 6);
	n_alts = u32(&r);
	for (k = 0; k < n_alts; ++k) {
		const unsigned char *a = arr(&r, 20, 1);
		uint64_t pos = at32(a), type = at32(a + 4), n = at32(a + 8);
		if (pos >= len || type < 1 || type > 6 || type == 4
		    || (type == 1 && n != 1) || (type == 3 && pos + n > len) || (type >= 5 && (n < pos || n >= len)))
			bad("ref.7.ht2 has a variant outside ref.3.ht2");
	}
	if (r.o < r.n) {
		uint64_t n_ht = u32(&r);
		for (k = 0; k < n_ht; ++k) {
			uint64_t left = u32(&r), right = u32(&r), n = u32(&r);
			const unsigned char *a = arr(&r, 4, n);
			if (left > right || right >= len) bad("ref.7.ht2 has a haplotype outside ref.3.ht2");
			for (i = 0; i < n; ++i)
				if (at32(a + 4 * i) >= n_alts) bad("ref.7.ht2 has a broken haplotype");
		}
	}
	if (r.o != r.n) bad("ref.7.ht2 is not whole");
	start(&r, x, 7);
	if (u32(&r) != n_alts) bad("ref.8.ht2 is not of ref.7.ht2");
	/* hisat2 reads the names as words, between the spaces of C++ streams */
	for (i = r.o, k = 0; i < r.n; ++i) {
		int c = r.p[i], space = c == ' ' || (c >= '\t' && c <= '\r');
		if (!space && (c < ' ' || c == 0x7f)) bad("ref.8.ht2 is not text");
		if (!space && (i == r.o || r.p[i - 1] == ' ' || (r.p[i - 1] >= '\t' && r.p[i - 1] <= '\r'))) ++k;
	}
	if (k != n_alts) bad("ref.8.ht2 is not of ref.7.ht2");
}

static void write_file(const char *path, const void *data, long size)
{
	FILE *fp = fopen(path, "wb");
	if (!fp || fwrite(data, 1, size, fp) != (size_t)size || fclose(fp)) fail("cannot write %s", path);
}

static void unpack(const char *path)
{
	struct index x;
	int i;
	index_path = path;
	tar_read(path, &x);
	check_index(&x);
	for (i = 0; members[i]; ++i) write_file(member_file(i), x.data[i], x.size[i]);
	free(x.buf);
}

#endif

static void remove_index(void)
{
	int i;
	for (i = 0; members[i]; ++i) unlink(member_file(i));
}

#ifdef BC_ALIGN
/* hisat2 reads FASTQ unless told the reads are FASTA: returns '>' or '@'
 * after the blank lines that start a reads file, or 0 for an empty one */
static int reads_kind(const char *path)
{
	FILE *fp = fopen(path, "rb");
	int c;
	if (!fp) fail("cannot read %s", path);
	while ((c = getc(fp)) == '\n' || c == '\r' || c == ' ' || c == '\t');
	fclose(fp);
	if (c == EOF) return 0;
	if (c != '>' && c != '@') fail("%s is neither FASTA nor FASTQ", path);
	return c;
}
#endif

/* --bc-index FILE  an index to read
 * --bc-out FILE    hisat2-build writes the index here
 *
 * align and build take lists of files separated by commas, so a file name
 * with a comma would be read as two. */
int main(int argc, char *argv[])
{
	const char **args = (const char **)calloc(argc + 4, sizeof(char *));
	const char *index = NULL, *out = NULL;
	int i, n = 0, rc;

	if (!args) fail("out of memory");
	/* Working files, of this run or one before it in the same file system */
	remove_index();
	if (atexit(remove_index)) fail("cannot register the clean-up");

	args[n++] = argv[0];
	for (i = 1; i < argc; ++i) {
		const char *a = argv[i], **slot;
		if (!strcmp(a, "--bc-index")) slot = &index;
		else if (!strcmp(a, "--bc-out")) slot = &out;
		else {
			args[n++] = argv[i];
			continue;
		}
		if (i + 1 >= argc) fail("%s needs a file", a);
		if (*slot) fail("%s given twice", a);
		*slot = argv[++i];
	}
	args[n] = NULL;

#ifdef BC_BUILD
	if (index) fail("--bc-index goes with align and inspect only");
	if (!out) return hisat2_tool_main(n, (tool_argv)args);
	/* the reference comes last; the index prefix follows it */
	if (n < 2 || args[n - 1][0] == '-') fail("no reference given");
	if (strchr(args[n - 1], ',')) fail("the name %s has a comma", args[n - 1]);
	args[n++] = PREFIX;
	args[n] = NULL;
	rc = hisat2_tool_main(n, (tool_argv)args);
	if (rc != 0) return rc;
	tar_write(out);
	return 0;
#else
	if (out) fail("--bc-out goes with build only");
	if (!index) return hisat2_tool_main(n, (tool_argv)args);
	unpack(index);
#ifdef BC_ALIGN
	{
		int fasta = 0, fastq = 0, has_f = 0;
		for (i = 1; i < n; ++i) {
			if (!strcmp(args[i], "-f")) has_f = 1;
			if ((!strcmp(args[i], "-U") || !strcmp(args[i], "-1") || !strcmp(args[i], "-2")) && i + 1 < n) {
				int kind;
				if (strchr(args[++i], ',')) fail("the name %s has a comma", args[i]);
				kind = reads_kind(args[i]);
				fasta |= kind == '>';
				fastq |= kind == '@';
			}
		}
		if (fasta && fastq) fail("the reads are FASTA and FASTQ: give them in one format");
		args[n++] = "-x";
		args[n++] = PREFIX;
		if (fasta && !has_f) args[n++] = "-f";
		args[n] = NULL;
		rc = hisat2_tool_main(n, (tool_argv)args);
	}
#else
	/* inspect: the index prefix is its one argument */
	args[n++] = PREFIX;
	args[n] = NULL;
	rc = hisat2_tool_main(n, (tool_argv)args);
#endif
	return rc;
#endif
}
SHIM_EOF

# Under wasm there are no threads to run the search workers: run each in
# place.
sed -i.bak 's|^            threads\[i\] = new tthread::thread(multiseedSearchWorker_hisat2, (void\*)&tids\[i\]);$|#ifdef __EMSCRIPTEN__\n            multiseedSearchWorker_hisat2((void*)\&tids[i]);\n            threads[i] = NULL;\n#else\n&\n#endif|; s|^            threads\[i\]->join();$|            if (threads[i] != NULL) threads[i]->join();|' hisat2.cpp
grep -q 'multiseedSearchWorker_hisat2((void\*)&tids\[i\]);' hisat2.cpp

# Offsets are TRefOff, a signed 64-bit number, but refExtent() is a size_t:
# 1 - refExtent() is the negative number meant only where size_t has 64
# bits. In wasm32 it is near 2^32, which made the fragment length of every
# pair (TLEN) that of one mate.
sed -i 's|^        st2.adjustOff(1 - refExtent());$|        st2.adjustOff(1 - (TRefOff)refExtent());|' aligner_result.h
grep -q 'st2.adjustOff(1 - (TRefOff)refExtent());' aligner_result.h

# hisat2-build's threads wait on each other, which wasm cannot run: build
# with one. The index is the same for any number of threads.
sed -i 's|^                nthreads = parseNumber<int>(1, "-p arg must be at least 1");$|&\n#ifdef __EMSCRIPTEN__\n                nthreads = 1;\n#endif|' hisat2_build.cpp
grep -q '^                nthreads = 1;$' hisat2_build.cpp

# hisat2 reports errors by throwing, and catches them to exit with a
# message and a status; hisat2-build catches running out of memory to try
# again with less. Both need C++ exceptions, which emscripten leaves off.
for tool in align build inspect; do
  emmake make "hisat2-$tool-s" \
    CXX=em++ \
    CC=emcc \
    RELEASE_FLAGS="-O2 -msimd128 -msse4.2 -std=c++11" \
    EXTRA_FLAGS="-std=c++11 -fwasm-exceptions $EM_FLAGS -sSTACK_SIZE=8MB -Dmain=hisat2_tool_main -DBC_${tool^^} biochef_main.cpp" \
    NO_TBB=1
  mv "hisat2-$tool-s" "hisat2-$tool-s.js"
done
