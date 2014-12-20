#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#define PAGESIZE 32

#define PHYSICAL_MEM_SIZE 32768

#define STORAGE_SIZE 131072

#define DATAFILE "./data.bin"
#define OUTFILE "./snapshot.bin"

#define MASK 32767
#define TIME_MAX 4294967295
#define MEMORY_SEGMENT 32768

#define __LOCK(); for(int j = 0; j < 4; j++) {if(threadIdx.x == j) {
#define __UNLOCK(); }__syncthreads(); }
#define __GET_BASE() j*MEMORY_SEGMENT
//C's macro is soooo bloody ugly comparing to ruby & lisp...

typedef unsigned char uchar;
typedef uint32_t u32;

//
__device__ __managed__ int PAGE_ENTRIES = PHYSICAL_MEM_SIZE/PAGESIZE;
//count the pagefault times
__device__ __managed__ int PAGEFAULT = 0;

//secondary memory
__device__ __managed__ uchar storage[STORAGE_SIZE];

//data input & output
__device__ __managed__ uchar result[STORAGE_SIZE];
__device__ __managed__ uchar input[STORAGE_SIZE];

//page table
extern __shared__ u32 pt[];

/******BLABLABLA~~****/
int load_binaryFile(const char *filename, uchar *a, int max_size) {
	FILE *fp = fopen(filename, "rb");
	int i = 0;
	while(!feof(fp) && i < max_size) {
		fread(a+i, sizeof(uchar), 1, fp);
		i++;
	}
	return i;
}

void write_binaryFIle(const char *filename, uchar *a, int size) {
	FILE *fp = fopen(filename, "wb+");
	fwrite(a, sizeof(uchar), size, fp);
}

__device__ u32 lru() {
	int offset = threadIdx.x*PAGE_ENTRIES/4;
	/****
	  實作queue來解決lru並無法解決效能瓶頸，因為最大的問題卡在find的O(n)
	  要改善find的效能，應實作binary search tree，but...
	 ***/
	u32 min = TIME_MAX;
	int victim_index = 0;
	for(int i = 0; i < PAGE_ENTRIES/4; i++) {
		if(pt[PAGE_ENTRIES+i+offset] == 0) return i+offset;
		else {
			if(pt[PAGE_ENTRIES+i+offset] < min) {
				min = pt[PAGE_ENTRIES+i+offset];
				victim_index = i;
			}
		}
	}
	return victim_index+offset;
}
__device__ int find(u32 p) {
	int offset = threadIdx.x*PAGE_ENTRIES/4;
	for(int i = 0; i < PAGE_ENTRIES/4; i++) {
		u32 cur_p= (pt[i+offset]>>15);
		if(cur_p == p) {
			if(pt[PAGE_ENTRIES+i+offset] == 0) return -1;
			else return i+offset;
		}
	}
	return -1;
}
__device__ u32 paging(uchar *data, u32 p, u32 offset) {
	if(pt[PAGE_ENTRIES*2] < TIME_MAX) pt[PAGE_ENTRIES*2]++;
	int p_index = find(p); //should only return the page that is of same id
	if(p_index == -1) {  //page fault!!
		PAGEFAULT++;
		u32 victim_index = lru(); //should only return the page that is of same id, since I can't see another thread's data[]
		u32 frame = pt[victim_index]&MASK;
		u32 victim_p = (pt[victim_index] >> 15);
		for(int i = 0; i < 32; i++) {
			storage[threadIdx.x*MEMORY_SEGMENT+victim_p*32+i] = data[frame+i];
			data[frame+i] = storage[threadIdx.x*MEMORY_SEGMENT+p*32+i];
		}
		pt[victim_index] = ((p<<15)|frame);
		pt[PAGE_ENTRIES+victim_index] = pt[PAGE_ENTRIES*2];
		return frame + offset;
	}
	else {
		pt[PAGE_ENTRIES+p_index] = pt[PAGE_ENTRIES*2];
		return (pt[p_index]&MASK) + offset;
	}
}
__device__ void init_pageTable(int pt_entries) {
	pt[PAGE_ENTRIES*2] = 0;
	for(int i = 0; i < PAGE_ENTRIES; i++) {
		pt[i] = (i*32)%(PAGE_ENTRIES/4);
		pt[PAGE_ENTRIES+i] = 0;
	}
}
/*********************/

__device__ uchar Gread(uchar *data, u32 addr) {
	u32 p = addr/PAGESIZE;
	u32 offset = addr%PAGESIZE;

	addr = paging(data, p, offset);
	return data[addr];
}

__device__ void Gwrite(uchar *data, u32 addr, uchar value) {
	u32 p = addr/PAGESIZE;
	u32 offset = addr%PAGESIZE;

	addr = paging(data, p, offset);
	data[addr] = value;
}

__device__ void snapshot(uchar *result, uchar *data, int offset, int input_size) {
	for(int i = 0; i < input_size; i++) {
		result[i] = Gread(data, i + offset);
		printf("id=%d, i=%d (%d, %d)\n", threadIdx.x, i, storage[i+MEMORY_SEGMENT*threadIdx.x], result[i]);
	}
}

__global__ void mykernel(int input_size) {
	__shared__ uchar data[32768];
	//get page table entries
	int pt_entries = PHYSICAL_MEM_SIZE/PAGESIZE;

	printf("my id = %d\n", threadIdx.x);
	//B4 1st Gwrite or Gread
	if(threadIdx.x == 0) init_pageTable(pt_entries);

	//####Gwrite/Gread code section start####
	__LOCK();
	for(int i = 0; i < input_size; i++) Gwrite(data, i, input[i+__GET_BASE()]);
	__UNLOCK();
	for(int i = input_size-1; i >= input_size-10; i--) {
		__LOCK();
		int value = Gread(data, i);
		__UNLOCK();
	}

	//the last line of Gwrite/Gread code section should be snapshot()
	__LOCK();
	snapshot(result+__GET_BASE(), data, 0, input_size);
	__UNLOCK();
	//####Gwrite/Gread code section end####
}

int main() {
	int input_size = load_binaryFile(DATAFILE, input, STORAGE_SIZE);

	cudaSetDevice(3);
	mykernel<<<1, 4, 16384>>>(input_size/4);
	cudaDeviceSynchronize();
	cudaDeviceReset();

	printf("pagefault times = %d\n", PAGEFAULT);
	write_binaryFIle(OUTFILE, result, input_size);

	return 0;
}