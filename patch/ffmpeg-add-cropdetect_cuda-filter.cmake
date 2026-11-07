# Adds the cropdetect_cuda filter to an FFmpeg checkout. Safe to run again.
# Usage: cmake -DSOURCE_DIR=<ffmpeg> [-DPATCH=<patch>] -P <this file>
# PATCH defaults to the patch of the same name next to this file.

if(NOT PATCH)
    string(REGEX REPLACE "\\.cmake$" ".patch" PATCH "${CMAKE_CURRENT_LIST_FILE}")
endif()

# The new files come from the patch.
set(new_files
    libavfilter/vf_cropdetect_cuda.c
    libavfilter/vf_cropdetect_cuda.cu
)

set(include_options "")
foreach(file IN LISTS new_files)
    file(REMOVE "${SOURCE_DIR}/${file}")
    list(APPEND include_options "--include=${file}")
endforeach()
execute_process(
    COMMAND git -C "${SOURCE_DIR}" apply ${include_options} "${PATCH}"
    COMMAND_ERROR_IS_FATAL ANY
)
foreach(file IN LISTS new_files)
    if(NOT EXISTS "${SOURCE_DIR}/${file}")
        message(FATAL_ERROR "${PATCH} does not create ${file}")
    endif()
endforeach()

# The registration lines are inserted by anchor, as their hunks break whenever
# FFmpeg changes a neighbouring line: <line> goes after the only line of <file>
# that starts with <anchor>.
function(insert_after file anchor line)
    file(READ "${SOURCE_DIR}/${file}" content)
    string(FIND "${content}" "\n${line}\n" existing_position)
    if(NOT existing_position EQUAL -1)
        return()
    endif()

    string(FIND "${content}" "\n${anchor}" first_position)
    string(FIND "${content}" "\n${anchor}" last_position REVERSE)
    if(first_position EQUAL -1)
        message(FATAL_ERROR "${file}: no line starts with ${anchor}")
    elseif(NOT first_position EQUAL last_position)
        message(FATAL_ERROR "${file}: more than one line starts with ${anchor}")
    endif()

    math(EXPR anchor_start "${first_position} + 1")
    string(SUBSTRING "${content}" ${anchor_start} -1 content_from_anchor)
    string(FIND "${content_from_anchor}" "\n" anchor_line_length)
    math(EXPR insert_at "${anchor_start} + ${anchor_line_length} + 1")
    string(SUBSTRING "${content}" 0 ${insert_at} head)
    string(SUBSTRING "${content}" ${insert_at} -1 tail)
    file(WRITE "${SOURCE_DIR}/${file}" "${head}${line}\n${tail}")
endfunction()

insert_after(configure
    [[cropdetect_filter_deps=]]
    [[cropdetect_cuda_filter_deps="gpl ffnvcodec"]])
insert_after(configure
    [[cropdetect_cuda_filter_deps=]]
    [[cropdetect_cuda_filter_deps_any="cuda_nvcc cuda_llvm"]])
insert_after(libavfilter/Makefile
    [[OBJS-$(CONFIG_CROPDETECT_FILTER)]]
    [[OBJS-$(CONFIG_CROPDETECT_CUDA_FILTER)        += vf_cropdetect_cuda.o vf_cropdetect_cuda.ptx.o \
                                                cuda/load_helper.o]])
insert_after(libavfilter/allfilters.c
    [[extern const FFFilter ff_vf_cropdetect;]]
    [[extern const FFFilter ff_vf_cropdetect_cuda;]])
# The clang build of the kernels gets the CUDA keywords from this header, and
# no kernel declared shared memory before.
insert_after(compat/cuda/cuda_runtime.h
    [[#define __device__ ]]
    [[#define __shared__ __attribute__((shared))]])
