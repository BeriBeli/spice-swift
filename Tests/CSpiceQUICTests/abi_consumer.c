// This consumer is compiled ONCE against the unchanged upstream quic.h, then
// linked unchanged to the independent C oracle and shipped spice-gtk artifact.
#include "quic.h"
#include <assert.h>
#include <limits.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(v) do { if (!(v)) { fprintf(stderr, "check failed line %d: %s\n", __LINE__, #v); abort(); } } while (0)
#define GUARD 32

typedef union {
    struct { size_t size; } data;
    max_align_t alignment;
} Allocation;

typedef struct {
    QuicUsrContext user;
    jmp_buf jump;
    size_t live, allocations, fail_at;
    int errors, warnings, mode, fail_io, fail_lines;
    uint8_t *encoded;
    size_t capacity, position;
    unsigned chunk;
    int rows;
    uint32_t input_chunk[17];
    uint8_t *next_line;
    unsigned lines_left, batch;
    int stride;
} User;

static void *user_malloc(QuicUsrContext *user, int size) {
    User *u = (User *)user;
    CHECK(size > 0);
    u->allocations++;
    if (u->allocations == u->fail_at) return NULL;
    Allocation *a = malloc(sizeof(*a) + GUARD + (size_t)size + GUARD);
    CHECK(a);
    a->data.size = (size_t)size;
    uint8_t *p = (uint8_t *)(a+1);
    memset(p, 0xa5, GUARD);
    memset(p+GUARD+size, 0xa5, GUARD);
    u->live++;
    return p+GUARD;
}
static void user_free(QuicUsrContext *user, void *pointer) {
    if (!pointer) return;
    User *u = (User *)user;
    uint8_t *p = (uint8_t *)pointer-GUARD;
    Allocation *a = (Allocation *)p-1;
    for (int i=0;i<GUARD;i++) {
        CHECK(p[i] == 0xa5 && p[GUARD+a->data.size+i] == 0xa5);
    }
    CHECK(u->live > 0);
    u->live--;
    memset(p+GUARD, 0xdd, a->data.size);
    free(a);
}
static __attribute__((noreturn, format(printf,2,3)))
void user_error(QuicUsrContext *user, const char *format, ...) {
    (void)format;
    User *u = (User *)user;
    u->errors++;
    longjmp(u->jump, 1);
}
static __attribute__((format(printf,2,3)))
void user_warn(QuicUsrContext *user, const char *format, ...) {
    (void)format;
    ((User *)user)->warnings++;
}
static __attribute__((format(printf,2,3)))
void user_info(QuicUsrContext *user, const char *format, ...) {
    (void)user; (void)format;
}
static int more_space(QuicUsrContext *user, uint32_t **out, int rows) {
    User *u = (User *)user;
    CHECK(rows >= u->rows);
    u->rows = rows;
    if (u->fail_io) {
        *out = NULL;
        return u->fail_io == 1 ? 0 : -1;
    }
    size_t n = (u->capacity-u->position)/4;
    if (n > u->chunk) n = u->chunk;
    if (u->mode == 1) {
        *out = (uint32_t *)(u->encoded+u->position);
    } else {
        CHECK(n <= 17);
        // Reuse the same physical buffer on every read callback.
        memcpy(u->input_chunk, u->encoded+u->position, n*4);
        *out = u->input_chunk;
    }
    u->position += n*4;
    return (int)n;
}
static int more_lines(QuicUsrContext *user, uint8_t **out) {
    User *u = (User *)user;
    if (u->fail_lines) {
        *out = NULL;
        return u->fail_lines == 1 ? 0 : -1;
    }
    unsigned n = u->lines_left < u->batch ? u->lines_left : u->batch;
    *out = u->next_line;
    u->next_line += (ptrdiff_t)n*u->stride;
    u->lines_left -= n;
    return (int)n;
}
static User *make_user(void) {
    User *u = calloc(1, sizeof(*u));
    CHECK(u);
    u->user = (QuicUsrContext){ user_error, user_warn, user_info, user_malloc,
                               user_free, more_space, more_lines };
    return u;
}
static unsigned bpp(int kind) { return kind < 4 ? (unsigned)kind : 4; }
static uint32_t seed = 0x71e45706;
static uint8_t random_byte(void) {
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return (uint8_t)seed;
}
static void prepare_io(User *u, uint8_t *data, size_t size, unsigned chunk, int mode) {
    u->encoded=data; u->capacity=size; u->chunk=chunk; u->mode=mode;
    u->position=0; u->rows=0;
}
static uint8_t *guarded(size_t size) {
    uint8_t *p = malloc(size+2*GUARD);
    CHECK(p); memset(p, 0xa5, size+2*GUARD); return p+GUARD;
}
static void guard_check(uint8_t *p, size_t size) {
    for (int i=0;i<GUARD;i++) CHECK(p[-GUARD+i]==0xa5 && p[size+i]==0xa5);
}
static int compatible(int source, int target) {
    return source == 1 ? target == 1 : source == 2 ? target == 2 || target == 4 :
        source == 5 ? target == 5 : target == 3 || target == 4;
}
static void expected_pixel(const uint8_t *src, int kind, int target, uint8_t out[4]) {
    memset(out,0,4);
    if (kind == 1) { out[0]=src[0]; return; }
    if (kind == 2) {
        unsigned value=src[0]|((unsigned)src[1]<<8);
        if (target == 2) { out[0]=src[0]; out[1]=src[1]&127; return; }
        for (int c=0;c<3;c++) { unsigned v=(value>>(c*5))&31; out[c]=(uint8_t)((v<<3)|(v>>2)); }
        return;
    }
    memcpy(out,src,kind==5?4:3);
}
static unsigned success_cases(const char *path) {
    FILE *file=fopen(path,"wb"); CHECK(file);
    User *u=make_user();
    QuicContext *ctx=quic_create(&u->user); CHECK(ctx);
    if (setjmp(u->jump)) { fprintf(stderr,"unexpected callback error\n"); abort(); }
    unsigned cases=0;
    const int sizes[][2]={{1,1},{31,19},{2049,7}};
    for (int kind=1;kind<=5;kind++) for (size_t d=0;d<3;d++)
    for (int pattern=0;pattern<3;pattern++) for (int sign=-1;sign<=1;sign+=2) {
        int w=sizes[d][0], h=sizes[d][1];
        int pitch=w*(int)bpp(kind)+(kind==2?8:7);
        size_t input_size=(size_t)pitch*h;
        uint8_t *input=guarded(input_size);
        uint8_t *first=input+(sign<0?(size_t)(h-1)*pitch:0);
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) for (unsigned c=0;c<bpp(kind);c++)
            first[(ptrdiff_t)y*sign*pitch+x*bpp(kind)+c] = pattern==0?random_byte():pattern==1?(uint8_t)(x*3+y*7+c*83):37;
        size_t capacity=(size_t)w*h*16+1024;
        uint8_t *encoded=guarded(capacity);
        for (unsigned chunk=1;chunk<=17;chunk+=8) {
            prepare_io(u,encoded,capacity,chunk,1);
            uint32_t *initial; int n=more_space(&u->user,&initial,0);
            u->next_line=first; u->lines_left=(unsigned)h; u->batch=2; u->stride=sign*pitch;
            // Upstream's unsigned num_lines*negative_stride sentinel overflows
            // for partial batches. Its valid negative-stride continuous path is
            // used here with two-byte alignment for RGB16 scalar accesses.
            uint8_t *lines=sign<0?first:NULL;
            unsigned count=sign<0?(unsigned)h:0;
            int words=quic_encode(ctx,kind,w,h,lines,count,sign*pitch,initial,(unsigned)n);
            CHECK(words>0); guard_check(encoded,capacity);
            CHECK(fwrite(encoded,4,(size_t)words,file)==(size_t)words);
            for (int target=1;target<=5;target++) if (compatible(kind,target))
            for (int out_sign=-1;out_sign<=1;out_sign+=2) {
                int out_pitch=w*(int)bpp(target)+(target==2?6:5);
                size_t out_size=(size_t)out_pitch*h;
                uint8_t *out=guarded(out_size);
                for (int y=0;y<h;y++) memset(out+(size_t)y*out_pitch,0,(size_t)w*bpp(target));
                uint8_t *out_first=out+(out_sign<0?(size_t)(h-1)*out_pitch:0);
                prepare_io(u,encoded,(size_t)words*4,chunk,0);
                n=more_space(&u->user,&initial,0);
                QuicImageType type=QUIC_IMAGE_TYPE_INVALID; int dw=0,dh=0;
                CHECK(quic_decode_begin(ctx,initial,(unsigned)n,&type,&dw,&dh)==0);
                CHECK((int)type==kind && dw==w && dh==h);
                CHECK(quic_decode(ctx,target,out_first,out_sign*out_pitch)==0);
                for (int y=0;y<h;y++) {
                    for (int x=0;x<w;x++) {
                        uint8_t expected[4]; expected_pixel(first+(ptrdiff_t)y*sign*pitch+x*bpp(kind),kind,target,expected);
                        CHECK(memcmp(out_first+(ptrdiff_t)y*out_sign*out_pitch+x*bpp(target),expected,bpp(target))==0);
                    }
                    for (int p=w*(int)bpp(target);p<out_pitch;p++) CHECK(out[(size_t)y*out_pitch+p]==0xa5);
                }
                guard_check(out,out_size); CHECK(fwrite(out,1,out_size,file)==out_size);
                free(out-GUARD); cases++;
            }
        }
        guard_check(input,input_size); free(input-GUARD); free(encoded-GUARD);
    }
    CHECK(u->errors==0 && u->warnings==0);
    quic_destroy(ctx); CHECK(u->live==0); free(u); CHECK(fclose(file)==0);
    return cases;
}

static void failure_cases(void) {
    // Each iteration injects one allocator failure. Context construction and
    // body storage are both covered; no callback choreography is assumed.
    for (int operation=0;operation<2;operation++) for (size_t fail=1;fail<=48;fail++) {
        User *u=make_user(); u->fail_at=fail;
        QuicContext *ctx=quic_create(&u->user);
        if (ctx) {
            uint32_t output[256]={0}; uint8_t pixels[4*17*3]={0};
            if (!setjmp(u->jump)) {
                if (operation==0) {
                    (void)quic_encode(ctx,QUIC_IMAGE_TYPE_RGBA,17,3,pixels,3,68,output,256);
                } else {
                    uint32_t stream[]={0x43495551,0,5,1,1,0x80808080,0};
                    QuicImageType kind; int width,height;
                    if (quic_decode_begin(ctx,stream,7,&kind,&width,&height)==0)
                        (void)quic_decode(ctx,kind,pixels,4);
                }
            }
            quic_destroy(ctx);
        }
        CHECK(u->live==0); free(u);
    }
    // Every word prefix of a one-pixel RGBA stream, including the required
    // trailing lookahead word. Fatal callbacks longjmp back into this C frame.
    const uint32_t stream[]={0x43495551,0,5,1,1,0x80808080,0};
    for (unsigned cut=1;cut<7;cut++) {
        User *u=make_user(); QuicContext *ctx=quic_create(&u->user); CHECK(ctx);
        prepare_io(u,(uint8_t *)stream,cut*4,1,0);
        uint32_t *initial; int n=more_space(&u->user,&initial,0);
        volatile int status=0;
        if (!setjmp(u->jump)) {
            QuicImageType kind; int width,height; uint8_t output[4]={0};
            status=quic_decode_begin(ctx,initial,(unsigned)n,&kind,&width,&height);
            if (!status) status=quic_decode(ctx,kind,output,4);
        } else status=-1;
        CHECK(status==-1); CHECK(u->errors==1);
        // A fresh valid begin must work on the same context after a fatal call.
        u->fail_io=0;
        prepare_io(u,(uint8_t *)stream,sizeof(stream),1,0);
        n=more_space(&u->user,&initial,0);
        if (!setjmp(u->jump)) {
            QuicImageType kind; int width,height; uint8_t output[4]={0};
            CHECK(quic_decode_begin(ctx,initial,(unsigned)n,&kind,&width,&height)==0);
            CHECK(quic_decode(ctx,kind,output,4)==0);
        } else CHECK(0);
        quic_destroy(ctx); CHECK(u->live==0); free(u);
    }
    for (int which=0;which<2;which++) for (int failure=1;failure<=2;failure++) {
        User *u=make_user(); QuicContext *ctx=quic_create(&u->user); CHECK(ctx);
        uint32_t output[32]={0}; uint8_t pixels[8]={0};
        u->fail_io=which==0?failure:0; u->fail_lines=which==1?failure:0;
        if (!setjmp(u->jump)) {
            (void)quic_encode(ctx,QUIC_IMAGE_TYPE_RGBA,1,2,pixels,1,4,output,which==0?1:32);
            CHECK(0);
        }
        CHECK(u->errors==1); quic_destroy(ctx); CHECK(u->live==0); free(u);
    }
    CHECK(quic_create(NULL)==NULL); quic_destroy(NULL);
    for (unsigned field=0;field<7;field++) {
        User *u=make_user();
        switch (field) {
        case 0:u->user.error=NULL;break; case 1:u->user.warn=NULL;break;
        case 2:u->user.info=NULL;break; case 3:u->user.malloc=NULL;break;
        case 4:u->user.free=NULL;break; case 5:u->user.more_space=NULL;break;
        case 6:u->user.more_lines=NULL;break;
        }
        CHECK(quic_create(&u->user)==NULL); CHECK(u->live==0); free(u);
    }
}
int main(int argc,char **argv) {
    CHECK(argc==2);
    unsigned cases=success_cases(argv[1]);
    failure_cases();
    printf("%u C consumer pixel/guard cases, allocation and longjmp checks passed\n",cases);
    return 0;
}
