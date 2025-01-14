/*
 * Copyright (c) 2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cudf/column/column.hpp>
#include <cudf/detail/offsets_iterator_factory.cuh>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/strings/detail/strings_children.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>

namespace cudf {
namespace strings {
namespace detail {
namespace experimental {

/**
 * @brief Kernel used by make_strings_children for calling the given functor
 *
 * @tparam SizeAndExecuteFunction Functor type to call in each thread
 *
 * @param fn Functor to call in each thread
 * @param exec_size Total number of threads to be processed by this kernel
 */
template <typename SizeAndExecuteFunction>
CUDF_KERNEL void strings_children_kernel(SizeAndExecuteFunction fn, size_type exec_size)
{
  auto tid = cudf::detail::grid_1d::global_thread_id();
  if (tid < exec_size) { fn(tid); }
}

/**
 * @brief Creates child offsets and chars data by applying the template function that
 * can be used for computing the output size of each string as well as create the output
 *
 * The `size_and_exec_fn` is expected declare an operator() function with a size_type parameter
 * and 3 member variables:
 * - `d_sizes`: output size in bytes of each output row for the 1st pass call
 * - `d_chars`: output buffer for new string data for the 2nd pass call
 * - `d_offsets`: used for addressing the specific output row data in `d_chars`
 *
 * The 1st pass call computes the output sizes and is identified by `d_chars==nullptr`.
 * Null rows should be set with an output size of 0.
 *
 * @code{.cpp}
 * struct size_and_exec_fn {
 *  size_type* d_sizes;
 *  char* d_chars;
 *  input_offsetalator d_offsets;
 *
 *   __device__ void operator()(size_type thread_idx)
 *   {
 *     // functor-specific logic to resolve out_idx from thread_idx
 *     if( !d_chars ) {
 *       d_sizes[out_idx] = output_size;
 *     } else {
 *       auto d_output = d_chars + d_offsets[out_idx];
 *       // write characters to d_output
 *     }
 *   }
 * };
 * @endcode
 *
 * @tparam SizeAndExecuteFunction Functor type with an operator() function accepting
 *         an index parameter and three member variables: `size_type* d_sizes`
 *         `char* d_chars`, and `input_offsetalator d_offsets`.
 *
 * @param size_and_exec_fn This is called twice. Once for the output size of each string
 *        and once again to fill in the memory pointed to by d_chars.
 * @param exec_size Number of threads for executing the `size_and_exec_fn` function
 * @param strings_count Number of strings
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned columns' device memory
 * @return Offsets child column and chars vector for creating a strings column
 */
template <typename SizeAndExecuteFunction>
auto make_strings_children(SizeAndExecuteFunction size_and_exec_fn,
                           size_type exec_size,
                           size_type strings_count,
                           rmm::cuda_stream_view stream,
                           rmm::device_async_resource_ref mr)
{
  // This is called twice -- once for computing sizes and once for writing chars.
  // Reducing the number of places size_and_exec_fn is inlined speeds up compile time.
  auto for_each_fn = [exec_size, stream](SizeAndExecuteFunction& size_and_exec_fn) {
    auto constexpr block_size = 256;
    auto grid                 = cudf::detail::grid_1d{exec_size, block_size};
    strings_children_kernel<<<grid.num_blocks, block_size, 0, stream.value()>>>(size_and_exec_fn,
                                                                                exec_size);
  };

  // Compute the output sizes
  auto output_sizes        = rmm::device_uvector<size_type>(strings_count, stream);
  size_and_exec_fn.d_sizes = output_sizes.data();
  size_and_exec_fn.d_chars = nullptr;
  for_each_fn(size_and_exec_fn);

  // Convert the sizes to offsets
  auto [offsets_column, bytes] = cudf::strings::detail::make_offsets_child_column(
    output_sizes.begin(), output_sizes.end(), stream, mr);
  size_and_exec_fn.d_offsets =
    cudf::detail::offsetalator_factory::make_input_iterator(offsets_column->view());

  // Now build the chars column
  rmm::device_uvector<char> chars(bytes, stream, mr);
  size_and_exec_fn.d_chars = chars.data();

  // Execute the function fn again to fill in the chars data.
  if (bytes > 0) { for_each_fn(size_and_exec_fn); }

  return std::pair(std::move(offsets_column), std::move(chars));
}

/**
 * @brief Creates child offsets and chars columns by applying the template function that
 * can be used for computing the output size of each string as well as create the output
 *
 * The `size_and_exec_fn` is expected declare an operator() function with a size_type parameter
 * and 3 member variables:
 * - `d_sizes`: output size in bytes of each output row for the 1st pass call
 * - `d_chars`: output buffer for new string data for the 2nd pass call
 * - `d_offsets`: used for addressing the specific output row data in `d_chars`
 *
 * The 1st pass call computes the output sizes and is identified by `d_chars==nullptr`.
 * Null rows should be set with an output size of 0.
 *
 * @code{.cpp}
 * struct size_and_exec_fn {
 *  size_type* d_sizes;
 *  char* d_chars;
 *  input_offsetalator d_offsets;
 *
 *   __device__ void operator()(size_type idx)
 *   {
 *     if( !d_chars ) {
 *       d_sizes[idx] = output_size;
 *     } else {
 *       auto d_output = d_chars + d_offsets[idx];
 *       // write characters to d_output
 *     }
 *   }
 * };
 * @endcode
 *
 * @tparam SizeAndExecuteFunction Functor type with an operator() function accepting
 *         an index parameter and three member variables: `size_type* d_sizes`
 *         `char* d_chars`, and `input_offsetalator d_offsets`.
 *
 * @param size_and_exec_fn This is called twice. Once for the output size of each string
 *        and once again to fill in the memory pointed to by `d_chars`.
 * @param strings_count Number of strings
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned columns' device memory
 * @return Offsets child column and chars vector for creating a strings column
 */
template <typename SizeAndExecuteFunction>
auto make_strings_children(SizeAndExecuteFunction size_and_exec_fn,
                           size_type strings_count,
                           rmm::cuda_stream_view stream,
                           rmm::device_async_resource_ref mr)
{
  return make_strings_children(size_and_exec_fn, strings_count, strings_count, stream, mr);
}

}  // namespace experimental
}  // namespace detail
}  // namespace strings
}  // namespace cudf
