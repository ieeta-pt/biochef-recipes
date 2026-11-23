set -eo pipefail

# The sources muscle.vcxproj lists and the options vcxproj_make.py gives
# them (src/build_linux.bash), without OpenMP: wasm has no threads here, so
# its pragmas are ignored and omp.h is a stub with one thread and locks that
# do nothing. gitver.txt as vcxproj_make.py writes it.
cd src

# GetPhysMemBytes exists only for Windows, Linux and macOS; muscle uses it
# for a memory warning and its banner, and returns 0.0 itself when it cannot
# read it, as it does here. The int64 typedefs are changed by
# patches/wasm-int64-long-long.patch.
cat > physmem_wasm.cpp <<'EOF_CPP'
double GetPhysMemBytes()
	{
	return 0.0;
	}
EOF_CPP

echo "\"$(git log --oneline | head -n1 | cut -d' ' -f1)\"" > gitver.txt
sed -n 's/.*<ClCompile Include="\([^"]*\)".*/\1/p' muscle.vcxproj > sources.txt
echo physmem_wasm.cpp >> sources.txt
mkdir -p ompstub obj
cat > ompstub/omp.h <<'EOF_OMP'
#pragma once
typedef int omp_lock_t;
static inline void omp_init_lock(omp_lock_t *l) { (void)l; }
static inline void omp_destroy_lock(omp_lock_t *l) { (void)l; }
static inline void omp_set_lock(omp_lock_t *l) { (void)l; }
static inline void omp_unset_lock(omp_lock_t *l) { (void)l; }
static inline int omp_get_max_threads(void) { return 1; }
static inline int omp_get_num_threads(void) { return 1; }
static inline int omp_get_thread_num(void) { return 0; }
EOF_OMP
xargs -P 4 -I{} sh -c 'em++ -O3 -DNDEBUG -ffast-math -Iompstub -c {} -o obj/$(basename {} .cpp).o' < sources.txt
mkdir -p ../out
em++ -O3 -ffast-math $EM_FLAGS obj/*.o -o ../out/muscle.js
