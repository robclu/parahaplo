#include "cuda.h"
#include "data.h"
#include "graph_internal.h"
#include "math.h"

#define BLOCK_SIZE 1024
#undef DEBUG

#ifndef NIH
    #define IH  0x00
    #define NIH 0x01
#endif

namespace haplo {

using graph_type = internal::Graph;
using data_type  = Data;

extern __shared__ size_t distance[];
extern __shared__ size_t counts[];

// ----------------------------------------------- PRINT FUNCTIONS ------------------------------------------

// Prints the edges of a node
__global__
void print_edges(data_type data, graph_type graph)
{
    if (threadIdx.y == 0 && blockIdx.x == 0) {   
        for (size_t i = 0; i < data.reads * (data.reads -1) / 2; ++i) {
            if (graph.edges[i].distance != 0.0f) {
                printf("%.4f ", graph.edges[i].distance);
                printf("%i ", graph.edges[i].f1);
                printf("%i\n", graph.edges[i].f2);
            }
        }
    } 
}

__global__
void print_haplotypes(data_type data, graph_type graph)
{
    // Haplotype from set 1
    for (size_t i = 0; i < data.snps; ++i) {
        printf("%i", graph.haplo_one[i]);
    } printf("\n");
    for (size_t i = 0; i < data.snps; ++i) {
        printf("%i", graph.haplo_two[i]);
    } printf("\n"); 
}


__device__
void print_temp_haplotypes(data_type& data, graph_type& graph)
{
    // Haplotype from set 1
    for (size_t i = 0; i < data.snps; ++i) {
        printf("%i", graph.haplo_one_temp[i]);
    } printf("\n");
    for (size_t i = 0; i < data.snps; ++i) {
        printf("%i", graph.haplo_two_temp[i]);
    } printf("\n"); 
}

__device__ 
void print_sets(graph_type& graph, const size_t elements)
{
    if (threadIdx.y == 0 && blockIdx.x == 0) {
        for (size_t i = 0; i < elements; ++i) 
            if (graph.set_one[i] == i) 
                printf("%i ", graph.set_one[i]);
        printf("\n");
        for (size_t i = 0; i < elements; ++i) 
            if (graph.set_two[i] == i)
                printf("%i ", graph.set_two[i]);
        printf("\n"); 
    }
}

__global__
void print_fragments(data_type data, graph_type graph)
{
    for (size_t i = 0; i < data.reads; ++i) {
        printf("%i ", graph.fragments[i].score);
    } printf("\n");
}

// --------------------------------------- COMPUTATION FUNCTIONS --------------------------------------------

// Finds the distances (similarity) between edges
__device__
void map_distances(data_type& data, graph_type& graph, const size_t threads)
{
    const size_t total_elems  = data.reads * (data.reads - 1) / 2;
    const size_t read_idx_one = blockIdx.x / (data.reads - 1);
    const size_t subt_elems   = (data.reads - read_idx_one) * (data.reads - read_idx_one - 1) / 2;
    const size_t read_idx_two = read_idx_one + (blockIdx.x - (total_elems - subt_elems)) + 1;
    const size_t snp_idx      = threadIdx.y;

    const auto read_info_one = data.read_info[read_idx_one];    
    const auto read_info_two = data.read_info[read_idx_two];    
    
    bool    first_valid = false , second_valid = false;
    uint8_t first_value = 0     , second_value = 0    ;

    if (read_idx_one < data.reads && read_idx_two < data.reads) {    
        // Check if each of the values is valid
        if (read_info_one.start_index() <= snp_idx && read_info_one.end_index() >= snp_idx) {
            first_valid = true;
            first_value = data.data[read_info_one.offset() + snp_idx - read_info_one.start_index()];
        }
        if (read_info_two.start_index() <= snp_idx && read_info_two.end_index() >= snp_idx) {
            second_valid = true;
            second_value = data.data[read_info_two.offset() + snp_idx - read_info_two.start_index()];
        }
        
        // Set the values for the graph edge
        graph.edges[blockIdx.x].f1 = read_idx_one;
        graph.edges[blockIdx.x].f2 = read_idx_two;
    } 
    
    // Load the distance into the shared array
    if (first_valid && second_valid) {
        if (first_value != second_value && first_value <= 1 && second_value <= 1) {
            distance[snp_idx] = 10; distance[snp_idx + threads] = 1;
        } else if (first_value != second_value && (first_value <= 1 || second_value <= 1)) {
            distance[snp_idx] = 5; distance[snp_idx + threads] = 1;
        } else if (first_value == second_value && first_value <= 1 && second_value <= 1) {
            distance[snp_idx] = 0; distance[snp_idx + threads] = 1;
        } else if (first_value == second_value & first_value > 1 && second_value > 1) {
            distance[snp_idx] = 0; distance[snp_idx + threads] = 0;
        }   
    } else if (first_valid && !second_valid && first_value <= 1) {
        distance[snp_idx] = 5; distance[snp_idx + threads] = 1;
    } else if (second_valid && !first_valid && second_value <= 1) {
        distance[snp_idx] = 5; distance[snp_idx + threads] = 1;
    } else if (!first_valid && !second_valid) {
        distance[snp_idx] = 0; distance[snp_idx + threads] = 0;
    }
    __syncthreads();    
}

__device__
void reduce_distances(data_type& data, graph_type& graph, const size_t threads) 
{
    size_t reduction_threads = threads;
    
    while (reduction_threads > 1) {
        size_t other_idx_one = threadIdx.y + (reduction_threads / 2);
        size_t other_idx_two = other_idx_one + threads;
        
        if (threadIdx.y < (reduction_threads / 2)) {                
            distance[threadIdx.y] += distance[other_idx_one];
            distance[threadIdx.y + threads] += distance[other_idx_two];
        }
        if (reduction_threads % 2 == 1) {
            // Load the extra value
            if (threadIdx.y == reduction_threads / 2) {
                distance[threadIdx.y] = distance[threadIdx.y + reduction_threads / 2];
                distance[threadIdx.y + threads] = distance[threadIdx.y + threads + reduction_threads / 2];
            }
            reduction_threads /= 2; reduction_threads += 1;
        } else reduction_threads /= 2;
        __syncthreads();
    }
    // Set the weight of the edge
    if (distance[threads] > 0 && threadIdx.y == 0) {
        graph.edges[blockIdx.x].distance = static_cast<float>(distance[0] / 10.f) /
                                           static_cast<float>(distance[threads])  + 0.5f;
    } else if (threadIdx.y == 0 && distance[threads] == 0) {
        graph.edges[blockIdx.x].distance = 1.0f;
    }
    
    // Modify the value so that it's easier to sort 
    if (graph.edges[blockIdx.x].distance == 1.0f && threadIdx.y == 0) {
        graph.edges[blockIdx.x].distance = 0.0f;
    }
}

// NOTE : This sort function should really be a fuctor that takes the swapping type and a swap functor
//        so that it can be easilty reused, but limited time, so I just copied the code for the fragment
//        sort -- can improve for future work
        
// ----------------------------------- EDGE SORT ------------------------------------------------------------

__device__
void swap_edges(graph_type& graph, const size_t edge_idx_one, const size_t edge_idx_two)
{
    Edge temp = graph.edges[edge_idx_one];
    graph.edges[edge_idx_one] = graph.edges[edge_idx_two];
    graph.edges[edge_idx_two] = temp; 
}

// Out to in operation for bitonic sort
__global__ 
void bitonic_out_in_sort(graph_type graph, const size_t block_size, const size_t total_elements)
{
    const size_t block_idx  = blockIdx.x / (block_size / 2);
    
    // Mapping for the indices (see https://en.wikipedia.org/wiki/Bitonic_sorter) second image 
    // idx one and two are the black lines in the orange blocks
    const size_t idx_one    = blockIdx.x + (block_idx * (block_size / 2));
    const size_t idx_two    = idx_one + (block_size - (blockIdx.x % (block_size / 2)) - 1) 
                            - (idx_one % (block_size / 2));
    
    // If the dimensions are in range
    if (idx_one < total_elements && idx_two < total_elements && threadIdx.y == 0) {
        // The edges need to be swapped if the right one is larger than the left one
        // or if the left one has a value of 0.5, since those must be removed
        if (graph.edges[idx_one].distance <= graph.edges[idx_two].distance) {
            swap_edges(graph, idx_one, idx_two);
        } 
    }
}

// Out to out operation fr bitonic sort
__global__
void bitonic_out_out_sort(graph_type graph, const size_t block_size, const size_t total_elements)
{
    const size_t block_idx = blockIdx.x / (block_size / 2);
    
    // Mapping for the indices (see https://en.wikipedia.org/wiki/Bitonic_sorter) second image 
    // idx one and two are the black lines in the red blocks
    const size_t idx_one   = blockIdx.x + (block_idx * (block_size / 2));
    const size_t idx_two   = idx_one + (block_size / 2);

    // Check that the node index is in the first half of the block and the comp node is in range
    if (idx_one < total_elements && idx_two < total_elements && threadIdx.y == 0) {
        // The edges need to be swapped if the right one is larger than the left one
        // or if the left one has a value of 0.5, since those must be removed
        if (graph.edges[idx_one].distance <= graph.edges[idx_two].distance) {
            swap_edges(graph, idx_one, idx_two);
        }
    }    
}

// ---------------------------------------- FRAGMENT SORT ---------------------------------------------------

__device__
void swap_fragments(graph_type& graph, const size_t frag_idx_one, const size_t frag_idx_two)
{
    Fragment temp = graph.fragments[frag_idx_one];
    graph.fragments[frag_idx_one] = graph.fragments[frag_idx_two];
    graph.fragments[frag_idx_two] = temp; 
}

// Out to in operation for bitonic sort
__global__ 
void bitonic_out_in_sort_frag(graph_type graph, const size_t block_size, const size_t total_elements)
{
    const size_t block_idx  = blockIdx.x / (block_size / 2);
    const size_t idx_one    = blockIdx.x + (block_idx * (block_size / 2));
    const size_t idx_two    = idx_one + (block_size - (blockIdx.x % (block_size / 2)) - 1) 
                            - (idx_one % (block_size / 2));
    
    // If the dimensions are in range
    if (idx_one < total_elements && idx_two < total_elements && threadIdx.y == 0) {
        // The edges need to be swapped if the right one is larger than the left one
        // or if the left one has a value of 0.5, since those must be removed
        if (graph.fragments[idx_one].score < graph.fragments[idx_two].score) {
            swap_fragments(graph, idx_one, idx_two);
        } 
    }
}

// Out to out operation fr bitonic sort
__global__
void bitonic_out_out_sort_frag(graph_type graph, const size_t block_size, const size_t total_elements)
{
    const size_t block_idx = blockIdx.x / (block_size / 2);
    const size_t idx_one   = blockIdx.x + (block_idx * (block_size / 2));
    const size_t idx_two   = idx_one + (block_size / 2);

    // Check that the node index is in the first half of the block and the comp node is in range
    if (idx_one < total_elements && idx_two < total_elements && threadIdx.y == 0) {
        // The edges need to be swapped if the right one is larger than the left one
        // or if the left one has a value of 0.5, since those must be removed
        if (graph.fragments[idx_one].score < graph.fragments[idx_two].score) {
            swap_fragments(graph, idx_one, idx_two);
        }
    }    
}

// To remove all uninformative values after the edge sort
__device__ 
size_t find_last_valid_edge(const graph_type& graph)
{
    bool   found_end       = false;   
    size_t last_valid_edge = 0;
    while (!found_end) {
       if (graph.edges[last_valid_edge].distance != 0.0f) 
            ++last_valid_edge;
        else 
            found_end = true;
    }
    return last_valid_edge;
}

__global__
void search_graph(data_type data, graph_type graph, size_t threads) 
{
    map_distances(data, graph, threads);
    reduce_distances(data, graph, threads);
}

// ------------------------------------------------ PARTITIONING --------------------------------------------

// If the fragment exists in a set
// We store a fragment as partitioned by setting the element at it's index to 1
template <uint8_t Set> __device__ 
inline uint8_t in_set(graph_type&  graph, const size_t fragment)
{ 
    return Set == 1 
                ? graph.set_one[fragment] == 1
                : graph.set_two[fragment] == 1;
}


__device__
void partition_next_largest_fragment(graph_type& graph, size_t& last_set_edge, const size_t last_valid_edge,
                                     uint8_t* shared_set)
{
    const size_t initial_edge = last_set_edge;
    bool   found              = false;
   
    if (blockIdx.x == 0 && threadIdx.y == 0) { 
        while (last_set_edge < last_valid_edge - 1 && !found) {
            uint8_t f1_in_set_1 = in_set<1>(graph, graph.edges[last_set_edge].f1); 
            uint8_t f1_in_set_2 = in_set<2>(graph, graph.edges[last_set_edge].f1); 
            uint8_t f2_in_set_1 = in_set<1>(graph, graph.edges[last_set_edge].f2); 
            uint8_t f2_in_set_2 = in_set<2>(graph, graph.edges[last_set_edge].f2);  
            
            if (f1_in_set_1 && !f2_in_set_2 && !f2_in_set_1) {
                // f1 in set one, add f2 to set two
                graph.set_two[graph.edges[last_set_edge].f2] = 1;
                ++graph.set_two_size;
                found = true;
            } else if (f2_in_set_1 && !f1_in_set_2 && !f1_in_set_1) {
                // f2 in set one, add f1 to set two
                graph.set_two[graph.edges[last_set_edge].f1] = 1;
                ++graph.set_two_size;
                found = true;
            } else if (f1_in_set_2 && !f2_in_set_1 && !f2_in_set_2) {
                // f1 in set 2, add f2 so set one
                graph.set_one[graph.edges[last_set_edge].f2] = 1;
                ++graph.set_one_size;
                found = true;
            } else if (f2_in_set_2 && !f1_in_set_1 && !f1_in_set_2) {
                // f2 in set 2, add f1 to set one
                graph.set_one[graph.edges[last_set_edge].f1] = 1;
                ++graph.set_one_size;
                found = true;
            } else ++last_set_edge;
        }
        if (found) {
            Edge temp                   = graph.edges[initial_edge];
            graph.edges[initial_edge]   = graph.edges[last_set_edge];
            graph.edges[last_set_edge]  = temp;
            last_set_edge               = initial_edge + 1;
        } else last_set_edge = initial_edge;
    }
}

__device__
void partition_next_smallest_fragment(graph_type& graph, size_t& last_set_edge, uint8_t* shared_set)
{
    const size_t initial_edge = last_set_edge;
    bool   found = false;
    
    if (blockIdx.x == 0 && threadIdx.y == 0) { 
        while (last_set_edge >= 1 && !found) {
            // This is all constant-time lookup
            uint8_t f1_in_set_1 = in_set<1>(graph, graph.edges[last_set_edge].f1); 
            uint8_t f1_in_set_2 = in_set<2>(graph, graph.edges[last_set_edge].f1); 
            uint8_t f2_in_set_1 = in_set<1>(graph, graph.edges[last_set_edge].f2); 
            uint8_t f2_in_set_2 = in_set<2>(graph, graph.edges[last_set_edge].f2); 
            
            if (f1_in_set_1 && !f2_in_set_1 && !f2_in_set_2) {
                // f1 in set one, add f2 to set one
                ++graph.set_one_size;
                graph.set_one[graph.edges[last_set_edge].f2] = 1;
                found = true;
            } else if (f2_in_set_1 && !f1_in_set_1 && !f1_in_set_2) {
                // f2 in set one, add f1 to set one
                ++graph.set_one_size;
                graph.set_one[graph.edges[last_set_edge].f1] = 1;
                found = true;
            } else if (f1_in_set_2 && !f2_in_set_2 && !f2_in_set_1) {
                // f1 in set 2, add f2 so set two
                ++graph.set_two_size;
                graph.set_two[graph.edges[last_set_edge].f2] = 1;
                found = true;
            } else if (f2_in_set_2 && !f1_in_set_2 && !f1_in_set_1) {
                // f2 in set 2, add f1 to set one
                ++graph.set_two_size;
                graph.set_two[graph.edges[last_set_edge].f1] = 1;
                found = true;
            } else --last_set_edge;
        }
        if (found) {
            Edge temp                   = graph.edges[initial_edge];
            graph.edges[initial_edge]   = graph.edges[last_set_edge];
            graph.edges[last_set_edge]  = temp;
            last_set_edge               = initial_edge - 1; 
        } else last_set_edge = initial_edge;
    }
}

__global__ 
void map_to_partitions(data_type data, graph_type graph)
{
    const size_t last_valid_edge        = find_last_valid_edge(graph);      // Improve this
    size_t       last_set_edge_forward  = 1;
    size_t       last_set_edge_backward = last_valid_edge - 1;
    bool         keep_partitioning      = true;
   
    extern __shared__ uint8_t sets[];
    
    // Add the first elements in the partitions
    graph.set_one[graph.edges[0].f1] = graph.edges[0].f1; graph.set_one_size = 1;
    graph.set_two[graph.edges[0].f2] = graph.edges[0].f2; graph.set_two_size = 1;
    
    // Partition the remaining fragments -- this needs to be improved
    while (keep_partitioning) {
        size_t last_edge_back_before = last_set_edge_backward;
        size_t last_edge_fwd_before  = last_set_edge_forward;

        partition_next_largest_fragment(graph, last_set_edge_forward, last_valid_edge, &sets[0]);
        partition_next_smallest_fragment(graph, last_set_edge_backward, &sets[0]);   
        
        if (last_set_edge_forward == last_valid_edge || last_set_edge_backward == 1     ||
            (last_set_edge_forward == last_edge_fwd_before                              && 
             last_set_edge_backward == last_edge_back_before)                           ||
            (graph.set_one_size + graph.set_two_size == data.reads)                      ) {
                keep_partitioning = false;
        }
    }  
}


__global__
void swap_fragment_set(data_type data, graph_type graph)
{
    bool set = false;
    Fragment* frag = &graph.fragments[0];
    while (!set) {
        if (frag->swapped < 2) {
            if (frag->set == 1) {
                graph.set_one[frag->index] = 0;
                graph.set_two[frag->index] = 1;
                --graph.set_one_size; ++graph.set_two_size;
                graph.fragments[frag->index].swapped = frag->swapped + 1;
                set = true;
            } else if (frag->set == 2) {
                graph.set_two[frag->index] = 0;
                graph.set_one[frag->index] = 1; 
                --graph.set_two_size; ++graph.set_one_size;
                graph.fragments[frag->index].swapped = frag->swapped + 1;
                set = true;
            }
        } else ++frag;
    }
}

// ------------------------------------------- NIH CONSIDERATION --------------------------------------------

__global__
void check_haplotypes(data_type data, graph_type graph)
{
   const size_t snp_idx = blockIdx.x * blockDim.x + threadIdx.x;
   
   // Check if the haplotypes are IH and have the same values 
   if (snp_idx < data.snps) {
       if (data.snp_info[snp_idx].type() == IH && 
           graph.haplo_one_temp[snp_idx] == graph.haplo_two_temp[snp_idx]) {
                // MEC score addition if haplo one is flipped 
                unsigned int mec_flip_one = min(static_cast<unsigned int>(graph.snp_scores_one[snp_idx + data.snps]),
                                                static_cast<unsigned int>(graph.snp_scores_two[snp_idx]));
          
                // MEC score addition if haplo two is flipped 
                unsigned int mec_flip_two = min(static_cast<unsigned int>(graph.snp_scores_two[snp_idx + data.snps]),
                                                static_cast<unsigned int>(graph.snp_scores_one[snp_idx]));

                // We need to flip the one which will make the least change to the MEC score
                if (mec_flip_one >= mec_flip_two) graph.haplo_one_temp[snp_idx] = !graph.haplo_two_temp[snp_idx];
                else                              graph.haplo_two_temp[snp_idx] = !graph.haplo_one_temp[snp_idx];
        }
   }
   __syncthreads();
}

// ------------------------------------- EVALUATES THE PARTITIONS -------------------------------------------
// Set is the partition -- 1 or 2
template <uint8_t Set> __global__
void determine_switch_error(data_type data, graph_type graph)
{   
    const size_t snp_idx  = blockIdx.x;   
    const size_t read_idx = threadIdx.y;
    
    extern __shared__ size_t counts[];  // Number of 1's and zeros in the alignments
   
    // Load data into shred memory 
    if (snp_idx < data.snps) {
        if (read_idx < data.reads && in_set<Set>(graph, read_idx)) {
            auto read_info = data.read_info[read_idx];
            if (read_info.start_index() <= snp_idx &&
                read_info.end_index()   >= snp_idx) {
                // Load the value into shared memory
                if (data.data[read_info.offset() + snp_idx - read_info.start_index()] == 0) 
                    counts[read_idx] = 1;
                else if (data.data[read_info.offset() + snp_idx - read_info.start_index()] == 1)
                    counts[read_idx + data.reads] = 1;
                else {
                    counts[read_idx] = 0; counts[read_idx + data.reads] = 0;
                }
            } else {
                counts[read_idx] = 0; counts[read_idx + data.reads] = 0;
            }   
        } else if (read_idx < data.reads) {
            counts[read_idx] = 0; counts[read_idx + data.reads] = 0;
        }
        __syncthreads();
        
        // Now reduce the arrays
        size_t reduction_threads = data.reads;
        while (reduction_threads > 1) {
            if (read_idx < reduction_threads / 2) {
                counts[read_idx]              += counts[read_idx + reduction_threads / 2];
                counts[read_idx + data.reads] += counts[read_idx + data.reads + reduction_threads / 2];
            }
            // If there are an odd number of elements in the array
            if (reduction_threads % 2 == 1) {
                if (read_idx == reduction_threads / 2) {
                    counts[read_idx]                = counts[read_idx + reduction_threads / 2];
                    counts[read_idx + data.reads]   = counts[read_idx + data.reads + reduction_threads / 2];            
                }
                reduction_threads /= 2; reduction_threads += 1;
            } else reduction_threads /= 2;
            __syncthreads();
        }
        
        // The first thread then moves the values into the arary for the graph
        // This code is hideous =/ -- time pressure
        if (threadIdx.y == 0) {
            if (Set == 1) {
                graph.haplo_one_temp[snp_idx] = counts[0] >= counts[data.reads] ? 0 : 1;
                graph.snp_scores_one[snp_idx] = counts[0] >= counts[data.reads] ? counts[data.reads] : counts[0];
                graph.snp_scores_one[snp_idx + data.snps] = counts[0] >= counts[data.reads] 
                                                      ? counts[0] : counts[data.reads];
            } else if (Set == 2) {
                graph.haplo_two_temp[snp_idx] = counts[0] >= counts[data.reads] ? 0 : 1;
                graph.snp_scores_two[snp_idx] = counts[0] >= counts[data.reads] ? counts[data.reads] : counts[0];
                graph.snp_scores_two[snp_idx + data.snps] = counts[0] >= counts[data.reads] 
                                                      ? counts[0] : counts[data.reads];
            }
        }
        __syncthreads();
#ifdef DEBUG
        if ((graph.haplo_one_temp[snp_idx] > 1 || graph.haplo_two_temp[snp_idx] > 1) && snp_idx < data.snps) {
            printf("Error %i\n", blockIdx.x);
        }
        __syncthreads();
#endif
    }
}

// -------------------------------------------- ADD UNPARTITIONED PARTITIONS --------------------------------

__global__
void add_unpartitioned(data_type data, graph_type graph)
{
    // Each block partitions one unpartitioned read 
    extern __shared__ uint8_t scores[];
    
    const size_t read_idx = blockIdx.x;
    const size_t snp_idx  = threadIdx.y;
    
    if (!in_set<1>(graph, read_idx) && !in_set<2>(graph, read_idx) && read_idx < data.reads) {
       if (snp_idx < data.snps) {
           auto read_info = data.read_info[read_idx];
           if (read_info.start_index() <= snp_idx && read_info.end_index() >= snp_idx) {
               // Check to see if the value against set 1 conflicts 
               uint8_t value = data.data[read_info.offset() + snp_idx - read_info.start_index()];
               if (value != graph.haplo_one_temp[snp_idx] && value <= 1) 
                   scores[snp_idx] = 1;
               else scores[snp_idx] = 0;
               if (value != graph.haplo_two_temp[snp_idx] && value <= 1)
                   scores[snp_idx + data.snps] = 1;
               else scores[snp_idx + data.snps] = 0;
           }
       } else {
           scores[snp_idx] = 0; 
           scores[snp_idx + data.snps] = 0;
       }
        __syncthreads(); 
        
        // And now we reduce the snps to find the total contribution of the read to the sets
        size_t reduction_threads = data.snps;
        while (reduction_threads > 1) {
            if (snp_idx < reduction_threads / 2) {
                scores[snp_idx]             += scores[snp_idx + reduction_threads / 2];
                scores[snp_idx + data.snps] += scores[snp_idx + data.snps + reduction_threads / 2];
            }
            // If therea are an odd number of elements to reduce, move the last one
            if (reduction_threads % 2 == 1) {
                if (snp_idx == reduction_threads) {
                    scores[snp_idx]             = scores[snp_idx + reduction_threads / 2];
                    scores[snp_idx + data.snps] = scores[snp_idx + data.snps + reduction_threads / 2];
                }
                reduction_threads /= 2; reduction_threads += 1;
            } else reduction_threads /= 2;
            __syncthreads();
        }
        // Add the result to the set in the graph
        if (threadIdx.y == 0) {
            scores[0] <= scores[data.snps]
                ? graph.set_one[read_idx] = read_idx
                : graph.set_two[read_idx] = read_idx;
        }
    }
    __syncthreads();
}

__device__
void set_haplotypes(graph_type& graph, const size_t snps)
{
    const size_t snp_idx = threadIdx.y * BLOCK_SIZE + threadIdx.x;
    if (snp_idx < snps) {
        graph.haplo_one[snp_idx] = graph.haplo_one_temp[snp_idx];
        graph.haplo_two[snp_idx] = graph.haplo_two_temp[snp_idx];
    }
}

// ------------------------------------------ MEC SCOR CALCULATION ------------------------------------------

__global__
void map_mec_score(data_type data, graph_type graph)
{
    extern __shared__ size_t conflicts[];
    
    const size_t frag_idx = blockIdx.x;
    const size_t snp_idx  = threadIdx.y;
    
    if (frag_idx < data.reads) {
        Fragment* frag = &graph.fragments[frag_idx];
        frag->index = frag_idx;
        
        if (in_set<1>(graph, frag_idx))      { frag->set = 1; }
        else if (in_set<2>(graph, frag_idx)) { frag->set = 2; }
#ifdef DEBUG
        else                                 { printf("Error!\n"); }
#endif
        
        auto read_info = data.read_info[frag_idx];
  
        // SNP is valid -- is part of the fragment 
        if (read_info.start_index() <= snp_idx && read_info.end_index() >= snp_idx) {
            uint8_t value = data.data[read_info.offset() + snp_idx - read_info.start_index()];
            if (value != graph.haplo_one_temp[snp_idx] && value <= 1)
                conflicts[snp_idx] = 1;
            else conflicts[snp_idx] = 0;
            // Other haplotype
            if (value != graph.haplo_two_temp[snp_idx] && value <= 1)
                conflicts[snp_idx + data.snps] = 1;
            else conflicts[snp_idx + data.snps] = 0;
        } else {
            conflicts[snp_idx] = 0;
            conflicts[snp_idx + data.snps] = 0;
        }
        __syncthreads();
        
        // Reduce the array to find the fragment value
        size_t reduction_threads = data.snps;
        while (reduction_threads > 1) {
            if (snp_idx < reduction_threads / 2) {
                conflicts[snp_idx]              += conflicts[snp_idx + reduction_threads / 2];
                conflicts[snp_idx + data.snps]  += conflicts[snp_idx + data.snps + reduction_threads / 2];
            } 
            if (reduction_threads % 2 == 1) {
                if (snp_idx == reduction_threads / 2) {
                    conflicts[snp_idx] = conflicts[snp_idx + reduction_threads / 2];
                    conflicts[snp_idx + data.snps] = conflicts[snp_idx + data.snps + reduction_threads / 2];
                }
                reduction_threads /= 2; reduction_threads += 1;
            } else reduction_threads /= 2;
            __syncthreads();
        }
        if (threadIdx.y == 0) {
            // Move the value to the fragment
            if (conflicts[0] < data.snps && conflicts[data.snps] < data.snps) {
                frag->score = min(static_cast<unsigned int>(conflicts[0])         , 
                                  static_cast<unsigned int>(conflicts[data.snps]) );
            } else frag->score = 0;
        }
    }
}

__global__ 
void reduce_mec_score(data_type data, graph_type graph) 
{
    // The scores for each of the fragments
    extern __shared__ size_t frag_scores[];
    
    // We are only using a single block for this
    const size_t frag_idx = threadIdx.y * BLOCK_SIZE + threadIdx.x;
    
    if (frag_idx < data.reads) {
        frag_scores[frag_idx] = graph.fragments[frag_idx].score;
    }
    __syncthreads();
    
    size_t reduction_threads = data.reads;
    while (reduction_threads > 1) {
        if (frag_idx < reduction_threads / 2) {
            frag_scores[frag_idx] += frag_scores[frag_idx + reduction_threads / 2];
        }
        // When there are an odd number of elements to reduce
        if (reduction_threads % 2 == 1) {
            if (frag_idx == reduction_threads / 2) {
                frag_scores[frag_idx] = frag_scores[frag_idx + reduction_threads / 2];
            }
            reduction_threads /= 2; reduction_threads += 1; 
        } else reduction_threads /= 2;
        __syncthreads();
    }
    // Save the mec score
    if (threadIdx.x == 0 && frag_scores[0] < *graph.mec_score) {
        *graph.mec_score = frag_scores[0]; 
        // Set the new haplotype
    }
    __syncthreads();
    if (*graph.mec_score == frag_scores[0]) set_haplotypes(graph, data.snps);
    __syncthreads();
}

}               // End namespace haplo
