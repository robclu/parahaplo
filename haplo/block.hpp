// ----------------------------------------------------------------------------------------------------------
/// @file   block.hpp
/// @brief  Header file for a block
// ----------------------------------------------------------------------------------------------------------

#ifndef PARAHAPLO_BLOCK_HPP
#define PARAHAPLO_BLOCK_HPP

#include "operations.hpp"
#include "read_info.h"
#include "snp_info.hpp"
#include "small_containers.h"

#include <boost/iostreams/device/mapped_file.hpp>
#include <boost/tokenizer.hpp>
#include <tbb/tbb.h>
#include <tbb/concurrent_unordered_map.h>
#include <tbb/parallel_sort.h>
#include <thrust/host_vector.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <unordered_map>
#include <utility>

// NOTE: All output the the terminal is for debugging and checking at the moment

namespace haplo {

// Define some HEX values for the 8 bits comparisons
#define ZERO    0x00
#define ONE     0x01
#define TWO     0x02
#define THREE   0x03
#define IH      0x00           // Intricically heterozygous
#define NIH     0x01           // Not intrinsically heterozygous
    
namespace io = boost::iostreams;
using namespace io;

// ----------------------------------------------------------------------------------------------------------
/// @class      Block 
/// @brief      Represents a block of input the for which the haplotypes must be determined
/// @tparam     Elements    The number of elements in the input data
/// @param      ThreadsX    The threads for the X direction 
/// @param      ThreadsY    The threads for the Y direction 
// ----------------------------------------------------------------------------------------------------------
template <size_t Elements, size_t ThreadsX = 1, size_t ThreadsY = 1>
class Block {
public:
    // ----------------------------------------- TYPES ALIAS'S ----------------------------------------------
    using data_container        = BinaryArray<Elements, 2>;    
    using binary_vector         = BinaryVector<2>;
    using atomic_type           = tbb::atomic<size_t>;
    using atomic_vector         = tbb::concurrent_vector<size_t>;
    using read_info_container   = thrust::host_vector<ReadInfo>;
    using snp_info_container    = tbb::concurrent_unordered_map<size_t, SnpInfo>;
    using concurrent_umap       = tbb::concurrent_unordered_map<size_t, uint8_t>;
    // ------------------------------------------------------------------------------------------------------
private:
    size_t              _rows;                  //!< The number of reads in the input data
    size_t              _cols;                  //!< The number of SNP sites in the container
    size_t              _first_splittable;      //!< 1st nono mono splittable solumn in splittale vector
    size_t              _last_aligned;          //!< The last aligned value
    data_container      _data;                  //!< Container for { '0' | '1' | '-' } data variables
    read_info_container _read_info;             //!< Information about each read (row)
    snp_info_container  _snp_info;              //!< Information about each snp (col)
    concurrent_umap     _flipped_cols;          //!< Columns which have been flipped
    atomic_vector       _splittable_cols;       //!< A vector of splittable columns
    
    // Solutions for the entire block 
    binary_vector       _haplo_one;             //!< The first haplotype
    binary_vector       _haplo_two;             //!< The second haplotype
public:
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Constructor to fill the block with data from the input file
    /// @param[in]  data_file       The file to fill the data with
    // ------------------------------------------------------------------------------------------------------
    Block(const char* data_file);
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the value of an element, if it exists, otherwise returns 3
    /// @param[in]  row_idx     The row index of the element
    /// @param[in]  col_idx     The column index of the element
    // ------------------------------------------------------------------------------------------------------
    uint8_t operator()(const size_t row_idx, const size_t col_idx) const;
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the number of subblocks in the block
    // ------------------------------------------------------------------------------------------------------
    inline size_t num_subblocks() const { return _splittable_cols.size() - _first_splittable; }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the start index of a subblock (or the end index of the previous one) -- returns 0 if
    ///             the given index is out of range
    /// @param[in]  i   The index of the subblock 
    // ------------------------------------------------------------------------------------------------------
    inline size_t subblock(const size_t i) const 
    { 
        return i < _splittable_cols.size() - _first_splittable ? _splittable_cols[_first_splittable + i] : 0;
    }
    
    // ------------------------------------------------------------------------------------------------------A
    /// @brief      Returns true if the requested column is monotone, false otherwise -- returns false if the
    ///             index is out of range
    /// @param[in]  i   The index of the column
    // ------------------------------------------------------------------------------------------------------
    inline bool is_monotone(const size_t i) const 
    {
        return i < _cols ? _snp_info.at(i).is_monotone() : false;
    }
    
    // ------------------------------------------------------------------------------------------------------A
    /// @brief      Returns true if the requested column is intrinsically herterozygous, false otherwise -- 
    ///             returns false if the index is out of range
    /// @param[in]  i   The index of the column
    // ------------------------------------------------------------------------------------------------------
    inline bool is_intrin_hetro(const size_t i) const 
    {
        return i < _cols ? (_snp_info.at(i).type() == IH) : false;
    }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the information for a snp
    /// @param[in]  i   The index of the snp (column)
    // ------------------------------------------------------------------------------------------------------
    inline const SnpInfo& snp_info(const size_t i) const { return _snp_info.at(i); }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the information for a read
    /// @param[in]  i   The index of the read (row)
    // ------------------------------------------------------------------------------------------------------
    inline const ReadInfo& read_info(const size_t i) const { return _read_info[i]; }    
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      The number of reads in the block (total number of rows)
    // ------------------------------------------------------------------------------------------------------
    inline size_t reads() const { return _rows; }

    // ------------------------------------------------------------------------------------------------------
    /// @brief      Merges the haplotype solution of a sub block into the final solution
    /// @param[in]  sub_block       The sub-block to get the solution from 
    /// @tparam     SubBlockType    The type of the sub-block
    // ------------------------------------------------------------------------------------------------------
    template <typename SubBlockType>
    void merge_haplotype(const SubBlockType& sub_block);
    
   // ------------------------------------------------------------------------------------------------------
    /// @brief      Determines the MEC score of the haplotpye 
    // ------------------------------------------------------------------------------------------------------
    void determine_mec_score() const;
    
    void print_haplotypes() const 
    {
        for (auto i = 0; i < _haplo_one.size() + 6; ++i) std::cout << "-";
        std::cout << "\nh  : "; 
        for (auto i = 0; i < _haplo_one.size(); ++i) std::cout << static_cast<unsigned>(_haplo_one.get(i));
        std::cout << "\nh` : ";
        for (auto i = 0; i < _haplo_two.size(); ++i) std::cout << static_cast<unsigned>(_haplo_two.get(i));
        std::cout << "\n";
        for (auto i = 0; i < _haplo_two.size() + 6; ++i) std::cout << "-";
        std::cout << "\n";
    }
private:
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Fills the block with data from the input fill
    /// @param[in]  data_file   The file to get the data from 
    // ------------------------------------------------------------------------------------------------------
    void fill(const char* data_file);
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Flips all elements of a column if there are more ones than zeros, and records that the
    ///             column has been flipped
    /// @param[in]  col_idx         The index of the column to flip
    /// @param[in]  col_start_row   The start row of the column
    /// @param[in]  col_end_row     The end row of the column
    // ------------------------------------------------------------------------------------------------------
    void flip_column_bits(const size_t col_idx, const size_t col_start_row, const size_t col_end_row);
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Processes a line of data
    /// @param      offset          The offset in the data container of the data
    /// @param      line            The data to proces
    /// @tparam     TokenPointer    The token pointer type
    /// @return     The new offset after processing
    // ------------------------------------------------------------------------------------------------------
    template <typename TokenPointer>
    size_t process_data(size_t offset, TokenPointer& line);

    // ------------------------------------------------------------------------------------------------------
    /// @brief      Processses a snp (column), checking if it is IH or NIH, and if it is montone, or flipping 
    ///             the bits if it has more ones than zeros
    // ------------------------------------------------------------------------------------------------------
    void process_snps(); 
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Sets the parameters for a column -- the start and end index
    /// @param[in]  col_idx     The index of the column to set the parameters for
    /// @param[in]  row_idx     The index of the row to update in teh column info
    /// @param[in]  value       The value of the element at row_idx, col_idx
    // ------------------------------------------------------------------------------------------------------
    void set_col_params(const size_t col_idx, const size_t row_idx, const uint8_t value);
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Sorts the (small in almost all cases) splittable vector, and removes and montone columns 
    ///             from the start of the vector
    // ------------------------------------------------------------------------------------------------------
    void sort_splittable_cols();
};

// ---------------------------------------------- IMPLEMENTATIONS -------------------------------------------

// ----------------------------------------------- PUBLIC ---------------------------------------------------

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
Block<Elements, ThreadsX, ThreadsY>::Block(const char* data_file)
: _rows{0}, _cols{0}, _first_splittable{0}, _last_aligned{0}, _read_info{0}, _splittable_cols{0} 
{
    fill(data_file);                    // Get the data from the input file
    process_snps();                     // Process the SNPs to determine block params
    
    // Resize the haplotypes
    _haplo_one.resize(_cols); _haplo_two.resize(_cols); 
} 

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
uint8_t Block<Elements, ThreadsX, ThreadsY>::operator()(const size_t row_idx, const size_t col_idx) const 
{
    // If the element exists
    return _read_info[row_idx].element_exists(col_idx) == true 
        ? _data.get(_read_info[row_idx].offset() + col_idx - _read_info[row_idx].start_index()) : 0x03;
} 

template <size_t Elements, size_t ThreadsX, size_t ThreadsY> template <typename SubBlockType>
void Block<Elements, ThreadsX, ThreadsY>::merge_haplotype(const SubBlockType& sub_block)
{
    const size_t start_col = _splittable_cols[sub_block.index() + _first_splittable];            
    const size_t end_col   = _splittable_cols[sub_block.index() + _first_splittable + 1];        
    size_t sub_haplo_idx   = 0;                             // Haplo idx in sub block
    bool   flip_all        = false;                         // If we need to flip all the bits 
  
    if (sub_block.index() == 0) _last_aligned = sub_block.base_start_row() - 2;

    // Check if we need to flip all bits
    if (_haplo_one.get(start_col) != sub_block.haplo_one().get(0) && !is_monotone(start_col))
        flip_all = true;
    
    // Go over all the columns and set the haplotypes 
    for (size_t col_idx = start_col; col_idx <= end_col; ++ col_idx) {
        // First check if the column is a monotone column, then the solution to the column's value
        if (is_monotone(col_idx)) {
            _haplo_one.set(col_idx, operator()(_snp_info[col_idx].start_index(), col_idx));
            _haplo_two.set(col_idx, operator()(_snp_info[col_idx].start_index(), col_idx));
        } else {
            // We need to get the solution from the sub block, but first check if this is a flipped column
            if ((_flipped_cols.find(col_idx) != _flipped_cols.end() && !flip_all) || flip_all) {
                // We flip the bits from the haplotype
                _haplo_one.set(col_idx, !sub_block.haplo_one().get(sub_haplo_idx));
                _haplo_two.set(col_idx, !sub_block.haplo_two().get(sub_haplo_idx));
                ++sub_haplo_idx;
            } else {
                // We don't need to flip any of the bits
                _haplo_one.set(col_idx, sub_block.haplo_one().get(sub_haplo_idx));
                _haplo_two.set(col_idx, sub_block.haplo_two().get(sub_haplo_idx));
                ++sub_haplo_idx;  
            }   
        }
    }
}

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
void Block<Elements, ThreadsX, ThreadsY>::determine_mec_score() const 
{
    size_t mec_score = 0;
    
    for (size_t read_idx = 0; read_idx < _rows; ++read_idx) {
        size_t contrib_one = 0, contrib_two = 0;
        for (size_t haplo_idx = 0; haplo_idx < _cols; ++haplo_idx) {
            // For the first haplotype
            if (_haplo_one.get(haplo_idx) != operator()(read_idx, haplo_idx) &&
                operator()(read_idx, haplo_idx) <= 1                        ) {
                    ++contrib_one;
            }
            if (_haplo_two.get(haplo_idx) != operator()(read_idx, haplo_idx) &&
                operator()(read_idx, haplo_idx) <= 1                        ) {
                    ++contrib_two;
            }
        }
        // Add the minimum contribution 
        mec_score += std::min(contrib_one, contrib_two);
    }
    std::cout << "MEC SCORE : " << mec_score << "\n";
}

// ------------------------------------------------- PRIVATE ------------------------------------------------

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
void Block<Elements, ThreadsX, ThreadsY>::fill(const char* data_file)
{
    // Open file and convert to string (for tokenizer)
    io::mapped_file_source file(data_file);
    if (!file.is_open()) throw std::runtime_error("Could not open input file =(!\n");
    
    std::string data(file.data(), file.size());

    // Create a tokenizer to tokenize by newline character and another by whitespace
    using tokenizer = boost::tokenizer<boost::char_separator<char>>;
    boost::char_separator<char> nwline_separator{"\n"};
    
    // Tokenize the data into lines
    tokenizer lines{data, nwline_separator};
    
    // Create a counter for the offset in the data container
    size_t offset = 0;
   
    // Get the data and store it in the data container 
    for (auto& line : lines) {
        offset = process_data(offset, line);
        ++_rows;
    }
    
    if (file.is_open()) file.close();
    
    // Set the number of columns 
    _cols = _snp_info.size();    
}

template <size_t Elements, size_t ThreadsX, size_t ThreadsY> template <typename TokenPointer>
size_t Block<Elements, ThreadsX, ThreadsY>::process_data(size_t         offset  ,
                                                         TokenPointer&  line    )
{
    // Create a tokenizer to tokenize by newline character and another by whitespace
    using tokenizer = boost::tokenizer<boost::char_separator<char>>;
    boost::char_separator<char> wspace_separator{" "}; 

    // Tokenize the line
    tokenizer elements{line, wspace_separator};

    std::string read_data;
    size_t start_index = 0, end_index = 0, counter = 0;
    for (auto token : elements) {
        if (counter == 0) 
            start_index = stoul(token);
        else if (counter == 1)
            end_index = stoul(token);
        else
            read_data = token;
        counter++;
    }
    _read_info.push_back(ReadInfo(_rows, start_index, end_index, offset));

    size_t col_idx = start_index;    
    // Put data into the data vector
    for (const auto& element : read_data) {
        switch (element) {
            case '0':
                _data.set(offset++, ZERO);
                set_col_params(col_idx, _rows, ZERO);
                break;
            case '1':
                _data.set(offset++, ONE);
                set_col_params(col_idx,_rows, ONE);
                break;
            case '-':
                _data.set(offset++, TWO);
                break;
            default:
                std::cerr << "Error reading input data - exiting =(\n";
                exit(1);
        } ++col_idx;
    }
    return offset;
}

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
void Block<Elements, ThreadsX, ThreadsY>::set_col_params(const size_t  col_idx,
                                                         const size_t  row_idx,
                                                         const uint8_t value  )
{
    if (_snp_info.find(col_idx) == _snp_info.end()) {
        // Not in map, so set start index to row index
        _snp_info[col_idx] = SnpInfo(row_idx, row_idx);
    } else {
        // In map, so start is set, set end 
        _snp_info[col_idx].end_index() = row_idx;
    }
    // Update the value counter
    value == ZERO ? _snp_info[col_idx].zeros()++
                  : _snp_info[col_idx].ones()++;
}

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
void Block<Elements, ThreadsX, ThreadsY>::process_snps()
{
    // We can use all the available cores for this 
    const size_t threads = (ThreadsX + ThreadsY) < _cols ? (ThreadsX + ThreadsY) : _cols;
    
    // Binary container for if a columns is splittable or not (not by default)
    binary_vector splittable_info(_cols);
    
    // Over each column in the row
    tbb::parallel_for(
        tbb::blocked_range<size_t>(0, threads),
        [&](const tbb::blocked_range<size_t>& thread_ids)
        {
            for (size_t thread_id = thread_ids.begin(); thread_id != thread_ids.end(); ++thread_id) {
                size_t thread_iters = ops::get_thread_iterations(thread_id, _cols, threads);
    
                // For each column we need to "walk" downwards and check how many non singular rows there are 
                for (size_t it = 0; it < thread_iters; ++it) {
                    size_t col_idx      = it * threads + thread_id;
                    size_t non_single   = 0;                                // Number of non singular columns
                    bool   splittable   = true;                             // Assume splittable
                    auto&  col_info     = _snp_info[col_idx];
                    
                    // For each of the elements in the column 
                    for (size_t row_idx = col_info.start_index(); row_idx <= col_info.end_index(); ++row_idx) {
                        if (_read_info[row_idx].length() > 1 && operator()(row_idx, col_idx) <= 1)
                            non_single++;
                        
                        // Check for the splittable condition
                        if (_read_info[row_idx].start_index() < col_idx && 
                            _read_info[row_idx].end_index()   > col_idx  )
                                splittable = false;
                    }
                  
                    // If the column fits the non-intrinsically heterozygous criteria, change the type
                    if (!(std::min(col_info.zeros(), col_info.ones()) >= (non_single / 2)) 
                           && !col_info.is_monotone()) {
                        col_info.set_type(NIH);
                    }
                    
                    // If there atre more 1's than 0's flip all the bits
                    //if (col_info.ones() > col_info.zeros() && !col_info.is_monotone()) 
                    //    flip_column_bits(col_idx, col_info.start_index(), col_info.end_index());
                    
                    // If the column is splittable, add it to the splittable info 
                    if (splittable && !col_info.is_monotone()) _splittable_cols.push_back(col_idx);
                }
            }
        }
    );
    // Need to sort the splittable columns in ascending order
    sort_splittable_cols();
}

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
void Block<Elements, ThreadsX, ThreadsY>::flip_column_bits(const size_t col_idx       , 
                                                           const size_t col_start_row ,
                                                           const size_t col_end_row   )
{
    for (size_t row_idx = col_start_row; row_idx <= col_end_row; ++row_idx) {
        size_t mem_offset    = _read_info[row_idx].offset() + col_idx - _read_info[row_idx].start_index(); 
        auto   element_value = _data.get(mem_offset);
        
        // Check that the element is not a gap, then set it
        if (element_value <= ONE) {                             
            element_value == ZERO 
                ? _data.set(mem_offset, ONE)
                : _data.set(mem_offset, ZERO);
        }
    }
    // Add that this column was flipped
    _flipped_cols[col_idx] = 0;
}

template <size_t Elements, size_t ThreadsX, size_t ThreadsY>
void Block<Elements, ThreadsX, ThreadsY>::sort_splittable_cols()
{
    // Sort the splittable vector -- this is still NlgN, so not really parallel
    tbb::parallel_sort(_splittable_cols.begin(), _splittable_cols.end(), std::less<size_t>());
    
    // Set the start index to be the first non-monotone column
    // tbb doesn't have erase and it'll be slow to erase from the front
    while (_snp_info[_splittable_cols[_first_splittable]].is_monotone()) ++_first_splittable;
    
    // Check that the last column is in the vector (just some error checking incase)
    if (_splittable_cols[_splittable_cols.size() - 1] != _cols - 1) 
        _splittable_cols.push_back(_cols - 1);
}


}           // End namespace haplo
#endif      // PARAHAPLO_BLOCK_HPP
