/*
 * Copyright (c) 2023-2024, NVIDIA CORPORATION.
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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/default_stream.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/detail/aggregation/aggregation.hpp>
#include <cudf/reduction.hpp>

class ReductionTest : public cudf::test::BaseFixture {};

TEST_F(ReductionTest, ReductionSum)
{
  cudf::test::fixed_width_column_wrapper<int> input({1, 2, 3, 4, 5, 6, 7, 8, 9, 10});
  cudf::reduce(input, *cudf::make_sum_aggregation<cudf::reduce_aggregation>(),
              cudf::data_type(cudf::type_id::INT32),
              cudf::test::get_default_stream());
}

