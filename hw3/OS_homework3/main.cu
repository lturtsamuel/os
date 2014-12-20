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
	/****
	  實作queue來解決lru並無法解決效能瓶頸，因為最大的問題卡在find的O(n)
	  要改善find的效能，應實作binary search tree，but...
	 ***/
	u32 min = TIME_MAX;
	int victim_index = 0;
	for(int i = 0; i < PAGE_ENTRIES; i++) {
		if(pt[PAGE_ENTRIES+i] == 0) return i;
		else {
			if(pt[PAGE_ENTRIES+i] < min) {
				min = pt[PAGE_ENTRIES+i];
				victim_index = i;
			}
		}
	}
	return victim_index;
}
__device__ int find(u32 p) {
	for(int i = 0; i < PAGE_ENTRIES; i++) {
		u32 cur_p = (pt[i]>>15);
		if(cur_p == p) {
			if(pt[PAGE_ENTRIES+i] == 0) return -1;
			else return i;
		}
	}
	return -1;
}
__device__ u32 paging(uchar *data, u32 p, u32 offset) {
	if(pt[PAGE_ENTRIES*2] < TIME_MAX) pt[PAGE_ENTRIES*2]++;
	int p_index = find(p);
	if(p_index == -1) {  //page fault!!
		PAGEFAULT++;
		u32 victim_index = lru();
		u32 frame = pt[victim_index]&MASK;
		u32 victim_p = (pt[victim_index] >> 15);
		for(int i = 0; i < 32; i++) {
			storage[victim_p*32+i] = data[frame+i];
			data[frame+i] = storage[p*32+i];
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
		pt[i] = i*32;
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
	}
}

__global__ void mykernel(int input_size) {
	__shared__ uchar data[PHYSICAL_MEM_SIZE];
	//get page table entries
	int pt_entries = PHYSICAL_MEM_SIZE/PAGESIZE;
	//B4 1st Gwrite or Gread
	init_pageTable(pt_entries);

	//####Gwrite/Gread code section start####
	for(int i = 0; i < input_size; i++) Gwrite(data, i, input[i]);
	for(int i = input_size-1; i >= input_size-10; i--) int value = Gread(data, i);

	//the last line of Gwrite/Gread code section should be snapshot()
	snapshot(result, data, 0, input_size);
	//####Gwrite/Gread code section end####
}

int main() {
	int input_size = load_binaryFile(DATAFILE, input, STORAGE_SIZE);

	cudaSetDevice(3);
	mykernel<<<1, 1, 16384>>>(input_size);
	cudaDeviceSynchronize();
	cudaDeviceReset();

	printf("pagefault times = %d\n", PAGEFAULT);
	write_binaryFIle(OUTFILE, result, input_size);

	return 0;
}