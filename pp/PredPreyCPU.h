/** 
 * @file
 * @brief PredPrey OpenCL CPU data structures and function headers.
 */
 

#ifndef PREDPREYCPU_H
#define PREDPREYCPU_H

#include "PredPreyCommon.h"

typedef struct pp_c_agent {
	cl_uint energy;
	cl_uint action;
	cl_uint type;
	cl_uint next;
} PPCAgent __attribute__ ((aligned (16)));


typedef struct pp_c_sim_params {
	cl_uint size_x;
	cl_uint size_y;
	cl_uint size_xy;
	cl_uint max_agents;
	cl_uint null_agent_pointer;
	cl_uint grass_restart;
	cl_uint lines_per_thread;
} PPCSimParams;

typedef struct pp_c_cell {
	cl_uint grass;
	cl_uint agent_pointer;
} PPCCell;

// Global work sizes
typedef struct pp_c_global_work_sizes {
	size_t step1;
	size_t step2;
} PPCGlobalWorkSizes;

// Local work sizes
typedef struct pp_c_local_work_sizes {
	size_t step1;
	size_t step2;
} PPCLocalWorkSizes;

// Kernels
typedef struct pp_c_kernels {
	cl_kernel step1;
	cl_kernel step2;
} PPCKernels;

// Data sizes
typedef struct pp_c_data_sizes {
	size_t stats;
	size_t matrix;
	size_t agents;
	size_t rng_seeds;
	size_t agent_params;
} PPCDataSizes;

/** @brief Get number of threads to use. */
int ppc_numthreads_get(size_t *num_threads, size_t *lines_per_thread, size_t *num_threads_sugested, size_t *num_threads_max, cl_uint cu, unsigned int num_lines, int argc, char* argv[]);

/** @brief Print information about number of threads / work-items and compute units. */
void ppc_threadinfo_print(cl_int cu, size_t num_threads, size_t lines_per_thread, size_t num_threads_sugested, size_t num_threads_max);

/** @brief Get kernel entry points. */
cl_int ppc_kernels_create(cl_program program, PPCKernels* krnls, GError** err);

/** @brief Release kernels.  */
void ppc_kernels_free(PPCKernels* krnls);

/** @brief Initialize simulation parameters in host, to be sent to kernels. */
PPCSimParams ppc_simparams_init(PPParameters params, cl_uint null_agent_pointer, size_t lines_per_thread);

/** @brief Determine buffer sizes. */
void ppc_datasizes_get(PPParameters params, PPCSimParams simParams, PPCDataSizes* dataSizes, PPCGlobalWorkSizes gws, PPCLocalWorkSizes lws, size_t num_threads);

#endif
