#include <stdio.h>
#include <vector>
#include <functional>
#include <chrono>
using namespace std::chrono;

#include <helper_functions.h>  // helper for shared functions common to CUDA Samples
#include <helper_cuda.h>       // helper functions for CUDA error checking and initialization
#include <cuda_profiler_api.h >
#include <cuda.h>

#include "wall_clock_timer.h"  // StartTimer() and GetTimer()
#include "cuda_common.h"       // my own helper functions
#include "sais.c"              // OpenBWT implementation

const int ALPHABET_SIZE = 256;
const int WARP_SIZE = 32;
typedef unsigned char byte;

#include "qlfc-cpu.cpp"


// Parameters
const int NUM_WARPS = 6;
const int BUFSIZE = 128*1024*1024;
const int CHUNK = 4*1024;
#define SYNC_WARP __threadfence_block  /* alternatively, __syncthreads or, better, __threadfence_warp */



template <int CHUNK,  int NUM_THREADS = WARP_SIZE,  int MTF_SYMBOLS = ALPHABET_SIZE>
__global__ void mtf_thread (const byte* inbuf,  byte* outbuf,  int inbytes,  int chunk)
{
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int tid = threadIdx.x;

    if (idx*CHUNK >= inbytes)  return;
    inbuf  += idx*CHUNK;
    outbuf += idx*CHUNK;
    auto cur  = *inbuf++;
    auto next = *inbuf++;

    volatile __shared__  byte mtf0 [MTF_SYMBOLS*NUM_THREADS];
    auto mtf = mtf0 + 4*tid;
    for (int k=0; k<MTF_SYMBOLS; k+=4)
    {
        *(unsigned*)(mtf+k*NUM_THREADS)  =  k + ((k+1)<<8) + ((k+2)<<16) + ((k+3)<<24);
    }


    int i = 0,  k = 0;
    auto old  = mtf[0];

    for(;;)
    {
        if (cur != old  &&  !(MTF_SYMBOLS < ALPHABET_SIZE  &&  k >= MTF_SYMBOLS-1)) {
            k++;
            auto index = (k&252)*NUM_THREADS+(k&3);
            auto next = mtf[index];
            mtf[index] = old;
            old = next;
        } else {
            mtf[0] = cur;
            *outbuf++ = k;
            if (++i >= CHUNK)  return;
            old = cur;
            cur = next;
            next = *inbuf++;
            k = 0;
        }
    }
}



template <int CHUNK,  int NUM_THREADS = WARP_SIZE,  int MTF_SYMBOLS = ALPHABET_SIZE>
__global__ void mtf_thread_by4 (const byte* inbuf,  byte* outbuf,  int inbytes,  int chunk)
{
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int tid = threadIdx.x;

    if (idx*CHUNK >= inbytes)  return;
    inbuf  += idx*CHUNK;
    outbuf += idx*CHUNK;
    auto cur  = *inbuf++;
    auto next = *inbuf++;

    volatile __shared__  byte mtf0 [MTF_SYMBOLS*NUM_THREADS];
    auto mtf = mtf0 + 4*tid;
    for (int k=0; k<MTF_SYMBOLS; k+=4)
    {
        *(unsigned*)(mtf+k*NUM_THREADS)  =  k + ((k+1)<<8) + ((k+2)<<16) + ((k+3)<<24);
    }


    int i = 0,  k = 0;
    auto mtf_k = mtf;
    auto old = cur;

    for(;;)
    {
        #pragma unroll
        for (int x=0; x<4; x++)
        {
            auto next = mtf_k[x];
            mtf_k[x] = old;
            old = next;
            if (cur==old)  goto found;
            k++;
        }
        mtf_k += 4*NUM_THREADS;
        if (MTF_SYMBOLS == ALPHABET_SIZE  ||  k < MTF_SYMBOLS)
            continue;

found:
        *outbuf++ = k;
        if (++i >= CHUNK)  return;

        old = cur = next;
        next = *inbuf++;

        mtf_k = mtf;
        k = 0;
    }
}



template <int NUM_WARPS,  int CHUNK,  typename MTF_WORD = unsigned>
__global__ void mtf_scalar (const byte* __restrict__ inbuf,  byte* __restrict__ outbuf,  int inbytes,  int chunk)
{
    const int idx = (blockIdx.x * blockDim.x + threadIdx.x) / WARP_SIZE;
    const int tid = (blockIdx.x * blockDim.x + threadIdx.x) % WARP_SIZE;
    const int warp_id = threadIdx.x / WARP_SIZE;

    if (idx*CHUNK >= inbytes)  return;
    inbuf  += idx*chunk;
    outbuf += idx*chunk;

    __shared__  MTF_WORD mtf0 [ALPHABET_SIZE*NUM_WARPS];
    auto mtf = mtf0 + ALPHABET_SIZE*warp_id;
    for (int i=0; i<ALPHABET_SIZE; i+=WARP_SIZE)
    {
        mtf[i+tid] = i+tid;
    }
    __syncthreads();


    for (int i=0; ; i++)
    {
        auto next = inbuf[i];

        #pragma unroll 4
        for ( ; i<CHUNK; i++)
        {
            auto cur = next;
            auto old = mtf[tid];

            unsigned n = __ballot (cur==old);
            if (n==0)  goto deeper;
            next = inbuf[i+1];

            auto minbit = __ffs(n) - 1;
            if (tid < minbit)  mtf[tid+1] = old;
            if (tid==0)        outbuf[i] = minbit;
            mtf[0] = cur;
            __syncthreads();
        }
        return;

    deeper:
        {
            auto cur = next;
            auto old = mtf[tid];

            int k;  unsigned n;
            #pragma unroll
            for (k=WARP_SIZE; k<ALPHABET_SIZE; k+=WARP_SIZE)
            {
                auto next = mtf[k+tid];
                mtf[k+tid+1-WARP_SIZE] = old;
                old = next;

                n = __ballot (cur==old);
                if (n) break;
                __syncthreads();
            }

            auto minbit = __ffs(n) - 1;
            if (tid < minbit)  mtf[k+tid+1] = old;
            if (tid==0)        outbuf[i] = k+minbit;
            mtf[0] = cur;
            __syncthreads();
        }
    }
}



template <int NUM_WARPS,  int CHUNK,  typename MTF_WORD = unsigned>
__global__ void mtf_2symbols (const byte* __restrict__ inbuf,  byte* __restrict__ outbuf,  int inbytes,  int chunk)
{
    const int idx = (blockIdx.x * blockDim.x + threadIdx.x) / WARP_SIZE;
    const int tid = (blockIdx.x * blockDim.x + threadIdx.x) % WARP_SIZE;
    const int warp_id = threadIdx.x / WARP_SIZE;

    if (idx*CHUNK >= inbytes)  return;
    inbuf  += idx*chunk;
    outbuf += idx*chunk;

    __shared__  MTF_WORD mtf0 [ALPHABET_SIZE*NUM_WARPS];
    auto mtf = mtf0 + ALPHABET_SIZE*warp_id;
    for (int i=0; i<ALPHABET_SIZE; i+=WARP_SIZE)
    {
        mtf[i+tid] = i+tid;
    }
    SYNC_WARP();


    for (int i=0; ; i+=2)
    {
        auto next1 = inbuf[i];
        auto next2 = inbuf[i+1];
        #pragma unroll 8
        for ( ; i<CHUNK; i+=2)
        {
            auto cur1 = next1;
            auto cur2 = next2;
            auto old = mtf[tid];
            next1 = inbuf[i+2];
            next2 = inbuf[i+3];

            unsigned n1 = __ballot (cur1==old);
            unsigned n2 = __ballot (cur2==old);
            if (n1==0 || n2==0)  goto deeper;

            auto minbit1 = __ffs(n1) - 1;
            if (tid < minbit1)  mtf[tid+1] = old;
            if (tid==0)         outbuf[i] = minbit1;
            mtf[0] = cur1;
            SYNC_WARP();

            auto minbit2 = __ffs(n2) - 1;
            if (minbit2 < minbit1)  minbit2++;     // the second symbol was shifted one more position down by the first one
            if (cur1==cur2)         minbit2 = 0;   // not required after RLE
            if (tid < minbit2)  mtf[tid+1] = mtf[tid];
            if (tid==0)         outbuf[i+1] = minbit2;
            mtf[0] = cur2;
            SYNC_WARP();
        }
        return;

    deeper:
        #pragma unroll
        for (int add=0; add<2; add++)
        {
            auto cur = inbuf[i+add];
            auto old = mtf[tid];

            int k;  unsigned n;
            #pragma unroll
            for (k=0; k<ALPHABET_SIZE; k+=WARP_SIZE)
            {
                n = __ballot (cur==old);
                if (n) break;
                auto next = mtf[k+WARP_SIZE+tid];
                mtf[k+tid+1] = old;
                old = next;
                SYNC_WARP();
            }

            auto minbit = __ffs(n) - 1;
            if (tid < minbit)  mtf[k+tid+1] = old;
            if (tid==0)        outbuf[i+add] = k+minbit;
            mtf[0] = cur;
            SYNC_WARP();
        }
    }
}



template <int NUM_WARPS,  int CHUNK,  typename MTF_WORD = unsigned>
__global__ void mtf_2buffers (const byte* __restrict__ inbuf,  byte* __restrict__ outbuf,  int inbytes,  int chunk)
{
    const int idx = (blockIdx.x * blockDim.x + threadIdx.x) / WARP_SIZE;
    const int tid = (blockIdx.x * blockDim.x + threadIdx.x) % WARP_SIZE;
    const int warp_id = threadIdx.x / WARP_SIZE;
//printf("%d ", warp_id);

    if (idx*CHUNK*2 >= inbytes)  return;
    inbuf  += idx*chunk*2;
    outbuf += idx*chunk*2;

    auto inbuf1  = inbuf,  inbuf2  = inbuf+chunk;
    auto outbuf1 = outbuf, outbuf2 = outbuf+chunk;

//    __shared__  byte in[128], out[128];
    __shared__  MTF_WORD mtf0 [ALPHABET_SIZE*NUM_WARPS*2];
    auto mtf1 = mtf0 + ALPHABET_SIZE*warp_id*2;
    auto mtf2 = mtf1 + ALPHABET_SIZE;
    for (int i=0; i<ALPHABET_SIZE; i+=WARP_SIZE)
    {
        mtf1[i+tid] = i+tid;
        mtf2[i+tid] = i+tid;
    }
    SYNC_WARP();


    for (int i=0; ; i++)
    {
        unsigned n1, n2;
        auto next1 = inbuf1[i];
        auto next2 = inbuf2[i];
        #pragma unroll 4
        for ( ; i<CHUNK; i++)
        {
            auto cur1 = next1;
            auto old1 = mtf1[tid];
            next1 = inbuf1[i+1];

            auto cur2 = next2;
            auto old2 = mtf2[tid];
            next2 = inbuf2[i+1];

            n1 = __ballot (cur1==old1);
            n2 = __ballot (cur2==old2);
            if (n1==0 || n2==0)  goto deeper;

            auto minbit = __ffs(n1) - 1;
            if (tid < minbit)  mtf1[tid+1] = old1;
            if (tid==0)        outbuf1[i] = minbit;
            mtf1[0] = cur1;

            minbit = __ffs(n2) - 1;
            if (tid < minbit)  mtf2[tid+1] = old2;
            if (tid==0)        outbuf2[i] = minbit;
            mtf2[0] = cur2;
            SYNC_WARP();
        }
        return;

    deeper:
        {
            auto cur = next1;
            auto old = mtf1[tid];

            int k;  unsigned n;
            #pragma unroll
            for (k=0; k<ALPHABET_SIZE; k+=WARP_SIZE)
            {
                n = __ballot (cur==old);
                if (n) break;
                auto next = mtf1[k+WARP_SIZE+tid];
                mtf1[k+tid+1] = old;
                old = next;
                SYNC_WARP();
            }

            auto minbit = __ffs(n) - 1;
            if (tid < minbit)  mtf1[k+tid+1] = old;
            if (tid==0)        outbuf1[i] = k+minbit;
            mtf1[0] = cur;
        }

        {
            auto cur = next2;
            auto old = mtf2[tid];

            int k;  unsigned n;
            #pragma unroll
            for (k=0; k<ALPHABET_SIZE; k+=WARP_SIZE)
            {
                n = __ballot (cur==old);
                if (n) break;
                auto next = mtf2[k+WARP_SIZE+tid];
                mtf2[k+tid+1] = old;
                old = next;
                SYNC_WARP();
            }

            auto minbit = __ffs(n) - 1;
            if (tid < minbit)  mtf2[k+tid+1] = old;
            if (tid==0)        outbuf2[i] = k+minbit;
            mtf2[0] = cur;
            SYNC_WARP();
        }
    }
}



// In-place RLE transformation (run lengths are dropped!)
int rle (byte* buf, int size)
{
    int c = -1, run=0;
    auto out = buf;
    for (size_t i = 0; i < size; i++)
    {
        buf[i]==c?  run++  :  (run=1, c = *out++ = buf[i]);
    }
    return out-buf;
}



int main (int argc, char **argv)
{
    bool apply_bwt = true;
    if (argv[1] && strcmp(argv[1],"-nobwt")==0) {
        apply_bwt = false;
        argv++, argc--;
    }

    bool apply_rle = true;
    if (argv[1] && strcmp(argv[1],"-norle")==0) {
        apply_rle = false;
        argv++, argc--;
    }

    if (!(argc==2 || argc==4)) {
        printf ("Usage: mtf [options] infile [N outfile]\n"
                "  N is the number of function those output will be saved\n"
                "  -nobwt   skip BWT transformation\n"
                "  -norle   skip RLE transformation\n"
                );
        return 0;
    }

    unsigned char* d_inbuf;
    unsigned char* d_outbuf;
    checkCudaErrors( cudaMalloc((void**)(&d_inbuf),  BUFSIZE+CHUNK*2));  // up to CHUNK*2 extra bytes may be processed
    checkCudaErrors( cudaMalloc((void**)(&d_outbuf), BUFSIZE+CHUNK*2));

    cudaEvent_t start, stop;
    checkCudaErrors( cudaEventCreate(&start));
    checkCudaErrors( cudaEventCreate(&stop));

    unsigned char* inbuf  = new unsigned char[BUFSIZE];
    unsigned char* outbuf = new unsigned char[BUFSIZE];
    int*      bwt_tempbuf = new int          [BUFSIZE];

    double insize = 0,  outsize = 0,  duration[100] = {0};  char *mtf_name[100] = {"cpu (1 thread)"};

    FILE* infile  = fopen (argv[1], "rb");
    FILE* outfile = fopen (argv[2]? argv[3] : "nul", "wb");
    if (!infile) {
        printf ("Can't open infile %s\n", argv[1]);
        return 1;
    }
    if (!outfile) {
        printf ("Can't open outfile %s\n", argv[3]);
        return 1;
    }
    int save_num  =  argc==4? atoi(argv[2]) : 0;
    DisplayCudaDevice();


    for (int inbytes; !!(inbytes = fread(inbuf,1,BUFSIZE,infile)); )
    {
        if (apply_bwt) {
            auto bwt_errcode  =  sais_bwt (inbuf, outbuf, bwt_tempbuf, inbytes);
            if (bwt_errcode < 0) {
                printf ("BWT failed with errcode %d\n", bwt_errcode);
                return 2;
            }
            memcpy (inbuf, outbuf, inbytes);
        }

        StartTimer();
            unsigned char MTFTable[ALPHABET_SIZE];
            auto ptr = qlfc (inbuf, outbuf, inbytes, MTFTable);
            auto outbytes = outbuf+inbytes - ptr;
        duration[0] += GetTimer();
        int num = 1;

        insize += inbytes;
        if (apply_rle)
            inbytes = rle(inbuf,inbytes);

        checkCudaErrors( cudaMemcpy (d_inbuf, inbuf, inbytes, cudaMemcpyHostToDevice));
        checkCudaErrors( cudaDeviceSynchronize());

        auto time_run = [&] (char *name, std::function<void(void)> f) {
            mtf_name[num] = name;
            checkCudaErrors( cudaEventRecord (start, nullptr));
            f();
            checkCudaErrors( cudaEventRecord (stop, nullptr));
            checkCudaErrors( cudaDeviceSynchronize());

            if (num == save_num) {
                checkCudaErrors( cudaMemcpy (outbuf, d_outbuf, inbytes, cudaMemcpyDeviceToHost));
                checkCudaErrors( cudaDeviceSynchronize());
                ptr = outbuf;
                outbytes = inbytes;
            }

            float start_stop;
            checkCudaErrors( cudaEventElapsedTime (&start_stop, start, stop));
            duration[num] += start_stop;
            num++;
        };

        time_run ("mtf_scalar        ", [&] {mtf_scalar    <NUM_WARPS,CHUNK>       <<<(inbytes-1)/(CHUNK*NUM_WARPS)+1,   NUM_WARPS*WARP_SIZE>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_2symbols      ", [&] {mtf_2symbols  <NUM_WARPS,CHUNK>       <<<(inbytes-1)/(CHUNK*NUM_WARPS)+1,   NUM_WARPS*WARP_SIZE>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_2buffers      ", [&] {mtf_2buffers  <NUM_WARPS,CHUNK>       <<<(inbytes-1)/(CHUNK*NUM_WARPS*2)+1, NUM_WARPS*WARP_SIZE>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});

        time_run ("mtf_thread        ", [&] {mtf_thread    <CHUNK>                 <<<(inbytes-1)/(CHUNK*WARP_SIZE)+1,             WARP_SIZE>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread_by4    ", [&] {mtf_thread_by4<CHUNK>                 <<<(inbytes-1)/(CHUNK*WARP_SIZE)+1,             WARP_SIZE>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});

        const int NUM_THREADS = 1*WARP_SIZE;
        time_run ("mtf_thread<8>     ", [&] {mtf_thread    <CHUNK,NUM_THREADS,8>   <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread<16>    ", [&] {mtf_thread    <CHUNK,NUM_THREADS,16>  <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread<32>    ", [&] {mtf_thread    <CHUNK,NUM_THREADS,32>  <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread<64>    ", [&] {mtf_thread    <CHUNK,NUM_THREADS,64>  <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});

        time_run ("mtf_thread_by4<8> ", [&] {mtf_thread_by4<CHUNK,NUM_THREADS,8>   <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread_by4<16>", [&] {mtf_thread_by4<CHUNK,NUM_THREADS,16>  <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread_by4<32>", [&] {mtf_thread_by4<CHUNK,NUM_THREADS,32>  <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});
        time_run ("mtf_thread_by4<64>", [&] {mtf_thread_by4<CHUNK,NUM_THREADS,64>  <<<(inbytes-1)/(CHUNK*NUM_THREADS)+1,         NUM_THREADS>>> (d_inbuf, d_outbuf, inbytes, CHUNK);});

        fwrite (ptr, 1, outbytes, outfile);
        outsize += outbytes;
    }

    printf("rle: %.0lf => %.0lf (%.2lf%%)\n", insize, outsize, outsize*100.0/insize);
    for (int i=0; i<sizeof(duration)/sizeof(*duration); i++)
        if (duration[i])
            printf("[%2d] %-*s:  %.6lf ms,  %.6lf MiB/s\n", i, strlen(mtf_name[2]), mtf_name[i], duration[i], ((1000/duration[i]) * insize) / (1 << 20));
    fclose(infile);
    fclose(outfile);
    cudaProfilerStop();
    return 0;
}
