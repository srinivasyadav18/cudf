/*
 * Copyright (c) 2020-2024, NVIDIA CORPORATION.
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

#include <cudf/detail/utilities/assert.cuh>
#include <cudf/fixed_point/temporary.hpp>
#include <cudf/types.hpp>

#include <cuda/std/limits>
#include <cuda/std/type_traits>
#include <cuda/std/utility>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <string>

/// `fixed_point` and supporting types
namespace numeric {

/**
 * @addtogroup fixed_point_classes
 * @{
 * @file
 * @brief Class definition for fixed point data type
 */

/// The scale type for fixed_point
enum scale_type : int32_t {};

/**
 * @brief Scoped enumerator to use when constructing `fixed_point`
 *
 * Examples:
 * ```cpp
 * using decimal32 = fixed_point<int32_t, Radix::BASE_10>;
 * using binary64  = fixed_point<int64_t, Radix::BASE_2>;
 * ```
 */
enum class Radix : int32_t { BASE_2 = 2, BASE_10 = 10 };

/**
 * @brief Returns `true` if the representation type is supported by `fixed_point`
 *
 * @tparam T The representation type
 * @return `true` if the type is supported by `fixed_point` implementation
 */
template <typename T>
constexpr inline auto is_supported_representation_type()
{
  return cuda::std::is_same_v<T, int32_t> ||  //
         cuda::std::is_same_v<T, int64_t> ||  //
         cuda::std::is_same_v<T, __int128_t>;
}

/** @} */  // end of group

// Helper functions for `fixed_point` type
namespace detail {

/**
 * @brief Recursively calculate a signed large power of 10 (>= 10^18) that can only be stored in an
 * 128bit integer
 *
 * @note Intended to be run at compile time.
 *
 * @tparam Exp10 The power of 10 to calculate
 * @return Returns 10^Exp10
 */
template <int Exp10>
constexpr __int128_t large_power_of_10()
{
  // Stop at 10^18 to speed up compilation; literals can be used for smaller powers of 10.
  static_assert(Exp10 >= 18);
  if constexpr (Exp10 == 18)
    return __int128_t(1000000000000000000LL);
  else
    return large_power_of_10<Exp10 - 1>() * __int128_t(10);
}

/**
 * @brief Divide by a power of 10 that fits within a 32bit integer.
 *
 * @tparam T Type of value to be divided-from.
 * @param value The number to be divided-from.
 * @param exp10 The power-of-10 of the denominator, from 0 to 9 inclusive.
 * @return Returns value / 10^exp10
 */
template <typename T>
CUDF_HOST_DEVICE inline T divide_power10_32bit(T value, int exp10)
{
  // Computing division this way is much faster than the alternatives.
  // Division is not implemented in GPU hardware, and the compiler will often implement it as a
  // multiplication of the reciprocal of the denominator, requiring a conversion to floating point.
  // Ths is especially slow for larger divides that have to use the FP64 pipeline, where threads
  // bottleneck.

  // Instead, if the compiler can see exactly what number it is dividing by, it can
  // produce much more optimal assembly, doing bit shifting, multiplies by a constant, etc.
  // For the compiler to see the value though, array lookup (with exp10 as the index)
  // is not sufficient: We have to use a switch statement. Although this introduces a branch,
  // it is still much faster than doing the divide any other way.
  // Perhaps an array can be used in C++23 with the assume attribute?

  // Since we're optimizing division this way, we have to do this for multiplication as well.
  // That's because doing them in different ways (switch, array, runtime-computation, etc.)
  // increases the register pressure on all kernels that use fixed_point types, specifically slowing
  // down some of the PYMOD and join benchmarks.

  // This is split up into separate functions for 32-, 64-, and 128-bit denominators.
  // That way we limit the templated, inlined code generation to the exponents that are
  // capable of being represented. Combining them together into a single function again
  // introduces too much pressure on the kernels that use this code, slowing down their benchmarks.

  // Also note that these divisors are hardcoded here in place, rather than in the PowersOf10
  // struct. This is because the NotEqual benchmark is slower when doing that; I guess the compiler
  // is getting confused by all of the templating and inlining and can't optimize it as well?

  // Note: Using signed powers of 10 (where possible) to avoid unintended integer conversion

  switch (exp10) {
    case 0: return value;
    case 1: return value / 10;
    case 2: return value / 100;
    case 3: return value / 1000;
    case 4: return value / 10000;
    case 5: return value / 100000;
    case 6: return value / 1000000;
    case 7: return value / 10000000;
    case 8: return value / 100000000;
    case 9: return value / 1000000000;
    default: return 0;
  }
}

/**
 * @brief Divide by a power of 10 that fits within a 64bit integer.
 *
 * @tparam T Type of value to be divided-from.
 * @param value The number to be divided-from.
 * @param exp10 The power-of-10 of the denominator, from 0 to 19 inclusive.
 * @return Returns value / 10^exp10
 */
template <typename T>
CUDF_HOST_DEVICE inline T divide_power10_64bit(T value, int exp10)
{
  // See comments in divide_power10_32bit() for discussion.
  switch (exp10) {
    case 0: return value;
    case 1: return value / 10;
    case 2: return value / 100;
    case 3: return value / 1000;
    case 4: return value / 10000;
    case 5: return value / 100000;
    case 6: return value / 1000000;
    case 7: return value / 10000000;
    case 8: return value / 100000000;
    case 9: return value / 1000000000;
    case 10: return value / 10000000000LL;
    case 11: return value / 100000000000LL;
    case 12: return value / 1000000000000LL;
    case 13: return value / 10000000000000LL;
    case 14: return value / 100000000000000LL;
    case 15: return value / 1000000000000000LL;
    case 16: return value / 10000000000000000LL;
    case 17: return value / 100000000000000000LL;
    case 18: return value / 1000000000000000000LL;
    case 19: return value / 10000000000000000000ULL;  // 10^19 only fits if unsigned!
    default: return 0;
  }
}

/**
 * @brief Divide by a power of 10 that fits within a 128bit integer.
 *
 * @tparam T Type of value to be divided-from.
 * @param value The number to be divided-from.
 * @param exp10 The power-of-10 of the denominator, from 0 to 38 inclusive.
 * @return Returns value / 10^exp10.
 */
template <typename T>
// clang-format off
//! @cond Suppress doxygen for noinline attribute as it doesn't know how to handle it
__attribute__((noinline))
//! @endcond
CUDF_HOST_DEVICE constexpr T divide_power10_128bit(T value, int exp10)
// clang-format on
{
  // See comments in divide_power10_32bit() for an introduction.

  // However, the code generated by this function is so large that it cannot be inlined.
  // If inlined it slows down the join benchmarks, perhaps because the code itself becomes too
  // large?

  switch (exp10) {
    case 0: return value;
    case 1: return value / 10;
    case 2: return value / 100;
    case 3: return value / 1000;
    case 4: return value / 10000;
    case 5: return value / 100000;
    case 6: return value / 1000000;
    case 7: return value / 10000000;
    case 8: return value / 100000000;
    case 9: return value / 1000000000;
    case 10: return value / 10000000000LL;
    case 11: return value / 100000000000LL;
    case 12: return value / 1000000000000LL;
    case 13: return value / 10000000000000LL;
    case 14: return value / 100000000000000LL;
    case 15: return value / 1000000000000000LL;
    case 16: return value / 10000000000000000LL;
    case 17: return value / 100000000000000000LL;
    case 18: return value / 1000000000000000000LL;
    case 19: return value / large_power_of_10<19>();
    case 20: return value / large_power_of_10<20>();
    case 21: return value / large_power_of_10<21>();
    case 22: return value / large_power_of_10<22>();
    case 23: return value / large_power_of_10<23>();
    case 24: return value / large_power_of_10<24>();
    case 25: return value / large_power_of_10<25>();
    case 26: return value / large_power_of_10<26>();
    case 27: return value / large_power_of_10<27>();
    case 28: return value / large_power_of_10<28>();
    case 29: return value / large_power_of_10<29>();
    case 30: return value / large_power_of_10<30>();
    case 31: return value / large_power_of_10<31>();
    case 32: return value / large_power_of_10<32>();
    case 33: return value / large_power_of_10<33>();
    case 34: return value / large_power_of_10<34>();
    case 35: return value / large_power_of_10<35>();
    case 36: return value / large_power_of_10<36>();
    case 37: return value / large_power_of_10<37>();
    case 38: return value / large_power_of_10<38>();
    default: return 0;
  }
}

/**
 * @brief Multiply by a power of 10 that fits within a 32bit integer.
 *
 * @tparam T Type of value to be multiplied.
 * @param value The number to be multiplied.
 * @param exp10 The power-of-10 of the multiplier, from 0 to 9 inclusive.
 * @return Returns value * 10^exp10
 */
template <typename T>
CUDF_HOST_DEVICE inline constexpr T multiply_power10_32bit(T value, int exp10)
{
  // See comments in divide_power10_32bit() for discussion.
  switch (exp10) {
    case 0: return value;
    case 1: return value * 10;
    case 2: return value * 100;
    case 3: return value * 1000;
    case 4: return value * 10000;
    case 5: return value * 100000;
    case 6: return value * 1000000;
    case 7: return value * 10000000;
    case 8: return value * 100000000;
    case 9: return value * 1000000000;
    default: return 0;
  }
}

/**
 * @brief Multiply by a power of 10 that fits within a 64bit integer.
 *
 * @tparam T Type of value to be multiplied.
 * @param value The number to be multiplied.
 * @param exp10 The power-of-10 of the multiplier, from 0 to 19 inclusive.
 * @return Returns value * 10^exp10
 */
template <typename T>
CUDF_HOST_DEVICE inline constexpr T multiply_power10_64bit(T value, int exp10)
{
  // See comments in divide_power10_32bit() for discussion.
  switch (exp10) {
    case 0: return value;
    case 1: return value * 10;
    case 2: return value * 100;
    case 3: return value * 1000;
    case 4: return value * 10000;
    case 5: return value * 100000;
    case 6: return value * 1000000;
    case 7: return value * 10000000;
    case 8: return value * 100000000;
    case 9: return value * 1000000000;
    case 10: return value * 10000000000LL;
    case 11: return value * 100000000000LL;
    case 12: return value * 1000000000000LL;
    case 13: return value * 10000000000000LL;
    case 14: return value * 100000000000000LL;
    case 15: return value * 1000000000000000LL;
    case 16: return value * 10000000000000000LL;
    case 17: return value * 100000000000000000LL;
    case 18: return value * 1000000000000000000LL;
    case 19: return value * 10000000000000000000ULL;  // 10^19 only fits if unsigned!
    default: return 0;
  }
}

/**
 * @brief Multiply by a power of 10 that fits within a 128bit integer.
 *
 * @tparam T Type of value to be multiplied.
 * @param value The number to be multiplied.
 * @param exp10 The power-of-10 of the multiplier, from 0 to 38 inclusive.
 * @return Returns value * 10^exp10.
 */
template <typename T>
// clang-format off
//! @cond Suppress doxygen for noinline attribute as it doesn't know how to handle it
__attribute__((noinline))
//! @endcond
CUDF_HOST_DEVICE constexpr T multiply_power10_128bit(T value, int exp10)
// clang-format on
{
  // See comments in divide_power10_128bit() for discussion.
  switch (exp10) {
    case 0: return value;
    case 1: return value * 10;
    case 2: return value * 100;
    case 3: return value * 1000;
    case 4: return value * 10000;
    case 5: return value * 100000;
    case 6: return value * 1000000;
    case 7: return value * 10000000;
    case 8: return value * 100000000;
    case 9: return value * 1000000000;
    case 10: return value * 10000000000LL;
    case 11: return value * 100000000000LL;
    case 12: return value * 1000000000000LL;
    case 13: return value * 10000000000000LL;
    case 14: return value * 100000000000000LL;
    case 15: return value * 1000000000000000LL;
    case 16: return value * 10000000000000000LL;
    case 17: return value * 100000000000000000LL;
    case 18: return value * 1000000000000000000LL;
    case 19: return value * large_power_of_10<19>();
    case 20: return value * large_power_of_10<20>();
    case 21: return value * large_power_of_10<21>();
    case 22: return value * large_power_of_10<22>();
    case 23: return value * large_power_of_10<23>();
    case 24: return value * large_power_of_10<24>();
    case 25: return value * large_power_of_10<25>();
    case 26: return value * large_power_of_10<26>();
    case 27: return value * large_power_of_10<27>();
    case 28: return value * large_power_of_10<28>();
    case 29: return value * large_power_of_10<29>();
    case 30: return value * large_power_of_10<30>();
    case 31: return value * large_power_of_10<31>();
    case 32: return value * large_power_of_10<32>();
    case 33: return value * large_power_of_10<33>();
    case 34: return value * large_power_of_10<34>();
    case 35: return value * large_power_of_10<35>();
    case 36: return value * large_power_of_10<36>();
    case 37: return value * large_power_of_10<37>();
    case 38: return value * large_power_of_10<38>();
    default: return 0;
  }
}

/**
 * @brief Multiply an integer by a power of 10.
 *
 * @note Use this function if you have no a-priori knowledge of what exp10 might be.
 * If you do, prefer calling the bit-size-specific versions
 *
 * @tparam Rep Representation type needed for integer exponentiation
 * @tparam T Integral type of value to be multiplied.
 * @param value The number to be multiplied.
 * @param exp10 The power-of-10 of the multiplier.
 * @return Returns value * 10^exp10
 */
template <typename Rep,
          typename T,
          typename cuda::std::enable_if_t<(cuda::std::is_integral_v<T>)>* = nullptr>
CUDF_HOST_DEVICE inline constexpr T multiply_power10(T value, int exp10)
{
  // Use this function if you have no knowledge of what exp10 might be
  // If you do, prefer calling the bit-size-specific versions
  if constexpr (sizeof(Rep) <= 4) {
    return multiply_power10_32bit(value, exp10);
  } else if constexpr (sizeof(Rep) <= 8) {
    return multiply_power10_64bit(value, exp10);
  } else {
    return multiply_power10_128bit(value, exp10);
  }
}

/**
 * @brief Divide an integer by a power of 10.
 *
 * @note Use this function if you have no a-priori knowledge of what exp10 might be.
 * If you do, prefer calling the bit-size-specific versions
 *
 * @tparam Rep Representation type needed for integer exponentiation
 * @tparam T Integral type of value to be divided-from.
 * @param value The number to be divided-from.
 * @param exp10 The power-of-10 of the denominator.
 * @return Returns value / 10^exp10
 */
template <typename Rep,
          typename T,
          typename cuda::std::enable_if_t<(cuda::std::is_integral_v<T>)>* = nullptr>
CUDF_HOST_DEVICE inline constexpr T divide_power10(T value, int exp10)
{
  if constexpr (sizeof(Rep) <= 4) {
    return divide_power10_32bit(value, exp10);
  } else if constexpr (sizeof(Rep) <= 8) {
    return divide_power10_64bit(value, exp10);
  } else {
    return divide_power10_128bit(value, exp10);
  }
}

/**
 * @brief A function for integer exponentiation by squaring.
 *
 * @tparam Rep Representation type for return type
 * @tparam Base The base to be exponentiated
 * @param exponent The exponent to be used for exponentiation
 * @return Result of `Base` to the power of `exponent` of type `Rep`
 */
template <typename Rep,
          Radix Base,
          typename T,
          typename cuda::std::enable_if_t<(cuda::std::is_same_v<int32_t, T> &&
                                           is_supported_representation_type<Rep>())>* = nullptr>
CUDF_HOST_DEVICE inline Rep ipow(T exponent)
{
  cudf_assert(exponent >= 0 && "integer exponentiation with negative exponent is not possible.");

  if constexpr (Base == numeric::Radix::BASE_2) { return static_cast<Rep>(1) << exponent; }

  // Note: Including an array here introduces too much register pressure
  // https://simple.wikipedia.org/wiki/Exponentiation_by_squaring
  // This is the iterative equivalent of the recursive definition (faster)
  // Quick-bench for squaring: http://quick-bench.com/Wg7o7HYQC9FW5M0CO0wQAjSwP_Y
  if (exponent == 0) { return static_cast<Rep>(1); }
  auto extra  = static_cast<Rep>(1);
  auto square = static_cast<Rep>(Base);
  while (exponent > 1) {
    if (exponent & 1) { extra *= square; }
    exponent >>= 1;
    square *= square;
  }
  return square * extra;
}

/** @brief Function that performs a `right shift` scale "times" on the `val`
 *
 * Note: perform this operation when constructing with positive scale
 *
 * @tparam Rep Representation type needed for integer exponentiation
 * @tparam Rad The radix which will act as the base in the exponentiation
 * @tparam T Type for value `val` being shifted and the return type
 * @param val The value being shifted
 * @param scale The amount to shift the value by
 * @return Shifted value of type T
 */
template <typename Rep, Radix Rad, typename T>
CUDF_HOST_DEVICE inline constexpr T right_shift(T const& val, scale_type const& scale)
{
  auto int_scale = static_cast<int32_t>(scale);
  if constexpr (!cuda::std::is_integral_v<T>) {
    // Note: diverting to the base-10 bit-size-specific functions based on size-of rep
    // slows down the NOT_EQUAL binary-op benchmark.
    return val / ipow<Rep, Rad>(int_scale);
  } else if constexpr (Rad == Radix::BASE_10) {
    return divide_power10<Rep>(val, int_scale);
  } else if constexpr (Rad == Radix::BASE_2) {
    return val >> int_scale;
  } else {
    return val / ipow<Rep, Rad>(int_scale);
  }
}

/** @brief Function that performs a `left shift` scale "times" on the `val`
 *
 * Note: perform this operation when constructing with negative scale
 *
 * @tparam Rep Representation type needed for integer exponentiation
 * @tparam Rad The radix which will act as the base in the exponentiation
 * @tparam T Type for value `val` being shifted and the return type
 * @param val The value being shifted
 * @param scale The amount to shift the value by
 * @return Shifted value of type T
 */
template <typename Rep, Radix Rad, typename T>
CUDF_HOST_DEVICE inline constexpr T left_shift(T const& val, scale_type const& scale)
{
  auto int_scale = -static_cast<int32_t>(scale);
  if constexpr (!cuda::std::is_integral_v<T>) {
    // Note: diverting to the base-10 bit-size-specific functions based on size-of rep
    // slows down the NOT_EQUAL binary-op benchmark.
    return val * ipow<Rep, Rad>(int_scale);
  } else if constexpr (Rad == Radix::BASE_10) {
    return multiply_power10<Rep>(val, int_scale);
  } else if constexpr (Rad == Radix::BASE_2) {
    return val << int_scale;
  } else {
    return val * ipow<Rep, Rad>(int_scale);
  }
}

/** @brief Function that performs a `right` or `left shift`
 * scale "times" on the `val`
 *
 * Note: Function will call the correct right or left shift based
 * on the sign of `val`
 *
 * @tparam Rep Representation type needed for integer exponentiation
 * @tparam Rad The radix which will act as the base in the exponentiation
 * @tparam T Type for value `val` being shifted and the return type
 * @param val The value being shifted
 * @param scale The amount to shift the value by
 * @return Shifted value of type T
 */
template <typename Rep, Radix Rad, typename T>
CUDF_HOST_DEVICE inline constexpr T shift(T const& val, scale_type const& scale)
{
  if (scale == 0) { return val; }
  if (scale > 0) { return right_shift<Rep, Rad>(val, scale); }
  return left_shift<Rep, Rad>(val, scale);
}

}  // namespace detail

/**
 * @addtogroup fixed_point_classes
 * @{
 * @file
 * @brief Class definition for fixed point data type
 */

/**
 * @brief Helper struct for constructing `fixed_point` when value is already shifted
 *
 * Example:
 * ```cpp
 * using decimal32 = fixed_point<int32_t, Radix::BASE_10>;
 * auto n = decimal32{scaled_integer{1001, 3}}; // n = 1.001
 * ```
 *
 * @tparam Rep The representation type (either `int32_t` or `int64_t`)
 */
template <typename Rep,
          typename cuda::std::enable_if_t<is_supported_representation_type<Rep>()>* = nullptr>
struct scaled_integer {
  Rep value;         ///< The value of the fixed point number
  scale_type scale;  ///< The scale of the value
  /**
   * @brief Constructor for `scaled_integer`
   *
   * @param v The value of the fixed point number
   * @param s The scale of the value
   */
  CUDF_HOST_DEVICE inline explicit scaled_integer(Rep v, scale_type s) : value{v}, scale{s} {}
};

/**
 * @brief A type for representing a number with a fixed amount of precision
 *
 * Currently, only binary and decimal `fixed_point` numbers are supported.
 * Binary operations can only be performed with other `fixed_point` numbers
 *
 * @tparam Rep The representation type (either `int32_t` or `int64_t`)
 * @tparam Rad The radix/base (either `Radix::BASE_2` or `Radix::BASE_10`)
 */
template <typename Rep, Radix Rad>
class fixed_point {
  Rep _value{};
  scale_type _scale;

 public:
  using rep                 = Rep;  ///< The representation type
  static constexpr auto rad = Rad;  ///< The base

  /**
   * @brief Constructor that will perform shifting to store value appropriately (from integral
   * types)
   *
   * @tparam T The integral type that you are constructing from
   * @param value The value that will be constructed from
   * @param scale The exponent that is applied to Rad to perform shifting
   */
  template <typename T,
            typename cuda::std::enable_if_t<cuda::std::is_integral_v<T> &&
                                            is_supported_representation_type<Rep>()>* = nullptr>
  CUDF_HOST_DEVICE inline explicit fixed_point(T const& value, scale_type const& scale)
    // `value` is cast to `Rep` to avoid overflow in cases where
    // constructing to `Rep` that is wider than `T`
    : _value{detail::shift<Rep, Rad>(static_cast<Rep>(value), scale)}, _scale{scale}
  {
  }

  /**
   * @brief Constructor that will not perform shifting (assumes value already shifted)
   *
   * @param s scaled_integer that contains scale and already shifted value
   */
  CUDF_HOST_DEVICE inline explicit fixed_point(scaled_integer<Rep> s)
    : _value{s.value}, _scale{s.scale}
  {
  }

  /**
   * @brief "Scale-less" constructor that constructs `fixed_point` number with a specified
   * value and scale of zero
   *
   * @tparam T The value type being constructing from
   * @param value The value that will be constructed from
   */
  template <typename T, typename cuda::std::enable_if_t<cuda::std::is_integral_v<T>>* = nullptr>
  CUDF_HOST_DEVICE inline fixed_point(T const& value)
    : _value{static_cast<Rep>(value)}, _scale{scale_type{0}}
  {
  }

  /**
   * @brief Default constructor that constructs `fixed_point` number with a
   * value and scale of zero
   */
  CUDF_HOST_DEVICE inline fixed_point() : _scale{scale_type{0}} {}

  /**
   * @brief Explicit conversion operator for casting to integral types
   *
   * @tparam U The integral type that is being explicitly converted to
   * @return The `fixed_point` number in base 10 (aka human readable format)
   */
  template <typename U, typename cuda::std::enable_if_t<cuda::std::is_integral_v<U>>* = nullptr>
  explicit constexpr operator U() const
  {
    // Cast to the larger of the two types (of U and Rep) before converting to Rep because in
    // certain cases casting to U before shifting will result in integer overflow (i.e. if U =
    // int32_t, Rep = int64_t and _value > 2 billion)
    auto const value = std::common_type_t<U, Rep>(_value);
    return static_cast<U>(detail::shift<Rep, Rad>(value, scale_type{-_scale}));
  }

  /**
   * @brief Converts the `fixed_point` number to a `scaled_integer`
   *
   * @return The `scaled_integer` representation of the `fixed_point` number
   */
  CUDF_HOST_DEVICE inline operator scaled_integer<Rep>() const
  {
    return scaled_integer<Rep>{_value, _scale};
  }

  /**
   * @brief Method that returns the underlying value of the `fixed_point` number
   *
   * @return The underlying value of the `fixed_point` number
   */
  CUDF_HOST_DEVICE inline rep value() const { return _value; }

  /**
   * @brief Method that returns the scale of the `fixed_point` number
   *
   * @return The scale of the `fixed_point` number
   */
  CUDF_HOST_DEVICE inline scale_type scale() const { return _scale; }

  /**
   * @brief Explicit conversion operator to `bool`
   *
   * @return The `fixed_point` value as a boolean (zero is `false`, nonzero is `true`)
   */
  CUDF_HOST_DEVICE inline explicit constexpr operator bool() const
  {
    return static_cast<bool>(_value);
  }

  /**
   * @brief operator +=
   *
   * @tparam Rep1 Representation type of the operand `rhs`
   * @tparam Rad1 Radix (base) type of the operand `rhs`
   * @param rhs The number being added to `this`
   * @return The sum
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1>& operator+=(fixed_point<Rep1, Rad1> const& rhs)
  {
    *this = *this + rhs;
    return *this;
  }

  /**
   * @brief operator *=
   *
   * @tparam Rep1 Representation type of the operand `rhs`
   * @tparam Rad1 Radix (base) type of the operand `rhs`
   * @param rhs The number being multiplied to `this`
   * @return The product
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1>& operator*=(fixed_point<Rep1, Rad1> const& rhs)
  {
    *this = *this * rhs;
    return *this;
  }

  /**
   * @brief operator -=
   *
   * @tparam Rep1 Representation type of the operand `rhs`
   * @tparam Rad1 Radix (base) type of the operand `rhs`
   * @param rhs The number being subtracted from `this`
   * @return The difference
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1>& operator-=(fixed_point<Rep1, Rad1> const& rhs)
  {
    *this = *this - rhs;
    return *this;
  }

  /**
   * @brief operator /=
   *
   * @tparam Rep1 Representation type of the operand `rhs`
   * @tparam Rad1 Radix (base) type of the operand `rhs`
   * @param rhs The number being divided from `this`
   * @return The quotient
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1>& operator/=(fixed_point<Rep1, Rad1> const& rhs)
  {
    *this = *this / rhs;
    return *this;
  }

  /**
   * @brief operator ++ (post-increment)
   *
   * @return The incremented result
   */
  CUDF_HOST_DEVICE inline fixed_point<Rep, Rad>& operator++()
  {
    *this = *this + fixed_point<Rep, Rad>{1, scale_type{_scale}};
    return *this;
  }

  /**
   * @brief operator + (for adding two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are added.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are added.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return The resulting `fixed_point` sum
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend fixed_point<Rep1, Rad1> operator+(
    fixed_point<Rep1, Rad1> const& lhs, fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator - (for subtracting two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are subtracted.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are subtracted.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return The resulting `fixed_point` difference
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend fixed_point<Rep1, Rad1> operator-(
    fixed_point<Rep1, Rad1> const& lhs, fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator * (for multiplying two `fixed_point` numbers)
   *
   * `_scale`s are added and `_value`s are multiplied.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return The resulting `fixed_point` product
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend fixed_point<Rep1, Rad1> operator*(
    fixed_point<Rep1, Rad1> const& lhs, fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator / (for dividing two `fixed_point` numbers)
   *
   * `_scale`s are subtracted and `_value`s are divided.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return The resulting `fixed_point` quotient
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend fixed_point<Rep1, Rad1> operator/(
    fixed_point<Rep1, Rad1> const& lhs, fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator % (for computing the modulo operation of two `fixed_point` numbers)
   *
   * If `_scale`s are equal, the modulus is computed directly.
   * If `_scale`s are not equal, the number with larger `_scale` is shifted to the
   * smaller `_scale`, and then the modulus is computed.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return The resulting `fixed_point` number
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend fixed_point<Rep1, Rad1> operator%(
    fixed_point<Rep1, Rad1> const& lhs, fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator == (for comparing two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are compared.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are compared.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return true if `lhs` and `rhs` are equal, false if not
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend bool operator==(fixed_point<Rep1, Rad1> const& lhs,
                                                 fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator != (for comparing two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are compared.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are compared.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return true if `lhs` and `rhs` are not equal, false if not
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend bool operator!=(fixed_point<Rep1, Rad1> const& lhs,
                                                 fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator <= (for comparing two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are compared.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are compared.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return true if `lhs` less than or equal to `rhs`, false if not
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend bool operator<=(fixed_point<Rep1, Rad1> const& lhs,
                                                 fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator >= (for comparing two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are compared.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are compared.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return true if `lhs` greater than or equal to `rhs`, false if not
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend bool operator>=(fixed_point<Rep1, Rad1> const& lhs,
                                                 fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator < (for comparing two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are compared.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are compared.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return true if `lhs` less than `rhs`, false if not
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend bool operator<(fixed_point<Rep1, Rad1> const& lhs,
                                                fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief operator > (for comparing two `fixed_point` numbers)
   *
   * If `_scale`s are equal, `_value`s are compared.
   * If `_scale`s are not equal, the number with the larger `_scale` is shifted to the
   * smaller `_scale`, and then the `_value`s are compared.
   *
   * @tparam Rep1 Representation type of the operand `lhs` and `rhs`
   * @tparam Rad1 Radix (base) type of the operand `lhs` and `rhs`
   * @param lhs The left hand side operand
   * @param rhs The right hand side operand
   * @return true if `lhs` greater than `rhs`, false if not
   */
  template <typename Rep1, Radix Rad1>
  CUDF_HOST_DEVICE inline friend bool operator>(fixed_point<Rep1, Rad1> const& lhs,
                                                fixed_point<Rep1, Rad1> const& rhs);

  /**
   * @brief Method for creating a `fixed_point` number with a new `scale`
   *
   * The `fixed_point` number returned will have the same value, underlying representation and
   * radix as `this`, the only thing changed is the scale.
   *
   * @param scale The `scale` of the returned `fixed_point` number
   * @return `fixed_point` number with a new `scale`
   */
  CUDF_HOST_DEVICE inline fixed_point<Rep, Rad> rescaled(scale_type scale) const
  {
    if (scale == _scale) { return *this; }
    Rep const value = detail::shift<Rep, Rad>(_value, scale_type{scale - _scale});
    return fixed_point<Rep, Rad>{scaled_integer<Rep>{value, scale}};
  }

  /**
   * @brief Returns a string representation of the fixed_point value.
   */
  explicit operator std::string() const
  {
    if (_scale < 0) {
      auto const av = detail::abs(_value);
      Rep const n   = detail::exp10<Rep>(-_scale);
      Rep const f   = av % n;
      auto const num_zeros =
        std::max(0, (-_scale - static_cast<int32_t>(detail::to_string(f).size())));
      auto const zeros = std::string(num_zeros, '0');
      auto const sign  = _value < 0 ? std::string("-") : std::string();
      return sign + detail::to_string(av / n) + std::string(".") + zeros +
             detail::to_string(av % n);
    }
    auto const zeros = std::string(_scale, '0');
    return detail::to_string(_value) + zeros;
  }
};

/**
 *  @brief Function for identifying integer overflow when adding
 *
 * @tparam Rep Type of integer to check for overflow on
 * @tparam T Types of lhs and rhs (ensures they are the same type)
 * @param lhs Left hand side of addition
 * @param rhs Right hand side of addition
 * @return true if addition causes overflow, false otherwise
 */
template <typename Rep, typename T>
CUDF_HOST_DEVICE inline auto addition_overflow(T lhs, T rhs)
{
  return rhs > 0 ? lhs > cuda::std::numeric_limits<Rep>::max() - rhs
                 : lhs < cuda::std::numeric_limits<Rep>::min() - rhs;
}

/** @brief Function for identifying integer overflow when subtracting
 *
 * @tparam Rep Type of integer to check for overflow on
 * @tparam T Types of lhs and rhs (ensures they are the same type)
 * @param lhs Left hand side of subtraction
 * @param rhs Right hand side of subtraction
 * @return true if subtraction causes overflow, false otherwise
 */
template <typename Rep, typename T>
CUDF_HOST_DEVICE inline auto subtraction_overflow(T lhs, T rhs)
{
  return rhs > 0 ? lhs < cuda::std::numeric_limits<Rep>::min() + rhs
                 : lhs > cuda::std::numeric_limits<Rep>::max() + rhs;
}

/** @brief Function for identifying integer overflow when dividing
 *
 * @tparam Rep Type of integer to check for overflow on
 * @tparam T Types of lhs and rhs (ensures they are the same type)
 * @param lhs Left hand side of division
 * @param rhs Right hand side of division
 * @return true if division causes overflow, false otherwise
 */
template <typename Rep, typename T>
CUDF_HOST_DEVICE inline auto division_overflow(T lhs, T rhs)
{
  return lhs == cuda::std::numeric_limits<Rep>::min() && rhs == -1;
}

/** @brief Function for identifying integer overflow when multiplying
 *
 * @tparam Rep Type of integer to check for overflow on
 * @tparam T Types of lhs and rhs (ensures they are the same type)
 * @param lhs Left hand side of multiplication
 * @param rhs Right hand side of multiplication
 * @return true if multiplication causes overflow, false otherwise
 */
template <typename Rep, typename T>
CUDF_HOST_DEVICE inline auto multiplication_overflow(T lhs, T rhs)
{
  auto const min = cuda::std::numeric_limits<Rep>::min();
  auto const max = cuda::std::numeric_limits<Rep>::max();
  if (rhs > 0) { return lhs > max / rhs || lhs < min / rhs; }
  if (rhs < -1) { return lhs > min / rhs || lhs < max / rhs; }
  return rhs == -1 && lhs == min;
}

// PLUS Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1> operator+(fixed_point<Rep1, Rad1> const& lhs,
                                                          fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  auto const sum   = lhs.rescaled(scale)._value + rhs.rescaled(scale)._value;

#if defined(__CUDACC_DEBUG__)

  assert(!addition_overflow<Rep1>(lhs.rescaled(scale)._value, rhs.rescaled(scale)._value) &&
         "fixed_point overflow");

#endif

  return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>{sum, scale}};
}

// MINUS Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1> operator-(fixed_point<Rep1, Rad1> const& lhs,
                                                          fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  auto const diff  = lhs.rescaled(scale)._value - rhs.rescaled(scale)._value;

#if defined(__CUDACC_DEBUG__)

  assert(!subtraction_overflow<Rep1>(lhs.rescaled(scale)._value, rhs.rescaled(scale)._value) &&
         "fixed_point overflow");

#endif

  return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>{diff, scale}};
}

// MULTIPLIES Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1> operator*(fixed_point<Rep1, Rad1> const& lhs,
                                                          fixed_point<Rep1, Rad1> const& rhs)
{
#if defined(__CUDACC_DEBUG__)

  assert(!multiplication_overflow<Rep1>(lhs._value, rhs._value) && "fixed_point overflow");

#endif

  return fixed_point<Rep1, Rad1>{
    scaled_integer<Rep1>(lhs._value * rhs._value, scale_type{lhs._scale + rhs._scale})};
}

// DIVISION Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1> operator/(fixed_point<Rep1, Rad1> const& lhs,
                                                          fixed_point<Rep1, Rad1> const& rhs)
{
#if defined(__CUDACC_DEBUG__)

  assert(!division_overflow<Rep1>(lhs._value, rhs._value) && "fixed_point overflow");

#endif

  return fixed_point<Rep1, Rad1>{
    scaled_integer<Rep1>(lhs._value / rhs._value, scale_type{lhs._scale - rhs._scale})};
}

// EQUALITY COMPARISON Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline bool operator==(fixed_point<Rep1, Rad1> const& lhs,
                                        fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  return lhs.rescaled(scale)._value == rhs.rescaled(scale)._value;
}

// EQUALITY NOT COMPARISON Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline bool operator!=(fixed_point<Rep1, Rad1> const& lhs,
                                        fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  return lhs.rescaled(scale)._value != rhs.rescaled(scale)._value;
}

// LESS THAN OR EQUAL TO Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline bool operator<=(fixed_point<Rep1, Rad1> const& lhs,
                                        fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  return lhs.rescaled(scale)._value <= rhs.rescaled(scale)._value;
}

// GREATER THAN OR EQUAL TO Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline bool operator>=(fixed_point<Rep1, Rad1> const& lhs,
                                        fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  return lhs.rescaled(scale)._value >= rhs.rescaled(scale)._value;
}

// LESS THAN Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline bool operator<(fixed_point<Rep1, Rad1> const& lhs,
                                       fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  return lhs.rescaled(scale)._value < rhs.rescaled(scale)._value;
}

// GREATER THAN Operation
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline bool operator>(fixed_point<Rep1, Rad1> const& lhs,
                                       fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale = std::min(lhs._scale, rhs._scale);
  return lhs.rescaled(scale)._value > rhs.rescaled(scale)._value;
}

// MODULO OPERATION
template <typename Rep1, Radix Rad1>
CUDF_HOST_DEVICE inline fixed_point<Rep1, Rad1> operator%(fixed_point<Rep1, Rad1> const& lhs,
                                                          fixed_point<Rep1, Rad1> const& rhs)
{
  auto const scale     = std::min(lhs._scale, rhs._scale);
  auto const remainder = lhs.rescaled(scale)._value % rhs.rescaled(scale)._value;
  return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>{remainder, scale}};
}

using decimal32  = fixed_point<int32_t, Radix::BASE_10>;     ///<  32-bit decimal fixed point
using decimal64  = fixed_point<int64_t, Radix::BASE_10>;     ///<  64-bit decimal fixed point
using decimal128 = fixed_point<__int128_t, Radix::BASE_10>;  ///< 128-bit decimal fixed point

/** @} */  // end of group
}  // namespace numeric
