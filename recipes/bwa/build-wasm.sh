# Patch kthread.c: Emscripten's no-pthread stubs leave pthread_cond_wait
# blocking forever and pthread_create silently returns without running the
# worker. Both kt_for (used by mem_process_seqs) and kt_pipeline (used by
# the bwa mem main loop) need sequential single-threaded fallbacks.
cat > kthread.c <<'KTHREAD_EOF'
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>

struct kt_for_t;
typedef struct { struct kt_for_t *t; long i; } ktf_worker_t;
typedef struct kt_for_t {
    int n_threads;
    long n;
    ktf_worker_t *w;
    void (*func)(void*, long, int);
    void *data;
} kt_for_t;

static inline long steal_work(kt_for_t *t)
{
    int i, min_i = -1;
    long k, min = LONG_MAX;
    for (i = 0; i < t->n_threads; ++i)
        if (min > t->w[i].i)
            min = t->w[i].i, min_i = i;
    k = __sync_fetch_and_add(&t->w[min_i].i, t->n_threads);
    return k >= t->n ? -1 : k;
}

static void *ktf_worker(void *data)
{
    ktf_worker_t *w = (ktf_worker_t*)data;
    long i;
    for (;;) {
        i = __sync_fetch_and_add(&w->i, w->t->n_threads);
        if (i >= w->t->n) break;
        w->t->func(w->t->data, i, w - w->t->w);
    }
    while ((i = steal_work(w->t)) >= 0)
        w->t->func(w->t->data, i, w - w->t->w);
    pthread_exit(0);
}

void kt_for(int n_threads, void (*func)(void*, long, int), void *data, long n)
{
#ifdef __EMSCRIPTEN__
    long i;
    (void)n_threads;
    for (i = 0; i < n; ++i)
        func(data, i, 0);
#else
    int i;
    kt_for_t t;
    pthread_t *tid;
    t.func = func, t.data = data, t.n_threads = n_threads, t.n = n;
    t.w = (ktf_worker_t*)alloca(n_threads * sizeof(ktf_worker_t));
    tid = (pthread_t*)alloca(n_threads * sizeof(pthread_t));
    for (i = 0; i < n_threads; ++i)
        t.w[i].t = &t, t.w[i].i = i;
    for (i = 0; i < n_threads; ++i)
        pthread_create(&tid[i], 0, ktf_worker, &t.w[i]);
    for (i = 0; i < n_threads; ++i)
        pthread_join(tid[i], 0);
#endif
}

struct ktp_t;
typedef struct {
    struct ktp_t *pl;
    int64_t index;
    int step;
    void *data;
} ktp_worker_t;
typedef struct ktp_t {
    void *shared;
    void *(*func)(void*, int, void*);
    int64_t index;
    int n_workers, n_steps;
    ktp_worker_t *workers;
    pthread_mutex_t mutex;
    pthread_cond_t cv;
} ktp_t;

static void *ktp_worker(void *data)
{
    ktp_worker_t *w = (ktp_worker_t*)data;
    ktp_t *p = w->pl;
    while (w->step < p->n_steps) {
        pthread_mutex_lock(&p->mutex);
        for (;;) {
            int i;
            for (i = 0; i < p->n_workers; ++i) {
                if (w == &p->workers[i]) continue;
                if (p->workers[i].step <= w->step &&
                    p->workers[i].index < w->index)
                    break;
            }
            if (i == p->n_workers) break;
            pthread_cond_wait(&p->cv, &p->mutex);
        }
        pthread_mutex_unlock(&p->mutex);
        w->data = p->func(p->shared, w->step, w->step ? w->data : 0);
        pthread_mutex_lock(&p->mutex);
        w->step = w->step == p->n_steps - 1 || w->data
            ? (w->step + 1) % p->n_steps : p->n_steps;
        if (w->step == 0) w->index = p->index++;
        pthread_cond_broadcast(&p->cv);
        pthread_mutex_unlock(&p->mutex);
    }
    pthread_exit(0);
}

#ifdef __EMSCRIPTEN__
void kt_pipeline(int n_threads, void *(*func)(void*, int, void*),
                 void *shared_data, int n_steps)
{
    (void)n_threads;
    for (;;) {
        void *data = func(shared_data, 0, 0);
        int step;
        if (data == 0) return;
        for (step = 1; step < n_steps; ++step)
            data = func(shared_data, step, data);
    }
}
#else
void kt_pipeline(int n_threads, void *(*func)(void*, int, void*),
                 void *shared_data, int n_steps)
{
    ktp_t aux;
    pthread_t *tid;
    int i;
    if (n_threads < 1) n_threads = 1;
    aux.n_workers = n_threads;
    aux.n_steps = n_steps;
    aux.func = func;
    aux.shared = shared_data;
    aux.index = 0;
    pthread_mutex_init(&aux.mutex, 0);
    pthread_cond_init(&aux.cv, 0);
    aux.workers = (ktp_worker_t*)alloca(n_threads * sizeof(ktp_worker_t));
    for (i = 0; i < n_threads; ++i) {
        ktp_worker_t *w = &aux.workers[i];
        w->step = 0;
        w->pl = &aux;
        w->data = 0;
        w->index = aux.index++;
    }
    tid = (pthread_t*)alloca(n_threads * sizeof(pthread_t));
    for (i = 0; i < n_threads; ++i)
        pthread_create(&tid[i], 0, ktp_worker, &aux.workers[i]);
    for (i = 0; i < n_threads; ++i)
        pthread_join(tid[i], 0);
    pthread_mutex_destroy(&aux.mutex);
    pthread_cond_destroy(&aux.cv);
}
#endif
KTHREAD_EOF

emmake make CC=emcc AR=emar CFLAGS="-O3 -sUSE_ZLIB=1 -msse2 -msimd128 -Wno-unused-function -Wno-implicit-function-declaration" DFLAGS=-DUSE_MALLOC_WRAPPERS LIBS="-lm -lz" -j4 bwa

emcc -O3 -msse2 -msimd128 $EM_FLAGS -sINITIAL_MEMORY=64MB bwashm.o bwase.o bwaseqio.o bwtgap.o bwtaln.o bamlite.o bwape.o kopen.o pemerge.o maxk.o bwtsw2_core.o bwtsw2_main.o bwtsw2_aux.o bwt_lite.o bwtsw2_chain.o fastmap.o bwtsw2_pair.o main.o -o bwa.js -L. -lbwa -lm -lz
