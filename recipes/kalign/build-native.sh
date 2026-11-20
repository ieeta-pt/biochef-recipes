set -eo pipefail

# An existing alignment with no gap characters and sequences of one length
# is read as ALN_STATUS_UNKNOWN, which has the same value (3) as
# ALN_STATUS_FINAL, so --add took it as finalised with alnlen 0 and read
# before the start of a buffer. Its sequences are kept as they are, so its
# length is that of its sequences, as msa_cmp.c already assumes; sequences
# of different lengths are an error.
python3 - <<'BIOCHEF_PY'
import sys

path = "lib/src/aln_add.c"
src = open(path).read()
old = "        alnlen = existing->alnlen;\n"
if src.count(old) != 1:
    sys.exit(f"patch: expected one alnlen assignment in {path}, found {src.count(old)}")
new = old + """        if(alnlen == 0 && numseq_existing > 0){
                alnlen = existing->sequences[0]->len;
                for(i = 1; i < numseq_existing; i++){
                        if(existing->sequences[i]->len != alnlen){
                                ERROR_MSG("Existing MSA must be aligned");
                        }
                }
                existing->alnlen = alnlen;
        }
"""
open(path, "w").write(src.replace(old, new))
BIOCHEF_PY

# kalign's sources and defines as its CMake build lists them, without CMake,
# with its threadpool. NOHAVE_AVX2: the binary runs on any x86_64; the AVX2
# build gives the same alignments.
SOURCES="lib/src/test.c lib/src/tldevel.c lib/src/tlmisc.c lib/src/tlrng.c lib/src/esl_stopwatch.c lib/src/msa_alloc.c lib/src/msa_op.c lib/src/msa_io.c lib/src/msa_misc.c lib/src/msa_check.c lib/src/msa_cmp.c lib/src/msa_sort.c lib/src/alphabet.c lib/src/task.c lib/src/bisectingKmeans.c lib/src/sequence_distance.c lib/src/bpm.c lib/src/euclidean_dist.c lib/src/pick_anchor.c lib/src/aln_wrap.c lib/src/aln_apair_dist.c lib/src/aln_add.c lib/src/aln_param.c lib/src/aln_run.c lib/src/aln_mem.c lib/src/aln_setup.c lib/src/aln_controller.c lib/src/aln_seqseq.c lib/src/aln_seqprofile.c lib/src/aln_profileprofile.c lib/src/aln_refine.c lib/src/sp_score.c lib/src/weave_alignment.c lib/src/poar.c lib/src/consensus_msa.c lib/src/anchor_consistency.c lib/src/msa_consistency.c lib/src/ensemble.c lib/src/threadpool/threadpool.c src/run_kalign.c src/parameters.c"
mkdir -p bin
gcc -O3 -std=gnu11 -DNDEBUG -DNOHAVE_AVX2 -DUSE_THREADPOOL \
  -DKALIGN_ALN_SERIAL_THRESHOLD=500 -DKALIGN_KMEANS_UPGMA_THRESHOLD=50 \
  -DKALIGN_DIST_MIN_SEQS=50 -DKALIGN_PFOR_MIN_CHUNK=10 \
  -DKALIGN_PACKAGE_NAME='"kalign"' -DKALIGN_PACKAGE_VERSION='"3.6.0"' \
  -Ilib/include -Ilib/src -Ilib/src/threadpool $SOURCES -lm -pthread -o bin/kalign
