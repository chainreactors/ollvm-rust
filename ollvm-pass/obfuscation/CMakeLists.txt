set(OBFUSCATION_SOURCES
    CryptoUtils.cpp
    Utils.cpp
    ObfuscationPassManager.cpp
    ObfuscationOptions.cpp
    IndirectBranch.cpp
    IndirectCall.cpp
    IndirectGlobalVariable.cpp
    Flattening.cpp
    StringEncryption.cpp
    LegacyLowerSwitch.cpp
)

if(WIN32)
    list(APPEND OBFUSCATION_SOURCES obfuscation.def)
endif()

add_library(LLVMObfuscationx SHARED ${OBFUSCATION_SOURCES})

target_include_directories(LLVMObfuscationx PRIVATE ${CMAKE_SOURCE_DIR}/obfuscation)

# intrinsics_gen only exists when building within the LLVM source tree
if(TARGET intrinsics_gen)
    add_dependencies(LLVMObfuscationx intrinsics_gen)
endif()
if(TARGET LLVMLinker)
    add_dependencies(LLVMObfuscationx LLVMLinker)
endif()

llvm_map_components_to_libnames(llvm_libs support core irreader linker)
target_link_libraries(LLVMObfuscationx PRIVATE ${llvm_libs})

if(NOT WIN32)
    # Export the plugin entry point symbol on Linux/macOS
    target_link_options(LLVMObfuscationx PRIVATE
        "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/LLVMObfuscationx.map"
    )
    # Use -fPIC for shared library
    set_target_properties(LLVMObfuscationx PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()
