/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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

#include "cudf/utilities/bit.hpp"
#include "nested_json.hpp"
#include "thrust/iterator/constant_iterator.h"
#include "thrust/iterator/transform_iterator.h"
#include "thrust/iterator/transform_output_iterator.h"
#include <io/utilities/column_type_histogram.hpp>
#include <io/utilities/parsing_utils.cuh>
#include <io/utilities/type_inference.cuh>

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/detail/utilities/visitor_overload.hpp>
#include <cudf/io/detail/data_casting.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/count.h>
#include <thrust/for_each.h>
#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/permutation_iterator.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/sort.h>
#include <thrust/transform.h>
#include <thrust/unique.h>

#include <algorithm>
#include <cstdint>

#define _CONCAT_(x, y) x##y
#define CONCAT(x, y)   _CONCAT_(x, y)
#define NVTX3_SCOPED_RANGE_IN(D, tag)                                                        \
  ::nvtx3::registered_message<D> const CONCAT(nvtx3_scope_name__,                            \
                                              __LINE__){std::string(__func__) + "::" + tag}; \
  ::nvtx3::event_attributes const CONCAT(nvtx3_scope_attr__,                                 \
                                         __LINE__){CONCAT(nvtx3_scope_name__, __LINE__)};    \
  ::nvtx3::domain_thread_range<D> const CONCAT(nvtx3_range__,                                \
                                               __LINE__){CONCAT(nvtx3_scope_attr__, __LINE__)};

#define CUDF_SCOPED_RANGE(tag) NVTX3_SCOPED_RANGE_IN(cudf::libcudf_domain, tag)
namespace cudf::io::json {
namespace detail {
void fill_schema_type_for_tree(device_json_column& root_column,
                               cudf::io::json_reader_options const& options);

// DEBUG prints
auto to_cat = [](auto v) -> std::string {
  switch (v) {
    case NC_STRUCT: return " S";
    case NC_LIST: return " L";
    case NC_STR: return " \"";
    case NC_VAL: return " V";
    case NC_FN: return " F";
    case NC_ERR: return "ER";
    default: return "UN";
  };
};
auto to_int    = [](auto v) { return std::to_string(static_cast<int>(v)); };
auto print_vec = [](auto const& cpu, auto const name, auto converter) {
  for (auto const& v : cpu)
    printf("%3s,", converter(v).c_str());
  std::cout << name << std::endl;
};

void print_tree(host_span<SymbolT const> input,
                tree_meta_t const& d_gpu_tree,
                rmm::cuda_stream_view stream)
{
  print_vec(cudf::detail::make_std_vector_async(d_gpu_tree.node_categories, stream),
            "node_categories",
            to_cat);
  print_vec(cudf::detail::make_std_vector_async(d_gpu_tree.parent_node_ids, stream),
            "parent_node_ids",
            to_int);
  print_vec(
    cudf::detail::make_std_vector_async(d_gpu_tree.node_levels, stream), "node_levels", to_int);
  auto node_range_begin = cudf::detail::make_std_vector_async(d_gpu_tree.node_range_begin, stream);
  auto node_range_end   = cudf::detail::make_std_vector_async(d_gpu_tree.node_range_end, stream);
  print_vec(node_range_begin, "node_range_begin", to_int);
  print_vec(node_range_end, "node_range_end", to_int);
  for (int i = 0; i < int(node_range_begin.size()); i++) {
    printf("%3s ",
           std::string(input.data() + node_range_begin[i], node_range_end[i] - node_range_begin[i])
             .c_str());
  }
  printf(" (JSON)\n");
}

/**
 * @brief Retrieves the parse_options to be used for type inference and type casting
 *
 * @param options The reader options to influence the relevant type inference and type casting
 * options
 */
cudf::io::parse_options parsing_options(cudf::io::json_reader_options const& options);

/**
 * @brief Infer the type of each column in column hierarchy
 * List, Struct column
 *
 * @param num_columns
 * @param tree
 * @param sorted_col_ids
 * @param sorted_node_ids
 * @param input
 * @param options
 * @param stream
 * @return
 */
rmm::device_uvector<cudf::type_id> type_infer_column_tree(
  size_type num_columns,
  tree_meta_t& tree,
  device_span<NodeIndexT> sorted_col_ids,
  device_span<NodeIndexT> sorted_node_ids,
  device_span<SymbolT const> input,
  cudf::io::json_reader_options const& options,
  rmm::cuda_stream_view stream)
{
  CUDF_FUNC_RANGE();
  auto parse_opts = parsing_options(options);  // holds device_uvector<trie>.

  // column_type_histogram for type inference
  auto column_strings_begin = thrust::make_transform_iterator(
    thrust::make_counting_iterator<size_type>(0),
    // sorted_node_ids.begin(),
    [node_categories  = tree.node_categories.begin(),
     node_range_begin = tree.node_range_begin.begin(),
     node_range_end   = tree.node_range_end.begin()] __device__(auto const node_id) {
      if (node_categories[node_id] == NC_VAL or node_categories[node_id] == NC_STR) {
        return thrust::tuple<size_type, size_type>{
          node_range_begin[node_id], node_range_end[node_id] - node_range_begin[node_id]};
      } else {
        return thrust::tuple<size_type, size_type>{0, 0};
        // TODO use sentinel? or how about inferring struct/list type too? is it useful?
      }
    });
  auto hist_it = thrust::make_transform_iterator(
    column_strings_begin,
    cudf::io::detail::convert_to_histograms<json_inference_options_view>{parse_opts.json_view(),
                                                                         input});

  rmm::device_uvector<cudf::io::column_type_bool_any16_t> column_type_histogram_bools(
    tree.node_categories.size(), stream);

  thrust::copy(rmm::exec_policy(stream),
               hist_it,
               hist_it + tree.node_categories.size(),
               column_type_histogram_bools.begin());

  rmm::device_uvector<cudf::type_id> inferred_types(num_columns, stream);
  {
    CUDF_SCOPED_RANGE("histogram");
    rmm::device_uvector<cudf::io::column_type_bool_any16_t> column_type_histogram_counts(
      num_columns, stream);
    thrust::reduce_by_key(rmm::exec_policy(stream),
                          sorted_col_ids.begin(),
                          sorted_col_ids.end(),
                          thrust::make_permutation_iterator(column_type_histogram_bools.begin(),
                                                            sorted_node_ids.begin()),
                          thrust::make_discard_iterator(),
                          column_type_histogram_counts.begin(),
                          thrust::equal_to{},
                          cudf::io::detail::custom_sum{});

    auto get_type_id = [] __device__(auto const& cinfo) {
      auto int_count_total = cinfo.big_int_count() or cinfo.negative_small_int_count() or
                             cinfo.positive_small_int_count();
      if (cinfo.valid_count() == false) {
        // Entire column is NULL; allocate the smallest amount of memory
        return type_id::INT8;
      } else if (cinfo.string_count()) {
        return type_id::STRING;
      } else if (cinfo.datetime_count()) {
        // CUDF_FAIL("Date time is inferred as string.\n");
        return type_id::EMPTY;
      } else if (cinfo.float_count() || (int_count_total and cinfo.null_count())) {
        return type_id::FLOAT64;
      } else if (cinfo.big_int_count() == false && int_count_total) {
        return type_id::INT64;
      } else if (cinfo.big_int_count() && cinfo.negative_small_int_count()) {
        return type_id::STRING;
      } else if (cinfo.big_int_count()) {
        return type_id::UINT64;
      } else if (cinfo.bool_count()) {
        return type_id::BOOL8;
      }
      // CUDF_FAIL("Data type inference failed.\n");
      return type_id::EMPTY;
    };
    CUDF_SCOPED_RANGE("get_type_id");
    thrust::transform(rmm::exec_policy(stream),
                      column_type_histogram_counts.begin(),
                      column_type_histogram_counts.end(),
                      inferred_types.begin(),
                      get_type_id);
  }
  return inferred_types;
}

/**
 * @brief Reduces node tree representation to column tree representation.
 *
 * @param tree Node tree representation of JSON string
 * @param col_ids Column ids of nodes
 * @param row_offsets Row offsets of nodes
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @return A tuple of column tree representation of JSON string, column ids of columns, and
 * max row offsets of columns
 */
std::tuple<tree_meta_t,
           rmm::device_uvector<NodeIndexT>,
           rmm::device_uvector<size_type>,
           rmm::device_uvector<cudf::type_id>>
reduce_to_column_tree(device_span<SymbolT const> input,
                      cudf::io::json_reader_options const& options,
                      tree_meta_t& tree,
                      device_span<NodeIndexT> col_ids,
                      device_span<size_type> row_offsets,
                      rmm::cuda_stream_view stream)
{
  CUDF_FUNC_RANGE();
  //   1. sort_by_key {col_id}, {row_offset} stable
  rmm::device_uvector<NodeIndexT> node_ids(row_offsets.size(), stream);
  thrust::sequence(rmm::exec_policy(stream), node_ids.begin(), node_ids.end());
  thrust::stable_sort_by_key(rmm::exec_policy(stream),
                             col_ids.begin(),
                             col_ids.end(),
                             thrust::make_zip_iterator(node_ids.begin(), row_offsets.begin()));
  auto num_columns = thrust::unique_count(rmm::exec_policy(stream), col_ids.begin(), col_ids.end());

  // 2. reduce_by_key {col_id}, {row_offset}, max.
  rmm::device_uvector<NodeIndexT> unique_col_ids(num_columns, stream);
  rmm::device_uvector<size_type> max_row_offsets(num_columns, stream);
  thrust::reduce_by_key(rmm::exec_policy(stream),
                        col_ids.begin(),
                        col_ids.end(),
                        row_offsets.begin(),
                        unique_col_ids.begin(),
                        max_row_offsets.begin(),
                        thrust::equal_to<size_type>(),
                        thrust::maximum<size_type>());

  // 3. reduce_by_key {col_id}, {node_categories} - custom opp (*+v=*, v+v=v, *+#=E)
  rmm::device_uvector<NodeT> column_categories(num_columns, stream);
  thrust::reduce_by_key(
    rmm::exec_policy(stream),
    col_ids.begin(),
    col_ids.end(),
    thrust::make_permutation_iterator(tree.node_categories.begin(), node_ids.begin()),
    unique_col_ids.begin(),
    column_categories.begin(),
    thrust::equal_to<size_type>(),
    [] __device__(NodeT type_a, NodeT type_b) -> NodeT {
      auto is_a_leaf = (type_a == NC_VAL || type_a == NC_STR);
      auto is_b_leaf = (type_b == NC_VAL || type_b == NC_STR);
      // (v+v=v, *+*=*,  *+v=*, *+#=E, NESTED+VAL=NESTED)
      // *+*=*, v+v=v
      if (type_a == type_b) {
        return type_a;
      } else if (is_a_leaf) {
        // *+v=*, N+V=N
        // STRUCT/LIST + STR/VAL = STRUCT/LIST, STR/VAL + FN = ERR, STR/VAL + STR = STR
        return type_b == NC_FN ? NC_ERR : (is_b_leaf ? NC_STR : type_b);
      } else if (is_b_leaf) {
        return type_a == NC_FN ? NC_ERR : (is_a_leaf ? NC_STR : type_a);
      }
      // *+#=E
      return NC_ERR;
    });

  // node_ids is sorted by col_id.
  auto col_type_id =  // rmm::device_uvector<cudf::type_id>{0, stream};
    type_infer_column_tree(num_columns, tree, col_ids, node_ids, input, options, stream);
  // TODO partition by category VAL, STR on col_id/sorted_col_id, then on range begin, end.
  // After this you don't need range_begin, range_end. So, you can use remove_if or partition.
  // OR copy only col_id, node_id so that you can use to index range_begin, range_end.
  // Then type infer
  // Then parse_data (how to get string size or string column now?)

  // 4. unique_copy parent_node_ids, ranges
  rmm::device_uvector<TreeDepthT> column_levels(0, stream);  // not required
  rmm::device_uvector<NodeIndexT> parent_col_ids(num_columns, stream);
  rmm::device_uvector<SymbolOffsetT> col_range_begin(num_columns, stream);  // Field names
  rmm::device_uvector<SymbolOffsetT> col_range_end(num_columns, stream);
  rmm::device_uvector<size_type> unique_node_ids(num_columns, stream);
  thrust::unique_by_key_copy(rmm::exec_policy(stream),
                             col_ids.begin(),
                             col_ids.end(),
                             node_ids.begin(),
                             thrust::make_discard_iterator(),
                             unique_node_ids.begin());
  thrust::copy_n(
    rmm::exec_policy(stream),
    thrust::make_zip_iterator(
      thrust::make_permutation_iterator(tree.parent_node_ids.begin(), unique_node_ids.begin()),
      thrust::make_permutation_iterator(tree.node_range_begin.begin(), unique_node_ids.begin()),
      thrust::make_permutation_iterator(tree.node_range_end.begin(), unique_node_ids.begin())),
    unique_node_ids.size(),
    thrust::make_zip_iterator(
      parent_col_ids.begin(), col_range_begin.begin(), col_range_end.begin()));

  // Restore the order
  {
    // use scatter to restore the order
    rmm::device_uvector<NodeIndexT> temp_col_ids(col_ids.size(), stream);
    rmm::device_uvector<size_type> temp_row_offsets(row_offsets.size(), stream);
    thrust::scatter(rmm::exec_policy(stream),
                    thrust::make_zip_iterator(col_ids.begin(), row_offsets.begin()),
                    thrust::make_zip_iterator(col_ids.end(), row_offsets.end()),
                    node_ids.begin(),
                    thrust::make_zip_iterator(temp_col_ids.begin(), temp_row_offsets.begin()));
    thrust::copy(rmm::exec_policy(stream),
                 thrust::make_zip_iterator(temp_col_ids.begin(), temp_row_offsets.begin()),
                 thrust::make_zip_iterator(temp_col_ids.end(), temp_row_offsets.end()),
                 thrust::make_zip_iterator(col_ids.begin(), row_offsets.begin()));
  }

  // convert parent_node_ids to parent_col_ids
  thrust::transform(rmm::exec_policy(stream),
                    parent_col_ids.begin(),
                    parent_col_ids.end(),
                    parent_col_ids.begin(),
                    [col_ids = col_ids.begin()] __device__(auto parent_node_id) -> size_type {
                      return parent_node_id == parent_node_sentinel ? parent_node_sentinel
                                                                    : col_ids[parent_node_id];
                    });

  // copy lists' max_row_offsets to children.
  // all structs should have same size.
  thrust::transform_if(
    rmm::exec_policy(stream),
    unique_col_ids.begin(),
    unique_col_ids.end(),
    max_row_offsets.begin(),
    [column_categories = column_categories.begin(),
     parent_col_ids    = parent_col_ids.begin(),
     max_row_offsets   = max_row_offsets.begin()] __device__(size_type col_id) {
      auto parent_col_id = parent_col_ids[col_id];
      while (parent_col_id != parent_node_sentinel and
             column_categories[parent_col_id] != node_t::NC_LIST) {
        col_id        = parent_col_id;
        parent_col_id = parent_col_ids[parent_col_id];
      }
      return max_row_offsets[col_id];
    },
    [column_categories = column_categories.begin(),
     parent_col_ids    = parent_col_ids.begin()] __device__(size_type col_id) {
      auto parent_col_id = parent_col_ids[col_id];
      return parent_col_id != parent_node_sentinel and
             (column_categories[parent_col_id] != node_t::NC_LIST);
      // Parent is not a list, or sentinel/root
    });

  return std::tuple{tree_meta_t{std::move(column_categories),
                                std::move(parent_col_ids),
                                std::move(column_levels),
                                std::move(col_range_begin),
                                std::move(col_range_end)},
                    std::move(unique_col_ids),
                    std::move(max_row_offsets),
                    std::move(col_type_id)};
}

/**
 * @brief Copies strings specified by pair of begin, end offsets to host vector of strings.
 *
 * @param input String device buffer
 * @param node_range_begin Begin offset of the strings
 * @param node_range_end End offset of the strings
 * @param stream CUDA stream
 * @return Vector of strings
 */
std::vector<std::string> copy_strings_to_host(device_span<SymbolT const> input,
                                              device_span<SymbolOffsetT const> node_range_begin,
                                              device_span<SymbolOffsetT const> node_range_end,
                                              rmm::cuda_stream_view stream)
{
  CUDF_FUNC_RANGE();
  auto const num_strings = node_range_begin.size();
  rmm::device_uvector<thrust::pair<const char*, size_type>> string_views(num_strings, stream);
  auto d_offset_pairs = thrust::make_zip_iterator(node_range_begin.begin(), node_range_end.begin());
  thrust::transform(rmm::exec_policy(stream),
                    d_offset_pairs,
                    d_offset_pairs + num_strings,
                    string_views.begin(),
                    [data = input.data()] __device__(auto const& offsets) {
                      // Note: first character for non-field columns
                      return thrust::make_pair(
                        data + thrust::get<0>(offsets),
                        static_cast<size_type>(thrust::get<1>(offsets) - thrust::get<0>(offsets)));
                    });
  auto d_column_names = cudf::make_strings_column(string_views, stream);
  auto to_host        = [](auto const& col) {
    if (col.is_empty()) return std::vector<std::string>{};
    auto const scv     = cudf::strings_column_view(col);
    auto const h_chars = cudf::detail::make_std_vector_sync<char>(
      cudf::device_span<char const>(scv.chars().data<char>(), scv.chars().size()),
      cudf::get_default_stream());
    auto const h_offsets = cudf::detail::make_std_vector_sync(
      cudf::device_span<cudf::offset_type const>(
        scv.offsets().data<cudf::offset_type>() + scv.offset(), scv.size() + 1),
      cudf::get_default_stream());

    // build std::string vector from chars and offsets
    std::vector<std::string> host_data;
    host_data.reserve(col.size());
    std::transform(
      std::begin(h_offsets),
      std::end(h_offsets) - 1,
      std::begin(h_offsets) + 1,
      std::back_inserter(host_data),
      [&](auto start, auto end) { return std::string(h_chars.data() + start, end - start); });
    return host_data;
  };
  return to_host(d_column_names->view());
}

/**
 * @brief Holds member data pointers of `d_json_column`
 *
 */
struct json_column_data {
  using row_offset_t = json_column::row_offset_t;
  row_offset_t* string_offsets;
  row_offset_t* string_lengths;
  row_offset_t* child_offsets;
  bitmask_type* validity;
  data_type cudf_type;
  void* d_fixed_width_data;
};

/**
 * @brief Constructs `d_json_column` from node tree representation
 * Newly constructed columns are insert into `root`'s children.
 * `root` must be a list type.
 *
 * @param input Input JSON string device data
 * @param options Parsing options
 * @param tree Node tree representation of the JSON string
 * @param col_ids Column ids of the nodes in the tree
 * @param row_offsets Row offsets of the nodes in the tree
 * @param root Root node of the `d_json_column` tree
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the device memory
 * of child_offets and validity members of `d_json_column`
 */
void make_device_json_column(device_span<SymbolT const> input,
                             cudf::io::json_reader_options const& options,
                             tree_meta_t& tree,
                             device_span<NodeIndexT> col_ids,
                             device_span<size_type> row_offsets,
                             device_json_column& root,
                             rmm::cuda_stream_view stream,
                             rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  // 1. gather column information.
  auto [d_column_tree, d_unique_col_ids, d_max_row_offsets, col_type_id] =
    reduce_to_column_tree(input, options, tree, col_ids, row_offsets, stream);
  auto num_columns    = d_unique_col_ids.size();
  auto unique_col_ids = cudf::detail::make_std_vector_async(d_unique_col_ids, stream);
  auto column_categories =
    cudf::detail::make_std_vector_async(d_column_tree.node_categories, stream);
  auto column_parent_ids =
    cudf::detail::make_std_vector_async(d_column_tree.parent_node_ids, stream);
  auto column_range_beg =
    cudf::detail::make_std_vector_async(d_column_tree.node_range_begin, stream);
  auto max_row_offsets = cudf::detail::make_std_vector_async(d_max_row_offsets, stream);
  std::vector<std::string> column_names = copy_strings_to_host(
    input, d_column_tree.node_range_begin, d_column_tree.node_range_end, stream);
  auto column_type_id = cudf::detail::make_std_vector_async(col_type_id, stream);

  auto to_json_col_type = [](auto category) {
    switch (category) {
      case NC_STRUCT: return json_col_t::StructColumn;
      case NC_LIST: return json_col_t::ListColumn;
      case NC_STR:
      case NC_VAL: return json_col_t::StringColumn;
      default: return json_col_t::Unknown;
    }
  };
  auto init_to_zero = [stream](auto& v) {
    CUDF_FUNC_RANGE();
    thrust::uninitialized_fill(rmm::exec_policy(stream), v.begin(), v.end(), 0);
  };

  auto initialize_json_columns = [&](auto i, auto& col) {
    CUDF_FUNC_RANGE();
    if (column_categories[i] == NC_ERR || column_categories[i] == NC_FN) {
      return;
    } else if (column_categories[i] == NC_VAL || column_categories[i] == NC_STR) {
      if (not column_type_id.empty()) col.cudf_type = data_type{column_type_id.at(i)};
      // TODO add unique_ptr column for fixed_width types
      if (col.cudf_type.id() != cudf::type_id::STRING) {
        col.fixed_width_column = make_fixed_width_column(
          col.cudf_type, max_row_offsets[i] + 1, mask_state::UNALLOCATED, stream, mr);
        col.d_fixed_width_data = col.fixed_width_column->mutable_view().template data<char>();
        // TODO, can strings be created here itself, if we know the size?
      } else {
        // FIXME remove this, or replace this with string column creation.
        // col.fixed_width_column = make_fixed_width_column(data_type{type_id::INT8}, 1,
        // mask_state::UNALLOCATED, stream, mr);
        col.d_fixed_width_data = nullptr;
        col.string_offsets.resize(max_row_offsets[i] + 1, stream);
        col.string_lengths.resize(max_row_offsets[i] + 2, stream);
        init_to_zero(col.string_offsets);
        init_to_zero(col.string_lengths);
      }
    } else if (column_categories[i] == NC_LIST) {
      col.child_offsets.resize(max_row_offsets[i] + 2, stream);
      init_to_zero(col.child_offsets);
    }
    col.num_rows = max_row_offsets[i] + 1;
    col.validity.resize(bitmask_allocation_size_bytes(max_row_offsets[i] + 1), stream);
    init_to_zero(col.validity);
    col.type = to_json_col_type(column_categories[i]);
  };

  // 2. generate nested columns tree and its device_memory
  // reorder unique_col_ids w.r.t. column_range_begin for order of column to be in field order.
  auto h_range_col_id_it =
    thrust::make_zip_iterator(column_range_beg.begin(), unique_col_ids.begin());
  std::sort(h_range_col_id_it, h_range_col_id_it + num_columns, [](auto const& a, auto const& b) {
    return thrust::get<0>(a) < thrust::get<0>(b);
  });

  // use hash map because we may skip field name's col_ids
  std::unordered_map<NodeIndexT, std::reference_wrapper<device_json_column>> columns;
  // map{parent_col_id, child_col_name}> = child_col_id, used for null value column tracking
  std::map<std::pair<NodeIndexT, std::string>, NodeIndexT> mapped_columns;
  // find column_ids which are values, but should be ignored in validity
  std::vector<uint8_t> ignore_vals(num_columns, 0);
  columns.try_emplace(parent_node_sentinel, std::ref(root));

  for (auto const this_col_id : unique_col_ids) {
    if (column_categories[this_col_id] == NC_ERR || column_categories[this_col_id] == NC_FN) {
      continue;
    }
    // Struct, List, String, Value
    std::string name   = "";
    auto parent_col_id = column_parent_ids[this_col_id];
    if (parent_col_id == parent_node_sentinel || column_categories[parent_col_id] == NC_LIST) {
      name = list_child_name;
    } else if (column_categories[parent_col_id] == NC_FN) {
      auto field_name_col_id = parent_col_id;
      parent_col_id          = column_parent_ids[parent_col_id];
      name                   = column_names[field_name_col_id];
    } else {
      CUDF_FAIL("Unexpected parent column category");
    }
    // If the child is already found,
    // replace if this column is a nested column and the existing was a value column
    // ignore this column if this column is a value column and the existing was a nested column
    auto it = columns.find(parent_col_id);
    CUDF_EXPECTS(it != columns.end(), "Parent column not found");
    auto& parent_col = it->second.get();
    bool replaced    = false;
    if (mapped_columns.count({parent_col_id, name}) > 0) {
      if (column_categories[this_col_id] == NC_VAL || column_categories[this_col_id] == NC_STR) {
        ignore_vals[this_col_id] = 1;
        continue;
      }
      auto old_col_id = mapped_columns[{parent_col_id, name}];
      if (column_categories[old_col_id] == NC_VAL || column_categories[old_col_id] == NC_STR) {
        // remap
        ignore_vals[old_col_id] = 1;
        mapped_columns.erase({parent_col_id, name});
        columns.erase(old_col_id);
        parent_col.child_columns.erase(name);
        replaced = true;  // to skip duplicate name in column_order
      } else {
        // If this is a nested column but we're trying to insert either (a) a list node into a
        // struct column or (b) a struct node into a list column, we fail
        CUDF_EXPECTS(not((column_categories[old_col_id] == NC_LIST and
                          column_categories[this_col_id] == NC_STRUCT) or
                         (column_categories[old_col_id] == NC_STRUCT and
                          column_categories[this_col_id] == NC_LIST)),
                     "A mix of lists and structs within the same column is not supported");
      }
    }
    CUDF_EXPECTS(parent_col.child_columns.count(name) == 0, "duplicate column name");
    // move into parent
    device_json_column col(stream, mr);
    initialize_json_columns(this_col_id, col);
    auto inserted = parent_col.child_columns.try_emplace(name, std::move(col)).second;
    CUDF_EXPECTS(inserted, "child column insertion failed, duplicate column name in the parent");
    if (not replaced) parent_col.column_order.push_back(name);
    columns.try_emplace(this_col_id, std::ref(parent_col.child_columns.at(name)));
    mapped_columns.try_emplace(std::make_pair(parent_col_id, name), this_col_id);
  }
  // restore unique_col_ids order
  std::sort(h_range_col_id_it, h_range_col_id_it + num_columns, [](auto const& a, auto const& b) {
    return thrust::get<1>(a) < thrust::get<1>(b);
  });

  fill_schema_type_for_tree(root, options);  // TODO allocate value columns here.
  // move columns data to device.
  std::vector<json_column_data> columns_data(num_columns);
  for (auto& [col_id, col_ref] : columns) {
    if (col_id == parent_node_sentinel) continue;
    auto& col            = col_ref.get();
    columns_data[col_id] = json_column_data{col.string_offsets.data(),
                                            col.string_lengths.data(),
                                            col.child_offsets.data(),
                                            col.validity.data(),
                                            col.cudf_type,
                                            col.d_fixed_width_data};
    // TODO cudf_type might be user input, TODO so, populate early.
  }

  // 3. scatter string offsets to respective columns, set validity bits
  auto d_ignore_vals  = cudf::detail::make_device_uvector_async(ignore_vals, stream);
  auto d_columns_data = cudf::detail::make_device_uvector_async(columns_data, stream);

  auto parse_opts = parsing_options(options);  // holds device_uvector<trie>.

  {
    CUDF_SCOPED_RANGE("ConvertFunctor");
    thrust::for_each_n(
      rmm::exec_policy(stream),
      thrust::counting_iterator<size_type>(0),
      col_ids.size(),
      [input,
       options         = parse_opts.view(),
       node_categories = tree.node_categories.begin(),
       col_ids         = col_ids.begin(),
       row_offsets     = row_offsets.begin(),
       range_begin     = tree.node_range_begin.begin(),
       range_end       = tree.node_range_end.begin(),
       d_ignore_vals   = d_ignore_vals.begin(),
       d_columns_data  = d_columns_data.begin()] __device__(size_type i) {
        switch (node_categories[i]) {
          case NC_STRUCT: set_bit(d_columns_data[col_ids[i]].validity, row_offsets[i]); break;
          case NC_LIST: set_bit(d_columns_data[col_ids[i]].validity, row_offsets[i]); break;
          case NC_VAL:
          case NC_STR:
            if (d_ignore_vals[col_ids[i]]) break;
            // trie_na and break;
            if (serialized_trie_contains(options.trie_na,
                                         {input.data() + range_begin[i],
                                          static_cast<size_t>(range_end[i] - range_begin[i])}))
              break;
            // if col_type == string, copy this. else ConvertFunctor{}
            if (d_columns_data[col_ids[i]].cudf_type.id() == type_id::STRING) {
              break;
              // auto in_begin = input.data() + range_begin[i];
              // auto in_end   = input.data() + range_end[i];
              // auto str_process_info = experimental::detail::process_string(in_begin, in_end,
              // nullptr, options); if (str_process_info.result ==
              // experimental::detail::data_casting_result::PARSING_SUCCESS) {
              //   d_columns_data[col_ids[i]].string_lengths[row_offsets[i]] =
              //   str_process_info.bytes;
              // } else {
              //   break;
              // }
              // // // TODO: do the null mask and size only here
              // // d_columns_data[col_ids[i]].string_offsets[row_offsets[i]] = range_begin[i];
              // // d_columns_data[col_ids[i]].string_lengths[row_offsets[i]] =
              // //   range_end[i] - range_begin[i];
            } else {
              // If this is a string value, remove quotes
              auto [in_begin, in_end] = trim_quotes(
                input.data() + range_begin[i], input.data() + range_end[i], options.quotechar);

              auto const is_parsed =
                cudf::type_dispatcher(d_columns_data[col_ids[i]].cudf_type,
                                      ConvertFunctor{},
                                      in_begin,
                                      in_end,
                                      d_columns_data[col_ids[i]].d_fixed_width_data,
                                      row_offsets[i],
                                      data_type{d_columns_data[col_ids[i]].cudf_type},
                                      options,
                                      false);
              if (not is_parsed) break;
            }
            set_bit(d_columns_data[col_ids[i]].validity, row_offsets[i]);
            break;
          default: break;
        }
      });
  }
  {
    CUDF_SCOPED_RANGE("StringLength");
    thrust::for_each_n(rmm::exec_policy(stream),
                       thrust::counting_iterator<size_type>(0),
                       col_ids.size(),
                       [input,
                        options         = parse_opts.view(),
                        node_categories = tree.node_categories.begin(),
                        col_ids         = col_ids.begin(),
                        row_offsets     = row_offsets.begin(),
                        range_begin     = tree.node_range_begin.begin(),
                        range_end       = tree.node_range_end.begin(),
                        d_ignore_vals   = d_ignore_vals.begin(),
                        d_columns_data  = d_columns_data.begin()] __device__(size_type i) {
                         switch (node_categories[i]) {
                           case NC_VAL:
                           case NC_STR:
                             if (d_ignore_vals[col_ids[i]]) break;
                             // trie_na and break;
                             if (!bit_is_set(d_columns_data[col_ids[i]].validity, row_offsets[i]))
                               break;
                             // if col_type == string, copy this. else ConvertFunctor{}
                             if (d_columns_data[col_ids[i]].cudf_type.id() == type_id::STRING) {
                               auto in_begin         = input.data() + range_begin[i];
                               auto in_end           = input.data() + range_end[i];
                               auto str_process_info = experimental::detail::process_string(
                                 in_begin, in_end, nullptr, options);
                               if (str_process_info.result ==
                                   experimental::detail::data_casting_result::PARSING_SUCCESS) {
                                 d_columns_data[col_ids[i]].string_lengths[row_offsets[i]] =
                                   str_process_info.bytes;
                               } else {
                                 break;
                               }
                             }
                             set_bit(d_columns_data[col_ids[i]].validity, row_offsets[i]);
                             break;
                           default: break;
                         }
                       });
  }
  // TODO
  // compute string offsets
  // allocate chars.
  // copy chars.
  {
    CUDF_SCOPED_RANGE("string_offsets");
    for (auto& [col_id, col_ref] : columns) {
      auto& col = col_ref.get();
      if (col.type == json_col_t::StringColumn and col.cudf_type.id() == type_id::STRING) {
        thrust::exclusive_scan(rmm::exec_policy(stream),
                               col.string_lengths.begin(),
                               col.string_lengths.end(),
                               col.string_lengths.begin());
        // Allocate chars
        auto const total_bytes = col.string_lengths.back_element(stream);
        col.fixed_width_column =
          strings::detail::create_chars_child_column(total_bytes, stream, mr);
        col.d_fixed_width_data = col.fixed_width_column->mutable_view().data<char>();
        columns_data[col_id].d_fixed_width_data = col.d_fixed_width_data;
      }
    }
    d_columns_data = cudf::detail::make_device_uvector_async(columns_data, stream);
  }

  {
    CUDF_SCOPED_RANGE("StringProcess");
    thrust::for_each_n(
      rmm::exec_policy(stream),
      thrust::counting_iterator<size_type>(0),
      col_ids.size(),
      [input,
       options         = parse_opts.view(),
       node_categories = tree.node_categories.begin(),
       col_ids         = col_ids.begin(),
       row_offsets     = row_offsets.begin(),
       range_begin     = tree.node_range_begin.begin(),
       range_end       = tree.node_range_end.begin(),
       d_ignore_vals   = d_ignore_vals.begin(),
       d_columns_data  = d_columns_data.begin()] __device__(size_type i) {
        switch (node_categories[i]) {
          case NC_VAL:
          case NC_STR:
            if (d_ignore_vals[col_ids[i]]) break;
            if (d_columns_data[col_ids[i]].cudf_type.id() == type_id::STRING) {
              if (!bit_is_set(d_columns_data[col_ids[i]].validity, row_offsets[i])) break;
              auto in_begin  = input.data() + range_begin[i];
              auto in_end    = input.data() + range_end[i];
              char* d_chars  = static_cast<char*>(d_columns_data[col_ids[i]].d_fixed_width_data);
              auto d_offsets = d_columns_data[col_ids[i]].string_lengths;
              auto d_buffer  = d_chars + d_offsets[row_offsets[i]];
              experimental::detail::process_string(in_begin, in_end, d_buffer, options);
            }
            break;
          default: break;
        }
      });
  }

  // 4. scatter List offset
  //   sort_by_key {col_id}, {node_id}
  //   unique_copy_by_key {parent_node_id} {row_offset} to
  //   col[parent_col_id].child_offsets[row_offset[parent_node_id]]

  rmm::device_uvector<NodeIndexT> original_col_ids(col_ids.size(), stream);  // make a copy
  thrust::copy(rmm::exec_policy(stream), col_ids.begin(), col_ids.end(), original_col_ids.begin());
  rmm::device_uvector<size_type> node_ids(row_offsets.size(), stream);
  // TODO Why do it twice? once in reduce_to_column_tree, once here? Reuse or use it early itself.
  thrust::sequence(rmm::exec_policy(stream), node_ids.begin(), node_ids.end());
  thrust::stable_sort_by_key(
    rmm::exec_policy(stream), col_ids.begin(), col_ids.end(), node_ids.begin());

  auto ordered_parent_node_ids =
    thrust::make_permutation_iterator(tree.parent_node_ids.begin(), node_ids.begin());
  auto ordered_row_offsets =
    thrust::make_permutation_iterator(row_offsets.begin(), node_ids.begin());
  {
    CUDF_SCOPED_RANGE("list_offsets");
    thrust::for_each_n(
      rmm::exec_policy(stream),
      thrust::counting_iterator<size_type>(0),
      col_ids.size(),
      [num_nodes = col_ids.size(),
       ordered_parent_node_ids,
       ordered_row_offsets,
       original_col_ids = original_col_ids.begin(),
       col_ids          = col_ids.begin(),
       row_offsets      = row_offsets.begin(),
       node_categories  = tree.node_categories.begin(),
       d_columns_data   = d_columns_data.begin()] __device__(size_type i) {
        auto parent_node_id = ordered_parent_node_ids[i];
        if (parent_node_id != parent_node_sentinel and node_categories[parent_node_id] == NC_LIST) {
          // unique item
          if (i == 0 or
              (col_ids[i - 1] != col_ids[i] or ordered_parent_node_ids[i - 1] != parent_node_id)) {
            // scatter to list_offset
            d_columns_data[original_col_ids[parent_node_id]]
              .child_offsets[row_offsets[parent_node_id]] = ordered_row_offsets[i];
          }
          // TODO: verify if this code is right. check with more test cases.
          if (i == num_nodes - 1 or
              (col_ids[i] != col_ids[i + 1] or ordered_parent_node_ids[i + 1] != parent_node_id)) {
            // last value of list child_offset is its size.
            d_columns_data[original_col_ids[parent_node_id]]
              .child_offsets[row_offsets[parent_node_id] + 1] = ordered_row_offsets[i] + 1;
          }
        }
      });
  }

  // restore col_ids, TODO is this required?
  // thrust::copy(
  //   rmm::exec_policy(stream), original_col_ids.begin(), original_col_ids.end(), col_ids.begin());

  {
    CUDF_SCOPED_RANGE("inc_scan");
    // 5. scan on offsets.
    for (auto& [id, col_ref] : columns) {
      auto& col = col_ref.get();
      if (col.type == json_col_t::StringColumn) {
        // thrust::inclusive_scan(rmm::exec_policy(stream),
        //                        col.string_offsets.begin(),
        //                        col.string_offsets.end(),
        //                        col.string_offsets.begin(),
        //                        thrust::maximum<json_column::row_offset_t>{});
      } else if (col.type == json_col_t::ListColumn) {
        thrust::inclusive_scan(rmm::exec_policy(stream),
                               col.child_offsets.begin(),
                               col.child_offsets.end(),
                               col.child_offsets.begin(),
                               thrust::maximum<json_column::row_offset_t>{});
      }
    }
  }
  // n spans. (span size.) lamda = sum.
  // exclusive_scan_by_key.
  // larger the lamda slower it gets.
  // inline the iterator too.
}

void fill_schema_type(device_json_column& json_col, std::optional<schema_element> schema)
{
  CUDF_FUNC_RANGE();
  auto get_child_schema = [schema](auto child_name) -> std::optional<schema_element> {
    if (schema.has_value()) {
      auto const result = schema.value().child_types.find(child_name);
      if (result != std::end(schema.value().child_types)) { return result->second; }
    }
    return {};
  };
  switch (json_col.type) {
    case json_col_t::StringColumn: {
      if (schema.has_value()) {
#ifdef NJP_DEBUG_PRINT
        std::cout << "-> explicit type: "
                  << (schema.has_value() ? std::to_string(static_cast<int>(schema->type.id()))
                                         : "n/a");
#endif
        json_col.cudf_type = schema.value().type;
        // FIXME: this is a hack. need to fix this.
        json_col.fixed_width_column =
          make_fixed_width_column(json_col.cudf_type, json_col.num_rows, mask_state::UNALLOCATED);
        json_col.d_fixed_width_data =
          json_col.fixed_width_column->mutable_view().template data<char>();
      }
      // Infer column type, if we don't have an explicit type for it
      else {
        // json_col.cudf_type =
        // cudf::io::detail::infer_data_type(
        //   parsing_options(options).json_view(), d_input, string_ranges_it, col_size, stream);
      }
    } break;
    case json_col_t::StructColumn: {
      for (auto const& col_name : json_col.column_order) {
        auto const& col = json_col.child_columns.find(col_name);
        if (col == json_col.child_columns.end()) { CUDF_FAIL("Column not found"); }
        auto& child_col = col->second;
        fill_schema_type(child_col, get_child_schema(col_name));
      }
    } break;
    case json_col_t::ListColumn: {
      if (!json_col.child_columns.empty())
        fill_schema_type(json_col.child_columns.begin()->second,
                         get_child_schema(json_col.child_columns.begin()->first));
    } break;
    default: CUDF_FAIL("Unsupported column type"); break;
  }
}

void fill_schema_type_for_tree(device_json_column& root_column,
                               cudf::io::json_reader_options const& options)
{
  CUDF_FUNC_RANGE();
  // TODO populate column metadata here?
  // TODO Move column ownership to tree creation itself.??? will it be better?

  // data_root refers to the root column of the data represented by the given JSON string
  auto& data_root =
    options.is_enabled_lines() ? root_column : root_column.child_columns.begin()->second;
  if (data_root.child_columns.empty()) return;

  // Slice off the root list column, which has only a single row that contains all the structs
  auto& root_struct_col = data_root.child_columns.begin()->second;

  // Iterate over the struct's child columns and convert to cudf column
  size_type column_index = 0;
  for (auto const& col_name : root_struct_col.column_order) {
    auto& json_col = root_struct_col.child_columns.find(col_name)->second;

    std::optional<schema_element> child_schema_element = std::visit(
      cudf::detail::visitor_overload{
        [column_index](const std::vector<data_type>& user_dtypes) -> std::optional<schema_element> {
          return (static_cast<std::size_t>(column_index) < user_dtypes.size())
                   ? std::optional<schema_element>{{user_dtypes[column_index]}}
                   : std::optional<schema_element>{};
        },
        [col_name](
          std::map<std::string, data_type> const& user_dtypes) -> std::optional<schema_element> {
          return (user_dtypes.find(col_name) != std::end(user_dtypes))
                   ? std::optional<schema_element>{{user_dtypes.find(col_name)->second}}
                   : std::optional<schema_element>{};
        },
        [col_name](std::map<std::string, schema_element> const& user_dtypes)
          -> std::optional<schema_element> {
          return (user_dtypes.find(col_name) != std::end(user_dtypes))
                   ? user_dtypes.find(col_name)->second
                   : std::optional<schema_element>{};
        }},
      options.get_dtypes());
#ifdef NJP_DEBUG_PRINT
    auto debug_schema_print = [](auto ret) {
      std::cout << ", type id: "
                << (ret.has_value() ? std::to_string(static_cast<int>(ret->type.id())) : "n/a")
                << ", with " << (ret.has_value() ? ret->child_types.size() : 0) << " children"
                << "\n";
    };
    std::visit(
      cudf::detail::visitor_overload{[column_index](const std::vector<data_type>&) {
                                       std::cout << "Column by index: #" << column_index;
                                     },
                                     [col_name](std::map<std::string, data_type> const&) {
                                       std::cout << "Column by flat name: '" << col_name;
                                     },
                                     [col_name](std::map<std::string, schema_element> const&) {
                                       std::cout << "Column by nested name: #" << col_name;
                                     }},
      options.get_dtypes());
    debug_schema_print(child_schema_element);
#endif

    // Get this JSON column's cudf column and schema info, (modifies json_col)
    fill_schema_type(json_col, child_schema_element);
    column_index++;
  }
}

std::pair<std::unique_ptr<column>, std::vector<column_name_info>> device_json_column_to_cudf_column(
  device_json_column& json_col,
  device_span<SymbolT const> d_input,
  cudf::io::json_reader_options const& options,
  std::optional<schema_element> schema,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  auto make_validity =
    [stream](device_json_column& json_col) -> std::pair<rmm::device_buffer, size_type> {
    CUDF_EXPECTS(json_col.validity.size() >= bitmask_allocation_size_bytes(json_col.num_rows),
                 "valid_count is too small");
    auto null_count = cudf::UNKNOWN_NULL_COUNT;
    // TODO compute null count at the end for all column null_masks, or is it needed?
    //   cudf::detail::null_count(json_col.validity.data(), 0, json_col.num_rows, stream);
    // full null_mask is always required for parse_data
    return {json_col.validity.release(), null_count};
    // Note: json_col modified here, moves this memory
  };

  auto get_child_schema = [schema](auto child_name) -> std::optional<schema_element> {
    if (schema.has_value()) {
      auto const result = schema.value().child_types.find(child_name);
      if (result != std::end(schema.value().child_types)) { return result->second; }
    }
    return {};
  };

  switch (json_col.type) {
    case json_col_t::StringColumn: {
      // move string_offsets to GPU and transform to string column
      auto const col_size = json_col.num_rows;  // string_offsets.size();
      // using char_length_pair_t = thrust::pair<const char*, size_type>;
      // // CUDF_EXPECTS(json_col.string_offsets.size() == json_col.string_lengths.size(),
      // //              "string offset, string length mismatch");
      // rmm::device_uvector<char_length_pair_t> d_string_data(col_size, stream);
      // // TODO how about directly storing pair<char*, size_t> in json_column?
      // auto offset_length_it =
      //   thrust::make_zip_iterator(json_col.string_offsets.begin(),
      //   json_col.string_lengths.begin());
      // // Prepare iterator that returns (string_offset, string_length)-pairs needed by inference
      // [[maybe_unused]] auto string_ranges_it =
      //   thrust::make_transform_iterator(offset_length_it, [] __device__(auto ip) {
      //     return thrust::pair<json_column::row_offset_t, std::size_t>{
      //       thrust::get<0>(ip), static_cast<std::size_t>(thrust::get<1>(ip))};
      //   });

      // Prepare iterator that returns (string_ptr, string_length)-pairs needed by type conversion
      // auto string_spans_it = thrust::make_transform_iterator(
      //   offset_length_it, [data = d_input.data()] __device__(auto ip) {
      //     return thrust::pair<const char*, std::size_t>{
      //       data + thrust::get<0>(ip), static_cast<std::size_t>(thrust::get<1>(ip))};
      //   });

      data_type target_type{};

      if (schema.has_value()) {
#ifdef NJP_DEBUG_PRINT
        std::cout << "-> explicit type: "
                  << (schema.has_value() ? std::to_string(static_cast<int>(schema->type.id()))
                                         : "n/a");
#endif
        target_type = schema.value().type;
      }
      // Infer column type, if we don't have an explicit type for it
      else {
        target_type = cudf::data_type{json_col.cudf_type};
        // cudf::io::detail::infer_data_type(
        //   parsing_options(options).json_view(), d_input, string_ranges_it, col_size, stream);
      }
      // Convert strings to the inferred data type
      auto col = [&]() {
        if (target_type != cudf::data_type{type_id::STRING}) {
          auto [new_null_mask, null_count] = make_validity(json_col);
          json_col.fixed_width_column->set_null_mask(std::move(new_null_mask), null_count);
          return std::move(json_col.fixed_width_column);
        }
        auto [new_null_mask, null_count] = make_validity(json_col);
        return make_strings_column(col_size,
                                   std::make_unique<column>(std::move(json_col.string_lengths)),
                                   std::move(json_col.fixed_width_column),
                                   null_count,
                                   std::move(new_null_mask));
        // return experimental::detail::parse_data(string_spans_it,
        //                                         col_size,
        //                                         target_type,
        //                                         make_validity(json_col).first,
        //                                         parsing_options(options).view(),
        //                                         stream,
        //                                         mr);
      }();

      // Reset nullable if we do not have nulls
      // This is to match the existing JSON reader's behaviour:
      // - Non-string columns will always be returned as nullable
      // - String columns will be returned as nullable, iff there's at least one null entry
      if (target_type.id() == type_id::STRING and col->null_count() == 0) {
        col->set_null_mask(rmm::device_buffer{0, stream, mr}, 0);
      }

      // For string columns return ["offsets", "char"] schema
      if (target_type.id() == type_id::STRING) {
        return {std::move(col), {{"offsets"}, {"chars"}}};
      }
      // Non-string leaf-columns (e.g., numeric) do not have child columns in the schema
      return {std::move(col), {}};
    }
    case json_col_t::StructColumn: {
      std::vector<std::unique_ptr<column>> child_columns;
      std::vector<column_name_info> column_names{};
      size_type num_rows{json_col.num_rows};
      // Create children columns
      for (auto const& col_name : json_col.column_order) {
        auto const& col = json_col.child_columns.find(col_name);
        column_names.emplace_back(col->first);
        auto& child_col            = col->second;
        auto [child_column, names] = device_json_column_to_cudf_column(
          child_col, d_input, options, get_child_schema(col_name), stream, mr);
        CUDF_EXPECTS(num_rows == child_column->size(),
                     "All children columns must have the same size");
        child_columns.push_back(std::move(child_column));
        column_names.back().children = names;
      }
      auto [result_bitmask, null_count] = make_validity(json_col);
      auto ret_col                      = make_structs_column(
        num_rows, std::move(child_columns), cudf::UNKNOWN_NULL_COUNT, {}, stream, mr);
      // Adding null_mask later to avoid superimpose_parent_nulls
      // TODO handle superimpose_parent_nulls later for top level struct columns, and list's
      // immediate children struct columns.
      ret_col->set_null_mask(std::move(result_bitmask), null_count);
      return {std::move(ret_col), column_names};
    }
    case json_col_t::ListColumn: {
      size_type num_rows = json_col.child_offsets.size() - 1;
      std::vector<column_name_info> column_names{};
      column_names.emplace_back("offsets");
      column_names.emplace_back(
        json_col.child_columns.empty() ? list_child_name : json_col.child_columns.begin()->first);

      // Note: json_col modified here, reuse the memory
      auto offsets_column = std::make_unique<column>(
        data_type{type_id::INT32}, num_rows + 1, json_col.child_offsets.release());
      // Create children column
      auto [child_column, names] =
        json_col.child_columns.empty()
          ? std::pair<std::unique_ptr<column>,
                      std::vector<column_name_info>>{std::make_unique<column>(), {}}
          : device_json_column_to_cudf_column(
              json_col.child_columns.begin()->second,
              d_input,
              options,
              get_child_schema(json_col.child_columns.begin()->first),
              stream,
              mr);
      column_names.back().children      = names;
      auto [result_bitmask, null_count] = make_validity(json_col);
      return {make_lists_column(num_rows,
                                std::move(offsets_column),
                                std::move(child_column),
                                null_count,
                                std::move(result_bitmask),
                                stream,
                                mr),
              std::move(column_names)};
    }
    default: CUDF_FAIL("Unsupported column type"); break;
  }
}

table_with_metadata device_parse_nested_json(device_span<SymbolT const> d_input,
                                             cudf::io::json_reader_options const& options,
                                             rmm::cuda_stream_view stream,
                                             rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();

  auto gpu_tree = [&]() {
    // Parse the JSON and get the token stream
    const auto [tokens_gpu, token_indices_gpu] = get_token_stream(d_input, options, stream);
    // gpu tree generation
    return get_tree_representation(tokens_gpu, token_indices_gpu, stream);
  }();  // IILE used to free memory of token data.
#ifdef NJP_DEBUG_PRINT
  auto h_input = cudf::detail::make_host_vector_async(d_input, stream);
  print_tree(h_input, gpu_tree, stream);
#endif

  auto [gpu_col_id, gpu_row_offsets] = records_orient_tree_traversal(d_input, gpu_tree, stream);

  device_json_column root_column(stream, mr);
  root_column.type = json_col_t::ListColumn;
  root_column.child_offsets.resize(2, stream);
  thrust::fill(rmm::exec_policy(stream),
               root_column.child_offsets.begin(),
               root_column.child_offsets.end(),
               0);

  // Get internal JSON column
  make_device_json_column(
    d_input, options, gpu_tree, gpu_col_id, gpu_row_offsets, root_column, stream, mr);

  // data_root refers to the root column of the data represented by the given JSON string
  auto& data_root =
    options.is_enabled_lines() ? root_column : root_column.child_columns.begin()->second;

  // Zero row entries
  if (data_root.type == json_col_t::ListColumn && data_root.child_columns.size() == 0) {
    return table_with_metadata{std::make_unique<table>(std::vector<std::unique_ptr<column>>{}),
                               {{}, std::vector<column_name_info>{}}};
  }

  // Verify that we were in fact given a list of structs (or in JSON speech: an array of objects)
  auto constexpr single_child_col_count = 1;
  CUDF_EXPECTS(data_root.type == json_col_t::ListColumn and
                 data_root.child_columns.size() == single_child_col_count and
                 data_root.child_columns.begin()->second.type == json_col_t::StructColumn,
               "Currently the nested JSON parser only supports an array of (nested) objects");

  // Slice off the root list column, which has only a single row that contains all the structs
  auto& root_struct_col = data_root.child_columns.begin()->second;

  // Initialize meta data to be populated while recursing through the tree of columns
  std::vector<std::unique_ptr<column>> out_columns;
  std::vector<column_name_info> out_column_names;

  // Iterate over the struct's child columns and convert to cudf column
  size_type column_index = 0;
  for (auto const& col_name : root_struct_col.column_order) {
    auto& json_col = root_struct_col.child_columns.find(col_name)->second;
    // Insert this columns name into the schema
    out_column_names.emplace_back(col_name);

    std::optional<schema_element> child_schema_element = std::visit(
      cudf::detail::visitor_overload{
        [column_index](const std::vector<data_type>& user_dtypes) -> std::optional<schema_element> {
          return (static_cast<std::size_t>(column_index) < user_dtypes.size())
                   ? std::optional<schema_element>{{user_dtypes[column_index]}}
                   : std::optional<schema_element>{};
        },
        [col_name](
          std::map<std::string, data_type> const& user_dtypes) -> std::optional<schema_element> {
          return (user_dtypes.find(col_name) != std::end(user_dtypes))
                   ? std::optional<schema_element>{{user_dtypes.find(col_name)->second}}
                   : std::optional<schema_element>{};
        },
        [col_name](std::map<std::string, schema_element> const& user_dtypes)
          -> std::optional<schema_element> {
          return (user_dtypes.find(col_name) != std::end(user_dtypes))
                   ? user_dtypes.find(col_name)->second
                   : std::optional<schema_element>{};
        }},
      options.get_dtypes());
#ifdef NJP_DEBUG_PRINT
    auto debug_schema_print = [](auto ret) {
      std::cout << ", type id: "
                << (ret.has_value() ? std::to_string(static_cast<int>(ret->type.id())) : "n/a")
                << ", with " << (ret.has_value() ? ret->child_types.size() : 0) << " children"
                << "\n";
    };
    std::visit(
      cudf::detail::visitor_overload{[column_index](const std::vector<data_type>&) {
                                       std::cout << "Column by index: #" << column_index;
                                     },
                                     [col_name](std::map<std::string, data_type> const&) {
                                       std::cout << "Column by flat name: '" << col_name;
                                     },
                                     [col_name](std::map<std::string, schema_element> const&) {
                                       std::cout << "Column by nested name: #" << col_name;
                                     }},
      options.get_dtypes());
    debug_schema_print(child_schema_element);
#endif

    // Get this JSON column's cudf column and schema info, (modifies json_col)
    auto [cudf_col, col_name_info] = device_json_column_to_cudf_column(
      json_col, d_input, options, child_schema_element, stream, mr);

    out_column_names.back().children = std::move(col_name_info);
    out_columns.emplace_back(std::move(cudf_col));

    column_index++;
  }

  return table_with_metadata{std::make_unique<table>(std::move(out_columns)),
                             {{}, out_column_names}};
}

table_with_metadata device_parse_nested_json(host_span<SymbolT const> input,
                                             cudf::io::json_reader_options const& options,
                                             rmm::cuda_stream_view stream,
                                             rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();

  // Allocate device memory for the JSON input & copy over to device
  rmm::device_uvector<SymbolT> d_input = cudf::detail::make_device_uvector_async(input, stream);

  return device_parse_nested_json(device_span<SymbolT const>{d_input}, options, stream, mr);
}
}  // namespace detail
}  // namespace cudf::io::json
