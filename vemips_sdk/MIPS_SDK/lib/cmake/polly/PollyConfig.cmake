# This file allows users to call find_package(Polly) and pick up our targets.

# Compute the installation prefix from this LLVMConfig.cmake file location.
get_filename_component(POLLY_INSTALL_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
get_filename_component(POLLY_INSTALL_PREFIX "${POLLY_INSTALL_PREFIX}" PATH)
get_filename_component(POLLY_INSTALL_PREFIX "${POLLY_INSTALL_PREFIX}" PATH)
get_filename_component(POLLY_INSTALL_PREFIX "${POLLY_INSTALL_PREFIX}" PATH)

set(LLVM_VERSION 20.1.6)
find_package(LLVM ${LLVM_VERSION} EXACT REQUIRED CONFIG
             HINTS "${POLLY_INSTALL_PREFIX}/lib/cmake/llvm")

set(Polly_CMAKE_DIR ${CMAKE_CURRENT_LIST_DIR})
set(Polly_BUNDLED_ISL ON)

set(Polly_DEFINITIONS ${LLVM_DEFINITIONS})
set(Polly_INCLUDE_DIRS ${POLLY_INSTALL_PREFIX}/include;${POLLY_INSTALL_PREFIX}/include/polly ${LLVM_INCLUDE_DIRS})
set(Polly_LIBRARY_DIRS ${POLLY_INSTALL_PREFIX}/lib)
set(Polly_EXPORTED_TARGETS Polly;PollyISL)
set(Polly_LIBRARIES ${LLVM_LIBRARIES} ${Polly_EXPORTED_TARGETS})

# Imported Targets:

if (NOT TARGET PollyISL)
  add_library(PollyISL STATIC IMPORTED)
endif()

if (NOT TARGET Polly)
  add_library(Polly STATIC IMPORTED)
  set_property(TARGET Polly PROPERTY INTERFACE_LINK_LIBRARIES PollyISL)
endif()

if (NOT TARGET LLVMPolly)
  add_library(LLVMPolly  IMPORTED)
  set_property(TARGET LLVMPolly PROPERTY INTERFACE_LINK_LIBRARIES Polly)
endif()

# Exported locations:
file(GLOB CONFIG_FILES "${Polly_CMAKE_DIR}/PollyExports-*.cmake")
foreach(f ${CONFIG_FILES})
  include(${f})
endforeach()
