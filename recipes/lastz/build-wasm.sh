cd src

emmake make CC=emcc -j4 lastz

emcc -O3 $EM_FLAGS lastz.o infer_scores.o seeds.o pos_table.o quantum.o seed_search.o diag_hash.o chain.o gapped_extend.o tweener.o masking.o segment.o edit_script.o identity_dist.o coverage_dist.o continuity_dist.o output.o gfa.o lav.o axt.o maf.o cigar.o sam.o genpaf.o text_align.o align_diffs.o utilities.o dna_utilities.o sequences.o capsule.o -lm -o lastz.js