/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


/*----------------------------------------------------------------------------80
Spectral heat current (SHC) calculations as described in:
[1] Z. Fan, et al. Thermal conductivity decomposition in two-dimensional 
materials: Application to graphene. Phys. Rev. B 95, 144309 (2017).
Written by Zheyong Fan and Alexander J. Gabourie.
------------------------------------------------------------------------------*/


#include "shc.cuh"
#include "atom.cuh"
#include "warp_reduce.cuh"
#include "error.cuh"

typedef unsigned long long uint64;
#define FILE_NAME_LENGTH      200


//build the look-up table used for recording force and velocity data
void SHC::build_fv_table
(
    Atom* atom, int* NN, int* NL,
    int *cpu_a_map, int* cpu_b_map, int* cpu_fv_index
)
{
    number_of_sections = 1;
    number_of_pairs = 0;
    for (int n1 = 0; n1 < atom->N; ++n1)
    {
        if (cpu_a_map[n1] != -1)
        {
            // need loop to initialize all fv_table elements to -1
            for (int n2 = 0; n2 <  atom->N; ++n2)
            {
                if (cpu_b_map[n2] != -1)
                {
                    cpu_fv_index[cpu_a_map[n1] * count_b + cpu_b_map[n2]] = -1;
                }
            }
            // Now set neighbors to correct value
            for (int i1 = 0; i1 < NN[n1]; ++i1)
            {
                int n2 = NL[n1 + i1 * atom->N];
                if (cpu_b_map[n2] != -1)
                {
                    cpu_fv_index[cpu_a_map[n1] * count_b + cpu_b_map[n2]] =
                        number_of_pairs++;
                }
            }
        }
    }
}


// allocate memory and initialize for calculating SHC
void SHC::preprocess(Atom *atom)
{
    if (!compute) return;
    //build map from N atoms to A and B labeled atoms
    count_a = 0; count_b = 0;
    int* cpu_a_map;
    int* cpu_b_map;
    MY_MALLOC(cpu_a_map, int, atom->N);
    MY_MALLOC(cpu_b_map, int, atom->N);
    for (int n = 0; n < atom->N; n++)
    {
        cpu_a_map[n] = -1;
        cpu_b_map[n] = -1;
        if (atom->group[0].cpu_label[n] == block_A)
        {     
            cpu_a_map[n] = count_a++;
        }
        else if (atom->group[0].cpu_label[n] == block_B)
        {
            cpu_b_map[n] = count_b++;
        }
    }

    int* NN; MY_MALLOC(NN, int, atom->N);
    int* NL; MY_MALLOC(NL, int, atom->N * atom->neighbor.MN);
    CHECK(cudaMemcpy(NN, atom->NN, sizeof(int) * atom->N,
        cudaMemcpyDeviceToHost));
    CHECK(cudaMemcpy(NL, atom->NL, sizeof(int) * atom->N * atom->neighbor.MN,
        cudaMemcpyDeviceToHost));

    int* cpu_fv_index;
    MY_MALLOC(cpu_fv_index, int, count_a * count_b);
    build_fv_table(atom, NN, NL, cpu_a_map, cpu_b_map, cpu_fv_index);

    MY_FREE(NN);
    MY_FREE(NL);

    // there are 12 data for each pair
    uint64 num1 = number_of_pairs * 12;
    uint64 num2 = num1 * M;
    CHECK(cudaMalloc((void**)&a_map, sizeof(int) * atom->N));
    CHECK(cudaMalloc((void**)&b_map, sizeof(int) * atom->N));
    CHECK(cudaMalloc((void**)&fv_index, sizeof(int) * count_a*count_b));
    CHECK(cudaMalloc((void**)&fv,       sizeof(real) * num1));
    CHECK(cudaMalloc((void**)&fv_all,   sizeof(real) * num2));
    CHECK(cudaMemcpy(fv_index, cpu_fv_index,
        sizeof(int) * count_a * count_b, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(a_map, cpu_a_map,
        sizeof(int) * atom->N, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(b_map, cpu_b_map,
        sizeof(int) * atom->N, cudaMemcpyHostToDevice));
    MY_FREE(cpu_fv_index);
    MY_FREE(cpu_a_map);
    MY_FREE(cpu_b_map);
}


static __global__ void gpu_find_k_time
(
    int Nc, int Nd, int M, int number_of_sections, int number_of_pairs, 
    real *g_fv_all, real *g_k_time_i, real *g_k_time_o
)
{
    //<<<Nc, 128>>>
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (M - 1) / 128 + 1;

    __shared__ real s_k_time_i[128];
    __shared__ real s_k_time_o[128];
    s_k_time_i[tid] = ZERO;
    s_k_time_o[tid] = ZERO;

    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int m = tid + patch * 128;
        if (m < M)
        {
            int index_0 = (m +   0) * number_of_pairs * 12;
            int index_t = (m + bid) * number_of_pairs * 12;

            for (uint64 np = 0; np < number_of_pairs; np++) // pairs
            {
                real f12x = g_fv_all[index_0 + np * 12 + 0];
                real f12y = g_fv_all[index_0 + np * 12 + 1];
                real f12z = g_fv_all[index_0 + np * 12 + 2];
                real f21x = g_fv_all[index_0 + np * 12 + 3];
                real f21y = g_fv_all[index_0 + np * 12 + 4];
                real f21z = g_fv_all[index_0 + np * 12 + 5];
                real  v1x = g_fv_all[index_t + np * 12 + 6];
                real  v1y = g_fv_all[index_t + np * 12 + 7];
                real  v1z = g_fv_all[index_t + np * 12 + 8];
                real  v2x = g_fv_all[index_t + np * 12 + 9];
                real  v2y = g_fv_all[index_t + np * 12 + 10];
                real  v2z = g_fv_all[index_t + np * 12 + 11];
                real f_dot_v_x = f12x * v2x - f21x * v1x;
                real f_dot_v_y = f12y * v2y - f21y * v1y;
                real f_dot_v_z = f12z * v2z - f21z * v1z;

                s_k_time_i[tid] -= f_dot_v_x + f_dot_v_y;
                s_k_time_o[tid] -= f_dot_v_z;
            }
        }
    }
    __syncthreads();

    if (tid < 64)
    {
        s_k_time_i[tid] += s_k_time_i[tid + 64];
        s_k_time_o[tid] += s_k_time_o[tid + 64];
    }
    __syncthreads();

    if (tid < 32)
    {
        warp_reduce(s_k_time_i, tid);
        warp_reduce(s_k_time_o, tid);
    }

    if (tid == 0)
    {
        g_k_time_i[bid] = s_k_time_i[0] / (number_of_sections * M);
        g_k_time_o[bid] = s_k_time_o[0] / (number_of_sections * M);
    }
}


// calculate the correlation function K(t)
void SHC::find_k_time(char *input_dir, Atom *atom)
{
    // allocate memory for K(t)
    real *k_time_i;
    real *k_time_o;
    MY_MALLOC(k_time_i, real, Nc);
    MY_MALLOC(k_time_o, real, Nc);

    // calculate K(t)
    real *g_k_time_i;
    real *g_k_time_o;
    CHECK(cudaMalloc((void**)&g_k_time_i, sizeof(real) * Nc));
    CHECK(cudaMalloc((void**)&g_k_time_o, sizeof(real) * Nc));
    gpu_find_k_time<<<Nc, 128>>>
    (
        Nc, M, M-Nc, number_of_sections, number_of_pairs, 
        fv_all, g_k_time_i, g_k_time_o
    );
    CUDA_CHECK_KERNEL

    CHECK(cudaMemcpy(k_time_i, g_k_time_i, 
        sizeof(real) * Nc, cudaMemcpyDeviceToHost));
    CHECK(cudaMemcpy(k_time_o, g_k_time_o, 
        sizeof(real) * Nc, cudaMemcpyDeviceToHost));
    CHECK(cudaFree(g_k_time_i));
    CHECK(cudaFree(g_k_time_o)); 

    // output the results
    char file_shc[FILE_NAME_LENGTH];
    strcpy(file_shc, input_dir);
    strcat(file_shc, "/shc.out");
    FILE *fid = my_fopen(file_shc, "a");
    for (int nc = 0; nc < Nc; nc++)
    {
        fprintf(fid, "%25.15e%25.15e\n", k_time_i[nc], k_time_o[nc]);
    }
    fflush(fid);
    fclose(fid);

    // free memory
    MY_FREE(k_time_i);
    MY_FREE(k_time_o);
}


void SHC::process(int step, char *input_dir, Atom *atom)
{
    if (!compute) return;
    uint64 step_ref = sample_interval * M;
    uint64 fv_size = number_of_pairs * 12;
    uint64 fv_memo = fv_size * sizeof(real);
        
    // sample fv data every "sample_interval" steps
    if ((step + 1) % sample_interval == 0)
    {
        uint64 offset = ((step-(step/step_ref)*step_ref+1)/sample_interval-1) 
            * fv_size;
        CHECK(cudaMemcpy(fv_all + offset, 
            fv, fv_memo, cudaMemcpyDeviceToDevice));
    }

    // calculate the correlation function every "sample_interval * M" steps
    if ((step + 1) % step_ref == 0) { find_k_time(input_dir, atom); }
}


void SHC::postprocess(void)
{
    if (!compute) return;
    CHECK(cudaFree(fv_index));
    CHECK(cudaFree(a_map));
    CHECK(cudaFree(b_map));
    CHECK(cudaFree(fv));
    CHECK(cudaFree(fv_all));
}


