// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// A hollow column is a composite column with a null (moved-from) subcolumn pointer.
// These tests build one of each kind and check that no entry point dereferences the
// null: predicates answer false, checks throw doris::Exception, and Block rebuilds.

#include <gtest/gtest.h>

#include <memory>
#include <utility>
#include <vector>

#include "common/exception.h"
#include "core/block/block.h"
#include "core/column/column_array.h"
#include "core/column/column_const.h"
#include "core/column/column_map.h"
#include "core/column/column_nullable.h"
#include "core/column/column_struct.h"
#include "core/column/column_vector.h"
#include "core/data_type/data_type_array.h"
#include "core/data_type/data_type_nullable.h"
#include "core/data_type/data_type_number.h"

namespace doris {
namespace {

ColumnInt64::MutablePtr create_int64_column() {
    auto column = ColumnInt64::create();
    column->insert_value(1);
    return column;
}

ColumnUInt8::MutablePtr create_null_map() {
    auto column = ColumnUInt8::create();
    column->insert_value(0);
    return column;
}

ColumnArray::ColumnOffsets::MutablePtr create_single_element_offsets() {
    auto offsets = ColumnArray::ColumnOffsets::create();
    offsets->insert_value(1);
    return offsets;
}

ColumnNullable::MutablePtr create_nullable() {
    return ColumnNullable::create(create_int64_column(), create_null_map());
}

// The public non-const accessors of ColumnNullable return copies, so tests reach the
// member through the const accessor to simulate a moved-from child.
void hollow_nested(ColumnNullable& nullable) {
    const_cast<ColumnPtr&>(std::as_const(nullable).get_nested_column_ptr()) = nullptr;
}

void hollow_null_map(ColumnNullable& nullable) {
    const_cast<ColumnUInt8::Ptr&>(std::as_const(nullable).get_null_map_column_ptr()) = nullptr;
}

void expect_never_dereferenced(const IColumn& column) {
    EXPECT_TRUE(column.is_hollow());
    EXPECT_THROW(static_cast<void>(column.is_exclusive()), doris::Exception);
    EXPECT_THROW(column.sanity_check(), doris::Exception);
    IColumn::ColumnCallback callback = [](const IColumn&) {};
    EXPECT_THROW(column.for_each_subcolumn(callback), doris::Exception);
}

} // namespace

TEST(ColumnHollowTest, IntactColumnsAreNotHollow) {
    EXPECT_FALSE(create_int64_column()->is_hollow());
    EXPECT_FALSE(create_nullable()->is_hollow());
    EXPECT_FALSE(
            ColumnArray::create(create_nullable(), create_single_element_offsets())->is_hollow());
}

TEST(ColumnHollowTest, NullableWithNullNested) {
    // Prod SIGSEGV 2026-11-13: ColumnNullable::sanity_check dereferenced a null
    // _nested_column on the local shuffle (Crc32HashPartitioner) path.
    auto nullable = create_nullable();
    hollow_nested(*nullable);
    expect_never_dereferenced(*nullable);
}

TEST(ColumnHollowTest, NullableWithNullNullMap) {
    auto nullable = create_nullable();
    hollow_null_map(*nullable);
    expect_never_dereferenced(*nullable);
}

TEST(ColumnHollowTest, ArrayWithNullData) {
    auto array = ColumnArray::create(create_nullable(), create_single_element_offsets());
    array->get_data_ptr() = nullptr;
    expect_never_dereferenced(*array);
}

TEST(ColumnHollowTest, ArrayWithNullOffsets) {
    auto array = ColumnArray::create(create_nullable(), create_single_element_offsets());
    array->get_offsets_ptr() = nullptr;
    expect_never_dereferenced(*array);
}

TEST(ColumnHollowTest, ArrayWithHollowGrandchild) {
    // Prod SIGSEGV 2026-09-10 (column_array.h, Iceberg Parquet scan): the null was one
    // level below the array, so is_exclusive() and is_hollow() must look through it.
    auto nullable = create_nullable();
    hollow_nested(*nullable);
    auto array = ColumnArray::create(std::move(nullable), create_single_element_offsets());
    EXPECT_TRUE(array->is_hollow());
    EXPECT_THROW(static_cast<void>(array->is_exclusive()), doris::Exception);
    EXPECT_THROW(array->sanity_check(), doris::Exception);
}

TEST(ColumnHollowTest, MapWithNullChildren) {
    auto map_null_keys = ColumnMap::create(create_int64_column(), create_int64_column(),
                                           create_single_element_offsets());
    map_null_keys->get_keys_ptr() = nullptr;
    expect_never_dereferenced(*map_null_keys);

    auto map_null_values = ColumnMap::create(create_int64_column(), create_int64_column(),
                                             create_single_element_offsets());
    map_null_values->get_values_ptr() = nullptr;
    expect_never_dereferenced(*map_null_values);

    auto map_null_offsets = ColumnMap::create(create_int64_column(), create_int64_column(),
                                              create_single_element_offsets());
    map_null_offsets->get_offsets_ptr() = nullptr;
    expect_never_dereferenced(*map_null_offsets);
}

TEST(ColumnHollowTest, StructWithNullField) {
    MutableColumns fields;
    fields.push_back(create_int64_column());
    fields.push_back(create_nullable());
    auto st = ColumnStruct::create(std::move(fields));
    st->get_column_ptr(1) = nullptr;
    expect_never_dereferenced(*st);
}

TEST(ColumnHollowTest, ConstWithNullData) {
    auto constant = ColumnConst::create(create_int64_column(), 3);
    auto& const_ref = *constant;
    const_cast<ColumnPtr&>(std::as_const(const_ref).get_data_column_ptr()) = nullptr;
    EXPECT_TRUE(const_ref.is_hollow());
    EXPECT_THROW(static_cast<void>(const_ref.is_exclusive()), doris::Exception);
    IColumn::ColumnCallback callback = [](const IColumn&) {};
    EXPECT_THROW(const_ref.for_each_subcolumn(callback), doris::Exception);
}

TEST(ColumnHollowTest, MutateThrows) {
    auto array = ColumnArray::create(create_nullable(), create_single_element_offsets());
    array->get_data_ptr() = nullptr;
    ColumnPtr shell = std::move(array);
    EXPECT_THROW(static_cast<void>(IColumn::mutate(std::move(shell))), doris::Exception);
}

TEST(ColumnHollowTest, BlockClearColumnDataThrowsOnHollowSlot) {
    // Prod SIGSEGV 2026-09-10: Block::clear_column_data -> is_recursively_exclusive ->
    // ColumnArray::is_exclusive dereferenced the null child. Both the exclusive (clear in
    // place) and the shared (clone_empty) branches must throw instead.
    auto type = std::make_shared<DataTypeArray>(make_nullable(std::make_shared<DataTypeInt64>()));
    auto make_hollow_array = []() -> ColumnPtr {
        auto nullable = create_nullable();
        hollow_nested(*nullable);
        return ColumnArray::create(std::move(nullable), create_single_element_offsets());
    };

    Block exclusive_block({ColumnWithTypeAndName(make_hollow_array(), type, "a")});
    EXPECT_THROW(exclusive_block.clear_column_data(), doris::Exception);
    EXPECT_THROW(exclusive_block.clear_column_data(std::vector<uint32_t> {0}), doris::Exception);

    ColumnPtr shared = make_hollow_array();
    Block shared_block({ColumnWithTypeAndName(shared, type, "a")});
    EXPECT_THROW(shared_block.clear_column_data(), doris::Exception);
    EXPECT_THROW(shared_block.clear_column_data(std::vector<uint32_t> {0}), doris::Exception);
}

TEST(ColumnHollowTest, BlockClearColumnDataKeepsWorkingOnIntactSlots) {
    auto type = std::make_shared<DataTypeArray>(make_nullable(std::make_shared<DataTypeInt64>()));
    ColumnPtr shared = ColumnArray::create(create_nullable(), create_single_element_offsets());
    Block block({ColumnWithTypeAndName(shared, type, "a")});
    block.clear_column_data();
    EXPECT_EQ(block.get_by_position(0).column->size(), 0);
    EXPECT_EQ(shared->size(), 1);
}

} // namespace doris
