# Copyright (c) 2024, NVIDIA CORPORATION.
from libcpp.memory cimport unique_ptr
from libcpp.utility cimport move

from rmm._lib.device_buffer cimport DeviceBuffer, device_buffer

from cudf._lib.cpp.column.column cimport column
from cudf._lib.cpp.column.column_factories cimport (
    make_duration_column as cpp_make_duration_column,
    make_empty_column as cpp_make_empty_column,
    make_fixed_point_column as cpp_make_fixed_point_column,
    make_fixed_width_column as cpp_make_fixed_width_column,
    make_numeric_column as cpp_make_numeric_column,
    make_timestamp_column as cpp_make_timestamp_column,
)
from cudf._lib.cpp.types cimport mask_state, size_type

from .types cimport DataType, type_id

from .types import MaskState, TypeId


cpdef Column make_empty_column(MakeEmptyColumnOperand type_or_id):
    cdef unique_ptr[column] result
    cdef type_id id

    if MakeEmptyColumnOperand is object:
        if isinstance(type_or_id, TypeId):
            id = type_or_id
            with nogil:
                result = move(
                    cpp_make_empty_column(
                        id
                    )
                )
        else:
            raise TypeError(
                "Must pass a TypeId or DataType"
            )
    elif MakeEmptyColumnOperand is DataType:
        with nogil:
            result = move(
                cpp_make_empty_column(
                    type_or_id.c_obj
                )
            )
    elif MakeEmptyColumnOperand is type_id:
        with nogil:
            result = move(
                cpp_make_empty_column(
                    type_or_id
                )
            )
    else:
        raise TypeError(
            "Must pass a TypeId or DataType"
        )
    return Column.from_libcudf(move(result))


cpdef Column make_numeric_column(
    DataType type_,
    size_type size,
    MaskArg mstate
):

    cdef unique_ptr[column] result
    cdef mask_state state
    cdef DeviceBuffer mask_buf
    cdef device_buffer mask
    cdef size_type null_count

    if MaskArg is object:
        if isinstance(mstate, MaskState):
            state = mstate
            with nogil:
                result = move(
                    cpp_make_numeric_column(
                        type_.c_obj,
                        size,
                        state
                    )
                )
        else:
            raise TypeError("Invalid mask argument")
    elif MaskArg is tuple:
        mask_buf, null_count = mstate
        mask = move(mask_buf.c_release())

        with nogil:
            result = move(
                cpp_make_numeric_column(
                    type_.c_obj,
                    size,
                    move(mask),
                    null_count
                )
            )
    else:
        raise TypeError("Invalid mask argument")

    return Column.from_libcudf(move(result))

cpdef Column make_fixed_point_column(
    DataType type_,
    size_type size,
    MaskArg mstate
):

    cdef unique_ptr[column] result
    cdef mask_state state
    cdef DeviceBuffer mask_buf
    cdef device_buffer mask
    cdef size_type null_count

    if MaskArg is object:
        if isinstance(mstate, MaskState):
            state = mstate
            with nogil:
                result = move(
                    cpp_make_fixed_point_column(
                        type_.c_obj,
                        size,
                        state
                    )
                )
        else:
            raise TypeError("Invalid mask argument")
    elif MaskArg is tuple:
        mask_buf, null_count = mstate
        mask = move(mask_buf.c_release())

        with nogil:
            result = move(
                cpp_make_fixed_point_column(
                    type_.c_obj,
                    size,
                    move(mask),
                    null_count
                )
            )
    else:
        raise TypeError("Invalid mask argument")

    return Column.from_libcudf(move(result))

cpdef Column make_timestamp_column(
    DataType type_,
    size_type size,
    MaskArg mstate
):

    cdef unique_ptr[column] result
    cdef mask_state state
    cdef DeviceBuffer mask_buf
    cdef device_buffer mask
    cdef size_type null_count

    if MaskArg is object:
        if isinstance(mstate, MaskState):
            state = mstate
            with nogil:
                result = move(
                    cpp_make_timestamp_column(
                        type_.c_obj,
                        size,
                        state
                    )
                )
        else:
            raise TypeError("Invalid mask argument")
    elif MaskArg is tuple:
        mask_buf, null_count = mstate
        mask = move(mask_buf.c_release())

        with nogil:
            result = move(
                cpp_make_timestamp_column(
                    type_.c_obj,
                    size,
                    move(mask),
                    null_count
                )
            )
    else:
        raise TypeError("Invalid mask argument")

    return Column.from_libcudf(move(result))

cpdef Column make_duration_column(
    DataType type_,
    size_type size,
    MaskArg mstate
):

    cdef unique_ptr[column] result
    cdef mask_state state
    cdef DeviceBuffer mask_buf
    cdef device_buffer mask
    cdef size_type null_count

    if MaskArg is object:
        if isinstance(mstate, MaskState):
            state = mstate
            with nogil:
                result = move(
                    cpp_make_duration_column(
                        type_.c_obj,
                        size,
                        state
                    )
                )
        else:
            raise TypeError("Invalid mask argument")
    elif MaskArg is tuple:
        mask_buf, null_count = mstate
        mask = move(mask_buf.c_release())

        with nogil:
            result = move(
                cpp_make_duration_column(
                    type_.c_obj,
                    size,
                    move(mask),
                    null_count
                )
            )
    else:
        raise TypeError("Invalid mask argument")

    return Column.from_libcudf(move(result))

cpdef Column make_fixed_width_column(
    DataType type_,
    size_type size,
    MaskArg mstate
):

    cdef unique_ptr[column] result
    cdef mask_state state
    cdef DeviceBuffer mask_buf
    cdef device_buffer mask
    cdef size_type null_count

    if MaskArg is object:
        if isinstance(mstate, MaskState):
            state = mstate
            with nogil:
                result = move(
                    cpp_make_fixed_width_column(
                        type_.c_obj,
                        size,
                        state
                    )
                )
        else:
            raise TypeError("Invalid mask argument")
    elif MaskArg is tuple:
        mask_buf, null_count = mstate
        mask = move(mask_buf.c_release())

        with nogil:
            result = move(
                cpp_make_fixed_width_column(
                    type_.c_obj,
                    size,
                    move(mask),
                    null_count
                )
            )
    else:
        raise TypeError("Invalid mask argument")

    return Column.from_libcudf(move(result))
