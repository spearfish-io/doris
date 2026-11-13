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

// Hollow (moved-from) composite columns, and the read-only traversal race that produced them.
// Prod: SIGSEGV @0x18 in ColumnNullable::sanity_check() on the local-shuffle partitioner path
// (2026-10-31, 2026-11-13). for_each_subcolumn used to MOVE a Nullable's null map (and an
// Array/Map's offsets) out for the duration of the callback, so a thread reading a shared column
// while another thread walked it (Block::clear_column_data -> is_recursively_intact) saw null.

#include <gtest/gtest.h>

#include <atomic>
#include <functional>
#include <memory>
#include <thread>
#include <utility>

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

ColumnNullable::MutablePtr create_nullable(size_t rows) {
    auto nested = ColumnInt64::create();
    for (size_t i = 0; i < rows; ++i) {
        nested->insert_value(static_cast<int64_t>(i));
    }
    return ColumnNullable::create(std::move(nested), ColumnUInt8::create(rows, 0));
}

ColumnArray::MutablePtr create_array() {
    auto data = ColumnInt64::create();
    data->insert_value(1);
    data->insert_value(2);
    auto offsets = ColumnArray::ColumnOffsets::create();
    offsets->insert_value(2);
    return ColumnArray::create(std::move(data), std::move(offsets));
}

ColumnMap::MutablePtr create_map() {
    auto keys = ColumnInt64::create();
    keys->insert_value(1);
    auto values = ColumnInt64::create();
    values->insert_value(10);
    auto offsets = ColumnArray::ColumnOffsets::create();
    offsets->insert_value(1);
    return ColumnMap::create(std::move(keys), std::move(values), std::move(offsets));
}

void expect_hollow_error(const std::function<void()>& function) {
    try {
        function();
        ADD_FAILURE() << "expected a hollow-column doris::Exception";
    } catch (const Exception& e) {
        EXPECT_EQ(e.code(), ErrorCode::INTERNAL_ERROR);
        EXPECT_NE(e.message().find("hollow column"), std::string::npos) << e.message();
    }
}

} // namespace

// Root cause, deterministic: while for_each_subcolumn runs its callback, the column must still be
// whole. The old Nullable/Array/Map traversal moved a child out here, so this sanity_check was the
// prod SIGSEGV.
TEST(ColumnHollowTest, ReadOnlyTraversalNeverHollowsTheColumn) {
    ColumnPtr nullable = create_nullable(3);
    const auto& nullable_ref = assert_cast<const ColumnNullable&>(*nullable);
    nullable->for_each_subcolumn([&](const IColumn&) {
        ASSERT_NE(nullable_ref.get_null_map_column_ptr().get(), nullptr);
        ASSERT_NE(nullable_ref.get_nested_column_ptr().get(), nullptr);
        EXPECT_NO_THROW(nullable->sanity_check());
    });

    ColumnPtr array = create_array();
    const auto& array_ref = assert_cast<const ColumnArray&>(*array);
    array->for_each_subcolumn([&](const IColumn&) {
        ASSERT_NE(array_ref.get_offsets_ptr().get(), nullptr);
        ASSERT_NE(array_ref.get_data_ptr().get(), nullptr);
        EXPECT_NO_THROW(array->sanity_check());
    });

    ColumnPtr map = create_map();
    const auto& map_ref = assert_cast<const ColumnMap&>(*map);
    map->for_each_subcolumn([&](const IColumn&) {
        ASSERT_NE(map_ref.get_offsets_ptr().get(), nullptr);
        EXPECT_NO_THROW(map->sanity_check());
    });
}

// The prod shape: one pipeline task clears its Block slot while another evaluates partition
// expressions (sanity_check) over the same shared column. Before the fix this crashed or tripped
// "hollow column" within a few thousand iterations; now the shared column is never written.
TEST(ColumnHollowTest, ClearingASharedColumnDoesNotRaceWithSanityCheck) {
    auto type = make_nullable(std::make_shared<DataTypeInt64>());
    ColumnPtr shared = create_nullable(64);

    std::atomic<bool> stop {false};
    std::atomic<size_t> reader_errors {0};
    std::thread reader([&] {
        while (!stop.load(std::memory_order_relaxed)) {
            try {
                shared->sanity_check();
            } catch (const Exception&) {
                reader_errors.fetch_add(1);
            }
        }
    });

    for (int i = 0; i < 20000; ++i) {
        Block block;
        block.insert({shared, type, "c0"});
        // Non-exclusive (shared with `shared`): walks the tree via is_recursively_intact.
        block.clear_column_data();
        ASSERT_EQ(block.get_by_position(0).column->size(), 0);
    }
    stop = true;
    reader.join();

    EXPECT_EQ(reader_errors.load(), 0);
    EXPECT_EQ(shared->size(), 64);
    EXPECT_NO_THROW(shared->sanity_check());
}

// A genuinely hollow column fails the query with a doris::Exception instead of a SIGSEGV.
TEST(ColumnHollowTest, NullableWithNullNestedThrows) {
    auto nullable = create_nullable(2);
    ColumnPtr none;
    nullable->change_nested_column(none);
    expect_hollow_error([&] { nullable->sanity_check(); });
    expect_hollow_error([&] { nullable->for_each_subcolumn([](const IColumn&) {}); });
    EXPECT_FALSE(nullable->is_exclusive());
}

TEST(ColumnHollowTest, ArrayWithMovedOutOffsetsThrows) {
    auto array = create_array();
    ColumnArray::ColumnOffsets::Ptr moved_out = std::move(array->get_offsets_ptr());
    ASSERT_NE(moved_out.get(), nullptr);
    expect_hollow_error([&] { array->sanity_check(); });
    expect_hollow_error([&] { array->for_each_subcolumn([](const IColumn&) {}); });
    EXPECT_FALSE(array->is_exclusive());

    ColumnPtr hollow = std::move(array);
    expect_hollow_error([&] { IColumn::mutate(std::move(hollow)); });
}

TEST(ColumnHollowTest, MapWithMovedOutKeysThrows) {
    auto map = create_map();
    ColumnPtr moved_out = std::move(map->get_keys_ptr());
    ASSERT_NE(moved_out.get(), nullptr);
    expect_hollow_error([&] { map->sanity_check(); });
    expect_hollow_error([&] { map->for_each_subcolumn([](const IColumn&) {}); });
    EXPECT_FALSE(map->is_exclusive());
}

TEST(ColumnHollowTest, StructWithHollowChildThrows) {
    auto nullable = create_nullable(2);
    auto* nullable_raw = nullable.get();
    Columns children;
    children.emplace_back(std::move(nullable));
    auto tuple = ColumnStruct::create(children);
    ColumnPtr none;
    nullable_raw->change_nested_column(none);
    expect_hollow_error([&] { tuple->sanity_check(); });
}

TEST(ColumnHollowTest, ConstOfHollowArrayThrows) {
    auto array = create_array();
    auto* array_raw = array.get();
    ColumnPtr constant = ColumnConst::create(std::move(array), 5);
    ColumnArray::ColumnOffsets::Ptr moved_out = std::move(array_raw->get_offsets_ptr());
    expect_hollow_error([&] { constant->sanity_check(); });
    expect_hollow_error([&] { constant->for_each_subcolumn([](const IColumn&) {}); });
}

// Block::clear_column_data rebuilds a hollow slot from its type (aaf48d7e0), now via the
// read-only traversal.
TEST(ColumnHollowTest, ClearColumnDataRebuildsHollowSlotFromType) {
    auto type = std::make_shared<DataTypeArray>(std::make_shared<DataTypeInt64>());
    auto array = create_array();
    auto* array_raw = array.get();
    Block block;
    block.insert({std::move(array), type, "a"});
    ColumnArray::ColumnOffsets::Ptr moved_out = std::move(array_raw->get_offsets_ptr());

    block.clear_column_data();
    const auto& rebuilt = block.get_by_position(0).column;
    ASSERT_NE(rebuilt.get(), nullptr);
    EXPECT_EQ(rebuilt->size(), 0);
    EXPECT_NO_THROW(rebuilt->sanity_check());
}

} // namespace doris
