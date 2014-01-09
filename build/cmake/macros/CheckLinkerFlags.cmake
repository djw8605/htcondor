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
    # This function is encapsulated voodo, although it appears to work correctly:
    # http://www.cmake.org/pipermail/cmake/2011-July/045525.html
    # If there is better standardized support for linker flag checking,
    # we should consider using that instead.
    set(_save_req ${CMAKE_REQUIRED_FLAGS})
    set(CMAKE_REQUIRED_FLAGS ${_flag})
    check_cxx_compiler_flag("" ${_var})
    set(CMAKE_REQUIRED_FLAGS ${_save_req})
endmacro(check_cxx_linker_flag)
