#include "data_converter.hpp"

#include <boost/iostreams/device/mapped_file.hpp>
#include <boost/tokenizer.hpp>

#include <iostream>
#include <vector>
#include <algorithm>

namespace haplo {

namespace io = boost::iostreams;
using namespace io;
    
#define ZERO    0x00
#define ONE     0x01
#define TWO     0x02
#define THREE   0x03

DataConverter::DataConverter(const char* data_file):
_data(0), _rows(0), _columns(0), _aBase(0), _cBase(0), _tBase(0), _gBase(0)
{
    convert_dataset_to_binary(data_file);
}

void DataConverter::print() const 
{
    //for (const auto& element : _data) std::cout << element;
    
    //std::cout << "Ref: " << std::endl;
    
    //for (auto i = 0; i < 23; ++i) std::cout << _chr1_ref_seq.at(i);

    
    //std::cout << std::endl << "Alt: " << std::endl;
    
   // for (auto i = 0; i < 23; ++i) std::cout << _chr1_alt_seq.at(i);
}

void DataConverter::convert_simulated_data_to_binary(const char* data_file)
{
    // Open file and convert to string (for tokenizer)
    io::mapped_file_source file(data_file);
    if (!file.is_open()) throw std::runtime_error("Could not open input file =(!\n");
    
    std::string data(file.data(), file.size());
    
    // Create a tokenizer to tokenize by newline character
    using tokenizer = boost::tokenizer<boost::char_separator<char>>;
    boost::char_separator<char> nwline_separator{"\n"};
    
    // Tokenize the data into lines and create a 
    tokenizer lines{data, nwline_separator};

    _columns = lines.begin()->length();
    
    _aBase.resize(_columns);
    _cBase.resize(_columns);
    _tBase.resize(_columns);
    _gBase.resize(_columns);
    
    // Get the data and store it in the data container
    for (const auto& line : lines) {
       // std::cout << line << std::endl;
        find_base_occurrance(line);
        _rows++;
    }
    
    determine_simulated_ref_sequence();
    
    for (const auto& line : lines) {
        process_line(line);
    }
    
    if (file.is_open()) file.close();
}
    
void DataConverter::convert_dataset_to_binary(const char* data_file)
{
        // Open file and convert to string (for tokenizer)
        io::mapped_file_source file(data_file);
        if (!file.is_open()) throw std::runtime_error("Could not open input file =(!\n");
        
        std::string data(file.data(), file.size());
        
        // Create a tokenizer to tokenize by newline character
        using tokenizer = boost::tokenizer<boost::char_separator<char>>;
        boost::char_separator<char> nwline_separator{"\n"};
        
        // Tokenize the data into lines and create a
        tokenizer lines{data, nwline_separator};
        
        //_columns = lines.begin()->length();
        size_t header_length = 5;
    
        for (const auto& line : lines) {
            std::cout << "line: " << line << std::endl;
            if(header_length == 0) {
                //std::cout << header_length << std::endl;
                determine_dataset_ref_sequence(line);
                _rows++;
                header_length = 5;
            }
            header_length--;
             std::cout << "i am here 1" << std::endl;
        }
    
        
        /*for (const auto& line : lines) {
            process_line(line);
            //row++;
        }*/
        
        if (file.is_open()) file.close();
}

    
template <typename TP>    
void DataConverter::find_base_occurrance(const TP& line)
{
    // count occurances of the bases (a,c,t,g) in each column of a line
    for(size_t i = 0; i < _columns; ++i) {
        if(line[i] == 'a')
            _aBase.push_back(_aBase.at(i)++);
        else if(line[i] == 'c')
            _cBase.push_back(_cBase.at(i)++);
        else if(line[i] == 't')
            _tBase.push_back(_tBase.at(i)++);
        else if(line[i] == 'g')
            _gBase.push_back(_gBase.at(i)++);
    }
}

void DataConverter::determine_simulated_ref_sequence()
{
    // Underscores, not camelcase -- base_occurance
    size_t base_occurance[4];
    // spaces between for and the bracket
    // ++i not i++
    // not i=0, i = 0
    // use size_t, int wont be big enough
    for (size_t i = 0 ; i < _columns; i++) {
        base_occurance[0] = {_aBase.at(i)};
        base_occurance[1] = {_cBase.at(i)};
        base_occurance[2] = {_tBase.at(i)};
        base_occurance[3] = {_gBase.at(i)};
        
        std::sort(base_occurance, base_occurance + 4);
        
        if(_aBase.at(i) == base_occurance[3])
            _refSeq.push_back('a');
        else if(_cBase.at(i) == base_occurance[3])
            _refSeq.push_back('c');
        else if(_tBase.at(i) == base_occurance[3])
            _refSeq.push_back('t');
        else if(_gBase.at(i) == base_occurance[3])
            _refSeq.push_back('g');
        
        if(_aBase.at(i) == base_occurance[2])
            _altSeq.push_back('a');
        else if(_cBase.at(i) == base_occurance[2])
            _altSeq.push_back('c');
        else if(_tBase.at(i) == base_occurance[2])
            _altSeq.push_back('t');
        else if(_gBase.at(i) == base_occurance[2])
            _altSeq.push_back('g');
    }

    
}
    
template <typename TP>
void DataConverter::determine_dataset_ref_sequence(const TP& token_pointer)
{
        //Create a tokenizer to tokenize by newline character and another by whitespace
        using tokenizer = boost::tokenizer<boost::char_separator<char>>;
        boost::char_separator<char> wspace_separator{" "};

        tokenizer   elements{token_pointer, wspace_separator};
        size_t column_counter = 0;

    
        for (auto& e : elements) {
            //std::cout << e << std::endl;
            
               //if() {
               //}
            
                    if(column_counter == 1){
                        //_chr1_ref_seq.push_back(static_cast<size_t>(e));
                    }
                    else if(column_counter == 3){
                        //std::cout << "col_count: " << e[0] << std::endl;
                        _chr1_ref_seq.push_back(e[0]);
                    }
                    else if(column_counter == 4){
                        _chr1_alt_seq.push_back(e[0]);
                    }
                    else if(column_counter == 9){
                        //_haplotype_one.push_back(convert_char_to_byte(e[0]));
                        //_haplotype_one.push_back(convert_char_to_byte(e[2]));
                    }
                //}
                /*else {
                        
                        std::cerr << "Error reading input data - exiting =(\n";
                        exit(1);
                    
                }*/
            
            column_counter++;
        }
    std::cout << "i am here 2" << std::endl;
}
                    
byte DataConverter::convert_char_to_byte(char input)
{
    switch(input){
            case 'a':
                return ZERO;
            case 'c':
                return ONE;
            case 't':
                return TWO;
            case 'g':
                return THREE;
    }
    
}
                    
char DataConverter::convert_byte_to_char(byte input)
{
    switch(input){
        case ZERO:
            return 'a';
        case ONE:
            return 'c';
        case TWO:
            return 't';
        case THREE:
            return 'g';
    }
    
}
    

    
    
template <typename TP>
void DataConverter::process_line(const TP& line) 
{
    //test examples
    //std::string referenceAllele = "ttcaaaataatgcactgtgaccaacccttt";
    //std::string alternateAllele = "cagctgtgctgcacaaacataagtaatcaa";

    // { brackets go on the same line inside functions 
    // only use { on a new line for the start of a function
    for (size_t i = 0; i < _columns; ++i) {
        if(line[i] == _refSeq.at(i)) {
            _data.push_back('1');
        }
        else if(line[i] == '-') {
            _data.push_back('-');
        }
        else {
            _data.push_back('0');
        }
        // Add in the space
        _data.push_back(' ');
    }
    // Add in the newline character
    _data.push_back('\n');
}

void DataConverter::write_data_to_file(const char* filename)
{
    // Create the parameters for the output file
    io::mapped_file_params file_params(filename);
    
    // Resize the file
    file_params.new_file_size = sizeof(char) * _data.size();
    
    // Open file and check that it opened
    io::mapped_file_sink output_file(file_params);
    if (!output_file.is_open()) throw std::runtime_error("Could not open output file =(!\n");
    
    // Copy the data to the file
    std::copy(_data.begin(), _data.end(), output_file.data());
    
    // Close the file
    if (output_file.is_open()) output_file.close();
}
    
}// End namespcea haplo
