#include "cuda.h"
#include "debug.h"
#include "math.h"
#include "tree_internal.h"

#define BLOCK_SIZE 1024

namespace haplo {

struct BoundsGpu {

    size_t lower;               // The lower value for the bound    
    size_t upper;               // The upper value for the bound
    size_t diff;                // The difference between the upper and lower bound
    size_t index;               // The snp index the bound represents
    size_t offset;              // The offset in the array of the bound
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Overload for the assingment operator 
    // ------------------------------------------------------------------------------------------------------
    __device__
    void operator=(BoundsGpu& other) 
    {
        lower           = other.lower;
        upper           = other.upper;
        diff            = other.diff;
        index           = other.index;
        offset          = other.offset;
    }
};


// Maps all the unsearched snps to an array of BoundsGpu structs which can then be reduces
__global__ 
void map_unsearched_snps(internal::Tree tree, BoundsGpu* snp_bounds, const size_t last_searched_snp,
                         const size_t start_node_idx)
{
    const size_t    thread_id     = blockIdx.x * blockDim.x + threadIdx.x;
    const size_t    ref_haplo_idx = tree.search_snps[thread_id + last_searched_snp + 1];
    const TreeNode* comp_node     = tree.node_ptr(start_node_idx);
    size_t same = 0, opp = 0;
    
    // Index of the haplotype for the comparison
    snp_bounds[thread_id].index  = ref_haplo_idx;
    snp_bounds[thread_id].offset = thread_id + last_searched_snp + 1;

    // If the SNP is NIH 
    if (tree.snp_info[ref_haplo_idx].type() == 1) {
        snp_bounds[thread_id].index = tree.snps + 1;
    } else { 
        // Go through all the set nodes    
        for (size_t i = last_searched_snp + 1; i >= 1; --i) {
            const size_t alignments       = tree.alignment_offsets[comp_node->haplo_idx + tree.reads];
            const size_t alignment_offset = tree.alignment_offsets[comp_node->haplo_idx] - 1;        
     
            for (size_t j = alignment_offset; j < alignment_offset + alignments; ++j) {
                size_t row_offset = tree.read_info[tree.aligned_reads[j]].offset();
                size_t read_start = tree.read_info[tree.aligned_reads[j]].start_index();
                size_t read_end   = tree.read_info[tree.aligned_reads[j]].end_index();
                
                // If the reads cross the snp sites
                if (read_start <= ref_haplo_idx && read_start <= comp_node->haplo_idx &&
                    read_end   >= ref_haplo_idx && read_end   >= comp_node->haplo_idx ) {
                    
                    // Values of the two elements
                    uint8_t ref_value  = tree.data[row_offset + (ref_haplo_idx - read_start)];
                    uint8_t comp_value = tree.data[row_offset + (comp_node->haplo_idx - read_start)]; 
                 
                    if (comp_value == ref_value && ref_value <= 1) ++same;
                    else if (comp_value != ref_value && ref_value <= 1 && comp_value <= 1) ++opp;
                }
            }
            if (i > 1) {
                // Go back up the tree
                comp_node = tree.node_ptr(comp_node->root_idx);
            }
        }
    }
    
    // Format the bounds 
    snp_bounds[thread_id].lower = min((unsigned int)same, (unsigned int)opp);
    snp_bounds[thread_id].upper = max((unsigned int)same, (unsigned int)opp);
    snp_bounds[thread_id].diff  = snp_bounds[thread_id].upper - snp_bounds[thread_id].lower;
    __syncthreads();
}

// Checks which of the two snps is more "vaulable", first by the bounds diff
// parameters, and then by the snp index
__device__
bool more_valuable(BoundsGpu* snp_one, BoundsGpu* snp_two)
{
    // First check which has the greater differenece between upper and lower
    return snp_one->diff > snp_two->diff 
                         ? true 
                         : snp_two->diff > snp_one->diff 
                            ? false 
                            : snp_one->index < snp_two->index 
                                ? true : false;
}

__device__ 
void swap_search_snp_indices(internal::Tree& tree, size_t last_searched_snp, const BoundsGpu* const bound)
{
    ++last_searched_snp;
    // If the value to swap is not already the value
    if (bound->index != tree.search_snps[last_searched_snp]) {
        const size_t temp                   = tree.search_snps[last_searched_snp];
        tree.search_snps[last_searched_snp] = bound->index;
        tree.search_snps[bound->offset]     = temp;
    }
}

// "Reduce" function for the list of selection params to determine the best param 
//  The reduction is done such that the resulting bound has the highest diff and 
//  lowest index (this is to mean that the snp is most correlated to the snps already
//  searched and is also closest to them (hence the lowest index))
__global__ 
void reduce_unsearched_snps(internal::Tree tree, BoundsGpu* snp_bounds, const size_t last_searched_snp,
                            const size_t elements)
{
    const size_t thread_id      = blockIdx.x * blockDim.x + threadIdx.x;
    const size_t reductions     = static_cast<size_t>(ceil(log2(static_cast<double>(elements))));
    size_t reduction_threads    = elements - 1, snp_idx_other = 0;
    
    while (reduction_threads > 1) {
        // Only the first half of the threads do the reduction 
        snp_idx_other = thread_id + (reduction_threads / 2);
        
        if (thread_id < (reduction_threads / 2)) {
            // If the more rightward bound is more valuable 
            if (!more_valuable(&snp_bounds[thread_id], &snp_bounds[snp_idx_other])) {
                // We need ro replace the left value withe the right one
                BoundsGpu temp            = snp_bounds[thread_id];
                snp_bounds[thread_id]     = snp_bounds[snp_idx_other];
                snp_bounds[snp_idx_other] = temp;
            }
        }
        // If there were an odd number of elements, the last one just fetches and moves a value 
        if (reduction_threads % 2 == 1) {
            if (thread_id == (reduction_threads / 2)) {
                // There is an odd number of elements in the array,
                // The last thread just needs to move a value 
                BoundsGpu temp            = snp_bounds[thread_id];
                snp_bounds[thread_id]     = snp_bounds[snp_idx_other];
                snp_bounds[snp_idx_other] = temp;
            }
            reduction_threads /= 2; reduction_threads += 1;
        } else reduction_threads /= 2;
        __syncthreads();
    }
    // The first thread needs to swap the search result
    if (thread_id == 0) {
        swap_search_snp_indices(tree, last_searched_snp, snp_bounds); 
    }
    __syncthreads();
}

// Swaps two nodes in the node array
__device__ 
void swap(TreeNode* left, TreeNode* right) 
{
    TreeNode temp = *left;
    *left          = *right;
    *right         = temp;
}

// Sorts a sub array bitonically 
__device__ 
void bitonic_out_in_sort(internal::Tree& tree       , const size_t start_idx    ,  
                         const size_t    block_idx  , const size_t block_size   ,
                         const size_t    total_nodes                            )
{
    const size_t thread_idx    = blockIdx.x * blockDim.x + threadIdx.x;
    const size_t node_idx      = thread_idx + (block_idx * (block_size / 2));
    const size_t comp_node_idx = node_idx + (block_size - (thread_idx % (block_size / 2)) - 1)
                               - (node_idx % (block_size / 2));
    
    if (comp_node_idx < total_nodes) {
        if (tree.node_ptr(start_idx + comp_node_idx)->lbound  < 
            tree.node_ptr(start_idx + node_idx)->lbound        ) {
                // Then the nodes need to be swapped
                swap(tree.node_ptr(start_idx + comp_node_idx), 
                     tree.node_ptr(start_idx + node_idx)    );
        }
    }
}


__device__
void bitonic_out_out_sort(internal::Tree& tree       , const size_t start_idx ,
                          const size_t    block_idx  , const size_t block_size,
                          const size_t    total_nodes                         )
{
    const size_t thread_idx    = blockIdx.x * blockDim.x + threadIdx.x;
    const size_t node_idx      = thread_idx + (block_idx * (block_size / 2));
    const size_t comp_node_idx = node_idx + (block_size / 2);

    // Check that the node index is in the first half of the block and the comp node is in range
    if (comp_node_idx < total_nodes) {
        // First node compares with the node __num_nodes__ ahead of it
        if (tree.node_ptr(start_idx + comp_node_idx)->lbound < 
            tree.node_ptr(start_idx + node_idx)->lbound      ) {
                // Then the nodes need to be swapped
                swap(tree.node_ptr(start_idx + comp_node_idx), 
                     tree.node_ptr(start_idx + node_idx)     );
        }
    }    
}

// Reduces a level using a parallel bitonic sort
__global__
void reduce_level(internal::Tree tree, const size_t start_node_idx, const size_t num_nodes)
{
    const size_t        passes         = static_cast<size_t>(ceil(log2(static_cast<double>(num_nodes))));
    const size_t        thread_id      = blockIdx.x * blockDim.x + threadIdx.x;
    size_t              block_size     = 2, prune_idx = INT_MAX;
    
    if (thread_id < num_nodes / 2) {
        for (size_t pass = 0; pass < passes; ++pass) {
            // We need a logarithmically decreasing number of out-in passes 
            bitonic_out_in_sort(tree, start_node_idx, thread_id / (block_size / 2), block_size, num_nodes);
            __syncthreads();

            // Now we need pass number of out-out bitonic sorts
            size_t out_out_block_size = block_size / 2; 
            for (size_t i = 0; i < pass; ++i) {
                bitonic_out_out_sort(tree, start_node_idx, thread_id / (out_out_block_size / 2), 
                                     out_out_block_size , num_nodes);
                out_out_block_size /= 2;
                __syncthreads();
            }
            block_size *= 2;
        }
    }
    
    // Nodes are now sorted, find the first node with LB > UB[0]
    // First pass (we need 2 because we only have nodes / 2 threads)
    if (thread_id > 0) {
        if ( (tree.node_ptr(start_node_idx + thread_id + num_nodes / 2)->lbound >= 
              tree.node_ptr(start_node_idx)->ubound                             )     &&
             (tree.node_ptr(start_node_idx + thread_id + num_nodes / 2 - 1)->lbound < 
              tree.node_ptr(start_node_idx)->ubound                                 )) {
                prune_idx = start_node_idx + thread_id + num_nodes / 2;
        }
        else if ( (tree.node_ptr(start_node_idx + thread_id)->lbound >= 
                   tree.node_ptr(start_node_idx)->ubound             ) &&
                  (tree.node_ptr(start_node_idx + thread_id - 1)->lbound < 
                   tree.node_ptr(start_node_idx)->ubound                 )) { 
                prune_idx = start_node_idx + thread_id;
        }
    }
}

// Updates the values of the alignments for a specific node
__device__
void add_node_alignments(internal::Tree& tree       , const size_t* const last_unaligned_idx, 
                         const size_t    node_idx   , const size_t* const alignment_offset  )
{
    TreeNode* const node            = tree.node_ptr(node_idx);
    const size_t thread_id          = blockIdx.x * blockDim.x + threadIdx.x;
    size_t alignments               = tree.alignment_offsets[node->haplo_idx + tree.reads];
    size_t alignment_start          = tree.alignment_offsets[node->haplo_idx];
    const size_t offset             = alignments * thread_id + *alignment_offset;
    size_t read_offset, elem_pos; uint8_t element;
    
    // If there is a valid index for the alignment start
    if (alignment_start != 0) {
        --alignment_start;
    
        // Set the offset in the read_values array of the start of the reads for this node
        node->align_idx = offset;
        
        // For all the alignments for the snp
        for (size_t i = alignment_start; i < alignment_start + alignments; ++i) {
            // Find the element in the data array
            read_offset = tree.read_info[tree.aligned_reads[i]].offset();
            elem_pos    = node->haplo_idx - tree.read_info[tree.aligned_reads[i]].start_index();
            element     = tree.data[read_offset + elem_pos];
            
            // Determine the alignment values of the node 
            if ((element == 0 && node->value == 0) || (element == 1 && node->value == 1)) {
                tree.read_values[offset + i - alignment_start] = 1;
            } else if ((element == 0 && node->value == 1) || (element == 1 && node->value == 0)) {
                tree.read_values[offset + i - alignment_start] = 0;
            }
        }
    }
}

// Updates the indices which are have been aligned so far
__device__ 
void update_global_alignments(internal::Tree& tree, size_t* last_unaligned_idx, const size_t haplo_idx)   
{
    __shared__ size_t  found   ; __shared__ size_t read_offset; __shared__ size_t  elem_pos     ;
    __shared__ size_t  elements; __shared__ size_t last_index ; __shared__ uint8_t element_value;
    
    elements   = tree.snp_info[haplo_idx].elements();
    last_index = *last_unaligned_idx;
    found      = 0; 
    
    // Go through all the unaligned reads
    for (size_t i = last_index; i < tree.reads && found < elements; ++i) {
        if (tree.aligned_reads[i] >= tree.snp_info[haplo_idx].start_index() &&
            tree.aligned_reads[i] <= tree.snp_info[haplo_idx].end_index()   ) {
            // If the read crosses the snp site
            if (tree.read_info[tree.aligned_reads[i]].start_index() <= haplo_idx &&
                tree.read_info[tree.aligned_reads[i]].end_index()   >= haplo_idx ) { 
                
                // Get the offset in memory of the start of the read
                read_offset     = tree.read_info[tree.aligned_reads[i]].offset();
                elem_pos        = haplo_idx - tree.read_info[tree.aligned_reads[i]].start_index();
                element_value   = tree.data[read_offset + elem_pos];
    
                // If the element is valid then add the index of the alignment by swapping 
                if (element_value <= 1) {
                    size_t temp_value               = tree.aligned_reads[i];
                    tree.aligned_reads[i]           = tree.aligned_reads[last_index];
                    tree.aligned_reads[last_index]  = temp_value;
                    ++last_index; ++found;
                }
            }
        }
    }
    // Update the last index 
    *last_unaligned_idx = last_index;
}

// Does the mapping for the leaf node -- calculates the alignments
__device__ 
void map_leaf_bounds(internal::Tree& tree, const size_t last_searched_snp, const size_t node_idx)
{
    TreeNode* const ref_node      = tree.node_ptr(node_idx);
    const TreeNode* comp_node     = tree.node_ptr(ref_node->root_idx);
    size_t          elements_used = 0;
   
    // Each of the snps which have been serached 
    for (size_t i = last_searched_snp; i >= 1; --i) {
        const size_t alignments       = tree.alignment_offsets[comp_node->haplo_idx + tree.reads];
        const size_t alignment_offset = tree.alignment_offsets[comp_node->haplo_idx];
        
        // Each of the alignments for a snp
        for (size_t j = alignment_offset; j < alignment_offset + alignments; ++j) {
            // If the aligned read crosses the snp index
            if (tree.read_info[tree.aligned_reads[j]].start_index() <= ref_node->haplo_idx &&
                tree.read_info[tree.aligned_reads[j]].end_index()   >= ref_node->haplo_idx ) {
                
                size_t row_offset  = tree.read_info[tree.aligned_reads[j]].offset();
                uint8_t ref_value  = tree.data[row_offset + ref_node->haplo_idx];
                uint8_t alignment  = tree.read_values[comp_node->align_idx + j];  
             
                if ((ref_value == ref_node->value && ref_value <= 1 && alignment == 1) ||
                    (ref_value != ref_node->value && ref_value <= 1 && alignment == 0)) {
                        // Optimal selection -- reduce the upper bound, dont increase lower bound
                        --ref_node->ubound; ++elements_used;
                } else if ((ref_value != ref_node->value && ref_value <= 1 && alignment == 1) ||
                           (ref_value == ref_node->value && ref_value <= 1 && alignment == 0)) {
                        // Non-optimal selection -- incread lower bound, don't reduce upper bound
                        ++ref_node->lbound; ++elements_used;
                }
            }
        }
        if (i > 1) {
            // Go back up the tree
            comp_node = tree.node_ptr(comp_node->root_idx);
        }
    }
    // For all remaining elements, we can reduce the upper bound
    ref_node->ubound -= (tree.snp_info[ref_node->haplo_idx].elements() - elements_used);
}

__global__ 
void map_level(internal::Tree tree          , BoundsGpu* snp_bounds      , const size_t last_searched_snp, 
               size_t* last_unaligned_idx   , size_t* alignment_offset   , const size_t prev_level_start , 
               const size_t this_level_start, const size_t nodes_in_level)
{
    // Set node parameters
    const size_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
    const size_t node_idx  = thread_id + this_level_start;
    
    // If a valid thread
    if (thread_id < nodes_in_level) { 
        TreeNode* const         node       = tree.node_ptr(node_idx);
        const TreeNode* const   root_node  = tree.node_ptr(prev_level_start + (threadIdx.x / 2));
        const size_t last_unaligned_before = *last_unaligned_idx; 
       
        // Set some of the node parameters
        node->haplo_idx = snp_bounds[0].index;
        node->root_idx  = prev_level_start + (threadIdx.x / 2);
        node->lbound    = root_node->lbound;
        node->ubound    = root_node->ubound;
        node->value     = threadIdx.x % 2 == 0 ? 0 : 1;

        // Update the bounds for the node 
        map_leaf_bounds(tree, last_searched_snp, node_idx);

        if (thread_id == 0) {
            // Add the alignments to the overall alignments
            update_global_alignments(tree, last_unaligned_idx, node->haplo_idx);
            if (*last_unaligned_idx != last_unaligned_before) {
                // Set the start index in the alignment array
                tree.alignment_offsets[node->haplo_idx] = last_unaligned_before + 1; 
                tree.alignment_offsets[node->haplo_idx + tree.reads] = *last_unaligned_idx
                                                                     - last_unaligned_before;
            }
        }
        __syncthreads();
        
        // Add the alignments for the node 
        add_node_alignments(tree, last_unaligned_idx, node_idx, alignment_offset);
        if (thread_id == 0) {
            // Move the alignment offset for the next iteration
            *alignment_offset += (nodes_in_level * tree.alignment_offsets[node->haplo_idx + tree.reads]);
        }       
    }
}

__global__
void map_root_node(internal::Tree tree       , BoundsGpu* snp_bounds    , const size_t last_searched_snp,
                   size_t* last_unaligned_idx, size_t* alignment_offset , const size_t start_ubound     , 
                   const size_t device_index )
{
    size_t last_unaligned_before = *last_unaligned_idx;
    
    TreeNode* const node  = tree.node_ptr(0);
    node->haplo_idx  = tree.search_snps[last_searched_snp];
    node->value      = 0; 
    node->lbound     = 0; 
    node->ubound     = start_ubound - tree.snp_info[node->haplo_idx].elements();
   
    // Add the alignments to the overall alignments
    update_global_alignments(tree, last_unaligned_idx, 0);
    if (*last_unaligned_idx != last_unaligned_before) {
        tree.alignment_offsets[0] = last_unaligned_before + 1; // Set the start index in the alignment array 
        tree.alignment_offsets[tree.reads] = *last_unaligned_idx - last_unaligned_before;
    }
    
    // Update the alignments values (how the reads are aligned) for this specific node
    add_node_alignments(tree, last_unaligned_idx, 0, alignment_offset);
    *alignment_offset += tree.alignment_offsets[tree.reads];        
}

__global__ 
void is_sorted(internal::Tree tree, const size_t start_index, const size_t nodes)
{
    size_t prev = tree.nodes[start_index].lbound;
    size_t end  = start_index;
    bool sorted = true;
   
    for (size_t i = start_index + 1; i < start_index + nodes; ++i) {
        if (tree.nodes[i].lbound >= prev) 
            prev = tree.nodes[i].lbound;
        else {
            sorted = false;
            end = i;
        }
    }
    if (sorted) printf("Sorted\n");
    else {
        printf("Not sorted %i", end - start_index);
        printf(" %i\n", nodes);
    }
}

__global__ 
void add_tree_alignments(internal::Tree tree, const size_t node_idx) 
{
    const TreeNode* const node   = tree.node_ptr(node_idx);
    const size_t thread_id       = blockIdx.x * blockDim.x + threadIdx.x;
    const size_t alignment_idx   = tree.aligned_reads[tree.alignment_offsets[node->haplo_idx] - 1 + thread_id];
    
    // Add the value to the alignments for the tree
    tree.alignments[alignment_idx] = tree.read_values[node->align_idx + thread_id]; 
}

__device__ size_t node_idx;

__global__
void find_temp_haplotype(internal::Tree tree, const size_t start_node_idx) 
{
    TreeNode* node         = tree.node_ptr(start_node_idx);
    size_t node_alignments = 0, is_last_iter    = 0, counter = 0;
    node_idx               = start_node_idx;
    
    do {
        // Set the values for the haplotype 
        tree.haplotype[node->haplo_idx]             = node->value;
        tree.haplotype[node->haplo_idx + tree.snps] = !node->value;
        
        // Get the number of alignments for the node 
        node_alignments = tree.alignment_offsets[node->haplo_idx + tree.reads];
        if (node_alignments > 0) {
            size_t grid_x  = node_alignments / 256 + 1;
            size_t block_x = node_alignments > 256 ? 256 : node_alignments;
            // Add the alignements to the tree's alignments 
            add_tree_alignments<<<grid_x, block_x>>>(tree, node_idx);
            cudaDeviceSynchronize();
        }
        if (node->root_idx == 0 || is_last_iter == 1) ++is_last_iter;
        node_idx = node->root_idx;
        node     = tree.node_ptr(node->root_idx);
        ++counter;
    } while (is_last_iter < 2);
}

// Aligns all the reads which do not have an alignment after solving the IH columns
__global__
void align_unaligned_reads(internal::Tree tree, const size_t* last_unaligned_idx, const size_t last_searched_snp) 
{
    extern __shared__ size_t values[];
    const size_t read_idx       = blockIdx.x + *last_unaligned_idx;
    const size_t thread_id      = threadIdx.y * BLOCK_SIZE + threadIdx.x;
    const size_t haplo_idx      = tree.search_snps[thread_id + last_searched_snp + 1];
    const size_t total_elements = tree.snps - last_searched_snp - 1;
    size_t reduction_threads    = total_elements;
    auto read_info              = tree.read_info[read_idx];
    
    // Load the values into shared memory
    if (read_info.start_index() <= haplo_idx && read_info.end_index() >= haplo_idx) {
        // SNP is valid and may have a value 
        tree.data[read_info.offset() + haplo_idx] == 0 
                                                  ? values[thread_id] = 1 
                                                  : values[thread_id + total_elements] = 1;
    } else {
        values[thread_id] = 0; values[thread_id + total_elements] = 0;
    }
    __syncthreads();
    
    do {
        bool odd_num_threads = false;
        
        // Check if there is an odd number of threads to reduce
        if (reduction_threads % 2 == 1 && thread_id == reduction_threads / 2) odd_num_threads = true;
        
        // Reduce all the even numbered elements
        reduction_threads /= 2;
        if (thread_id < reduction_threads) {
            values[thread_id] += values[thread_id + reduction_threads];
            values[thread_id + total_elements] += values[thread_id + total_elements + reduction_threads];
        }        
        
        // If there are an odd number of elements move the last element
        if (odd_num_threads && thread_id == reduction_threads) {
            values[thread_id]                  = values[thread_id + reduction_threads];
            values[thread_id + total_elements] = values[thread_id + total_elements + reduction_threads];
            reduction_threads += 1;
        }
        __syncthreads;
    } while (reduction_threads > 1);
    
    // Set the alignment for the haplotype
    if (thread_id == 0) {
        values[thread_id] > values[thread_id + total_elements] 
                        ? tree.alignments[read_idx] = 0 : tree.alignments[read_idx] = 1;
    }
}

// Solves for the haplotype values for the NIH columns 
// Each block solves for one of the NIH columns
__global__
void solve_nih_columns(internal::Tree tree, const size_t last_searched_snp )
{
    extern __shared__ size_t values[];
    const size_t thread_id   = threadIdx.y * BLOCK_SIZE + threadIdx.x;
    const size_t haplo_idx   = tree.search_snps[last_searched_snp + blockIdx.x + 1];
    size_t reduction_threads = tree.reads - 1;
    auto snp_info            = tree.snp_info[haplo_idx];
    
    // Load the values into shared memory
    if (snp_info.start_index() <= thread_id && snp_info.end_index() >= thread_id) {
        auto value     = tree.data[tree.read_info[thread_id].offset() + haplo_idx];
        auto alignment = tree.alignments[thread_id];
        if (value == 0) {
            if (alignment == 0) {
                values[thread_id]     = 1; values[thread_id + 1] = 0;
                values[thread_id + 2] = 0;
            } else {
                values[thread_id]     = 1; values[thread_id + 2] = 1;
                values[thread_id + 2] = 1;
            }
        } else if (value == 1) {
            if (alignment == 0) {
                values[thread_id]     = 0; values[thread_id + 1] = 1; 
                values[thread_id + 2] = 1; 
            } else {
                values[thread_id]     = 0; values[thread_id + 1] = 0; 
                values[thread_id + 2] = 1; 
            }
        }
    } else {
        values[thread_id]     = 0; values[thread_id + 1] = 0; 
        values[thread_id + 2] = 0;
    }
    __syncthreads();
    
    // Do the reduction to find the value with the lowest score
    do {
        bool odd_num_threads = false;
        
        if (reduction_threads % 2 == 1 && thread_id == reduction_threads / 2) 
            odd_num_threads = true;
        
        // Now use half the threads for the reduction
        reduction_threads /= 2;
        if (thread_id < reduction_threads) {
            values[thread_id]     += values[thread_id + reduction_threads * 3];
            values[thread_id + 1] += values[thread_id + reduction_threads * 3 + 1];
            values[thread_id + 2] += values[thread_id + reduction_threads * 3 + 2];
        }
        
        // If there are an off number of elements then just move the last element
        if (odd_num_threads && thread_id == reduction_threads) {
            values[thread_id]     = values[thread_id + reduction_threads * 3];
            values[thread_id + 1] = values[thread_id + reduction_threads * 3 + 1];
            values[thread_id + 2] = values[thread_id + reduction_threads * 3 + 2];
            reduction_threads += 1;
        }
    } while (reduction_threads > 1);
    __syncthreads();
    
    // First thread then sets the haplotype value
    if (thread_id == 0) {
        if (values[0] >= values[1]) {
            if (values[0] >= values[2]) {
                tree.haplotype[haplo_idx] = 0; 
                tree.haplotype[haplo_idx + tree.snps] = 0;
            } else {
                tree.haplotype[haplo_idx] = 1; 
                tree.haplotype[haplo_idx + tree.snps] = 0;
            }
        } else {
            if (values[1] >= values[2]) {
                tree.haplotype[haplo_idx] = 0;
                tree.haplotype[haplo_idx + tree.snps] = 1;
            } else {
                tree.haplotype[haplo_idx] = 1; 
                tree.haplotype[haplo_idx + tree.snps] = 0;
            }
        }
    }
    __syncthreads();
}

__global__
void print_haplotypes(internal::Tree tree)
{
    for (size_t i = 0; i < tree.snps; ++i) 
        printf("%i", static_cast<unsigned>(tree.haplotype[i]));
    printf("\n");
    for (size_t i = tree.snps; i < 2 * tree.snps; ++i) 
        printf("%i", static_cast<unsigned>(tree.haplotype[i]));
    printf("\n");
}

}               // End namespace haplo
