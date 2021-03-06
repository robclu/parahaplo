// ----------------------------------------------------------------------------------------------------------
/// @file   Header file for parahaplo snp info class for the GPU -- smaller than CPU class
// ----------------------------------------------------------------------------------------------------------

#ifndef PARHAPLO_SNP_INFO_GPU_H
#define PARHAPLO_SNP_INFO_GPU_H

#include "cuda_defs.h"
#include "snp_info.hpp"
#include <stdint.h>

namespace haplo {
           
// ----------------------------------------------------------------------------------------------------------
/// @class      SnpInfoGpu
/// @brief      Stores some information about a SNP for the GPU
// ----------------------------------------------------------------------------------------------------------
class SnpInfoGpu {
private:
    size_t      _start_idx;     //!< Start read index of the snp
    size_t      _end_idx;       //!< End read index of the snp
    size_t      _elements;      //!< Number of elements in the snp (0's or 1's -- not gaps)
    uint8_t     _type;          //!< IH or NIH
public:
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Constructor
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    SnpInfoGpu()
    : _start_idx{0}, _end_idx{0}, _elements{0}, _type{0} {}

    // ------------------------------------------------------------------------------------------------------
    /// @brief      Constructor -- sets the values
    /// @param[in]  snp_info        The cpu side snp info to create this snp from
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    SnpInfoGpu(const SnpInfo& other) noexcept
    : _start_idx(other.start_index())        , 
      _end_idx(other.end_index())            , 
      _elements(other.ones() + other.zeros()),
      _type(other.type())                    {}
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the staet index of the read 
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline size_t start_index() const { return _start_idx; }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the staet index of the read 
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline size_t& start_index() { return _start_idx; }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the end index of the read
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline size_t end_index() const { return _end_idx; }

    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the end index of the read
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline size_t& end_index() { return _end_idx; }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Sets the type of the snp
    /// @param[in]  value   The value to set the type to
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline void set_type(const uint8_t value) { _type = value & 0x03; }

    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the type of the snp
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline size_t type() const { return _type; }    

    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the length of the read 
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD
    inline size_t length() const { return _end_idx - _start_idx + 1; }
    
    // ------------------------------------------------------------------------------------------------------
    /// @brief      Gets the number of elements in the snp
    // ------------------------------------------------------------------------------------------------------
    CUDA_HD 
    inline size_t elements() const { return _elements; }
};

}           // End namespace haplo
#endif      // PARAHAPLO_SNP_INFO_GPU_H
