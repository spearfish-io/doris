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

package org.apache.doris.qe;

import org.apache.doris.nereids.StatementContext;
import org.apache.doris.thrift.TMasterOpRequest;
import org.apache.doris.thrift.TMasterOpResult;
import org.apache.doris.utframe.TestWithFeService;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.mockito.MockedConstruction;
import org.mockito.Mockito;

import java.io.Closeable;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The master side of a forwarded statement must close its StatementContext, like executeQuery does for a direct
 * connection, so statement-scoped resources (e.g. the Iceberg table lease) are released instead of leaking until
 * StatementContext.finalize() logs "Resources leak".
 */
public class ConnectProcessorProxyExecuteTest extends TestWithFeService {
    @AfterEach
    public void tearDown() {
        // proxyExecute installs the master context as the thread's ConnectContext; restore the fixture's.
        connectContext.setThreadLocalInfo();
    }

    @Test
    public void testForwardedStatementReleasesStatementResources() throws Exception {
        AtomicInteger closes = new AtomicInteger();
        ConnectContext master = new ConnectContext(null, true);

        TMasterOpResult result = proxyExecute(master, closes, false);

        Assertions.assertEquals(0, result.getStatusCode(), result.getErrMessage());
        Assertions.assertEquals(1, closes.get());
        // close() is idempotent: closing again (e.g. a query-finish path) must not release twice.
        master.getStatementContext().close();
        Assertions.assertEquals(1, closes.get());
    }

    @Test
    public void testFailedForwardedStatementReleasesStatementResources() throws Exception {
        AtomicInteger closes = new AtomicInteger();
        ConnectContext master = new ConnectContext(null, true);

        TMasterOpResult result = proxyExecute(master, closes, true);

        Assertions.assertNotEquals(0, result.getStatusCode());
        Assertions.assertEquals(1, closes.get());
    }

    private TMasterOpResult proxyExecute(ConnectContext master, AtomicInteger closes, boolean fail)
            throws Exception {
        TMasterOpRequest request = new TMasterOpRequest();
        request.setUser("root");
        request.setDb("");
        request.setSql("INSERT INTO iceberg.db.t VALUES (1)");
        try (MockedConstruction<StmtExecutor> executors = Mockito.mockConstruction(StmtExecutor.class,
                        (executor, construction) -> Mockito.doAnswer(invocation -> {
                            // What planning an Iceberg write does: borrow a statement-scoped lease.
                            StatementContext statementContext = new StatementContext();
                            master.setStatementContext(statementContext);
                            statementContext.getOrRegisterStatementResource("icebergTableLease",
                                    () -> (Closeable) closes::incrementAndGet);
                            if (fail) {
                                throw new IllegalStateException("execution failed");
                            }
                            master.getState().setOk();
                            return null;
                        }).when(executor).queryRetry(Mockito.any()))) {
            return new MysqlConnectProcessor(master).proxyExecute(request);
        }
    }
}
