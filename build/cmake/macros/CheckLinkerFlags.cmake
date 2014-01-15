 ###############################################################
 # 
 # Copyright 2014 Red Hat, Inc. 
 # 
 # Licensed under the Apache License, Version 2.0 (the "License"); you 
 # may not use this file except in compliance with the License.  You may 
 # obtain a copy of the License at 
 # 
 #    http://www.apache.org/licenses/LICENSE-2.0 
 # 
 # Unless required by applicable law or agreed to in writing, software 
 # distributed under the License is distributed on an "AS IS" BASIS, 
 # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 # See the License for the specific language governing permissions and 
 # limitations under the License. 
 # 
 ############################################################### 

macro(check_cxx_linker_flag _flag _var)
    message("Performing Test ${_var}")        
    unset(${_var})

    set(_stub_code "int main() { return 0; }")

    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/build/cmake/stub_code.cpp "${_stub_code}\n")

    execute_process(COMMAND ${CMAKE_CXX_COMPILER} ${_flag} ${CMAKE_CURRENT_BINARY_DIR}/build/cmake/stub_code.cpp
                    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/build/cmake
                    ERROR_VARIABLE _stderr)

    if (NOT _stderr)
        message("Performing Test ${_var} - Success")
        set(${_var} 1)
    else()
        message("Performing Test ${_var} - Failed")
    endif()
endmacro(check_cxx_linker_flag)
