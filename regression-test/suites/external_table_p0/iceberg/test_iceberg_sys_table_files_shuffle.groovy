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

// The $files GROUP BY that SIGSEGV'd a prod BE in ColumnNullable::sanity_check() on the local
// shuffle (Crc32HashPartitioner / ShuffleExchanger), 2026-11-13. It is a race, so the query runs
// many times with a forced local shuffle and must return the same rows every time.
suite("test_iceberg_sys_table_files_shuffle", "p0,external,doris,external_docker,external_docker_doris") {
    String enabled = context.config.otherConfigs.get("enableIcebergTest")
    if (enabled == null || !enabled.equalsIgnoreCase("true")) {
        logger.info("disable iceberg test.")
        return
    }

    String catalog_name = "test_iceberg_files_shuffle_ctl"
    String db_name = "test_iceberg_files_shuffle_db"
    String table_name = "files_shuffle_tbl"
    String rest_port = context.config.otherConfigs.get("iceberg_rest_uri_port")
    String minio_port = context.config.otherConfigs.get("iceberg_minio_port")
    String externalEnvIp = context.config.otherConfigs.get("externalEnvIp")
    sql """drop catalog if exists ${catalog_name}"""
    sql """
    CREATE CATALOG ${catalog_name} PROPERTIES (
        'type'='iceberg',
        'iceberg.catalog.type'='rest',
        'uri' = 'http://${externalEnvIp}:${rest_port}',
        "s3.access_key" = "admin",
        "s3.secret_key" = "password",
        "s3.endpoint" = "http://${externalEnvIp}:${minio_port}",
        "s3.region" = "us-east-1"
    );"""

    sql """switch ${catalog_name}"""
    sql """create database if not exists ${db_name}"""
    sql """use ${db_name}"""
    sql """drop table if exists ${table_name}"""
    sql """create table ${table_name} (id int, name string) properties ('format-version'='2')"""
    // One insert per data file, so $files has several rows to shuffle.
    int fileCount = 12
    for (int i = 0; i < fileCount; i++) {
        sql """insert into ${table_name} values (${i}, 'n${i}'), (${i + 100}, null)"""
    }

    sql """set parallel_pipeline_task_num = 8"""
    sql """set enable_local_shuffle = true"""
    sql """set force_to_local_shuffle = true"""
    sql """set ignore_storage_data_distribution = true"""

    // The Watchdog LatticeStorageIntegrityService query, verbatim apart from the table name.
    String watchdogSql = """
        SELECT content AS Content, substring_index(file_path, '://', 1) AS Scheme,
               count(*) AS FileCount, min(file_path) AS ExamplePath
        FROM ${table_name}\$files
        GROUP BY content, substring_index(file_path, '://', 1) ORDER BY content"""

    List<List<Object>> first = sql watchdogSql
    assertEquals(1, first.size())
    assertEquals(0, ((Number) first[0][0]).intValue())
    assertEquals("s3", first[0][1].toString())
    assertEquals(fileCount, ((Number) first[0][2]).intValue())
    for (int i = 0; i < 50; i++) {
        assertEquals(first, sql(watchdogSql))
    }

    sql """drop table if exists ${table_name}"""
    sql """drop database if exists ${db_name}"""
    sql """drop catalog if exists ${catalog_name}"""
}
