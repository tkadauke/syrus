package dev.syrus.android.data

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class SyrusApiClientTest {
    private lateinit var server: TestHttpServer
    private val requests = mutableListOf<RequestRecord>()

    @Before
    fun startServer() {
        server = TestHttpServer { request ->
            requests += request
            route(request)
        }
        server.start()
    }

    @After
    fun stopServer() {
        server.close()
    }

    @Test
    fun loadHomeStateUsesExistingAppApiContract() {
        val state = SyrusApiClient(serverUrl(), "syrus_token").loadHomeState(limit = 10)

        assertEquals("operator@example.test", state.profile.email)
        assertEquals("oken", state.profile.tokenSuffix)
        assertEquals(1, state.jobs.size)
        assertEquals(42, state.jobs.first().id)
        assertEquals("running", state.jobs.first().state)
        assertEquals("tkadauke/syrus", state.jobs.first().repositorySlug)
        assertEquals(
            listOf("/api/v1/app/bootstrap", "/api/v1/app/jobs"),
            requests.map { it.path },
        )
        assertTrue(requests.all { it.authorization == "Bearer syrus_token" })
        assertEquals("limit=10", requests.last().query)
    }

    @Test
    fun loadBootstrapSurfacesApiErrorMessage() {
        server.handler = { request ->
            requests += request
            TestResponse(401, """{"error":{"message":"Provide a valid API token."}}""")
        }

        val result = runCatching { SyrusApiClient(serverUrl(), "bad").loadBootstrap() }

        assertTrue(result.isFailure)
        assertEquals("Provide a valid API token.", result.exceptionOrNull()?.message)
    }

    private fun route(request: RequestRecord): TestResponse {
        return when (request.path) {
            "/api/v1/app/bootstrap" -> TestResponse(
                200,
                """{"whoami":{"email":"operator@example.test","token_suffix":"oken"}}""",
            )
            "/api/v1/app/jobs" -> TestResponse(
                200,
                """{"count":1,"jobs":[{"id":42,"title":"Ship Android MVP","state":"running","repository":{"slug":"tkadauke/syrus"}}]}""",
            )
            else -> TestResponse(404, """{"error":{"message":"not found"}}""")
        }
    }

    private fun serverUrl(): String {
        return "http://127.0.0.1:${server.port}"
    }

    private data class RequestRecord(
        val path: String,
        val query: String,
        val authorization: String,
    )

    private data class TestResponse(
        val status: Int,
        val body: String,
    )

    private class TestHttpServer(
        @Volatile var handler: (RequestRecord) -> TestResponse,
    ) : AutoCloseable {
        private val socket = ServerSocket(0)
        private val running = AtomicBoolean(false)
        private val executor = Executors.newSingleThreadExecutor()

        val port: Int = socket.localPort

        fun start() {
            running.set(true)
            executor.execute {
                while (running.get()) {
                    runCatching { socket.accept().use(::handleSocket) }
                }
            }
        }

        override fun close() {
            running.set(false)
            socket.close()
            executor.shutdownNow()
        }

        private fun handleSocket(client: Socket) {
            val reader = BufferedReader(InputStreamReader(client.getInputStream()))
            val requestLine = reader.readLine() ?: return
            val target = requestLine.split(" ").getOrNull(1).orEmpty()
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isBlank()) break
                val separator = line.indexOf(':')
                if (separator > 0) {
                    headers[line.substring(0, separator).lowercase()] = line.substring(separator + 1).trim()
                }
            }

            val path = target.substringBefore('?')
            val query = target.substringAfter('?', "")
            val response = handler(RequestRecord(path, query, headers["authorization"].orEmpty()))
            val body = response.body.toByteArray()
            client.getOutputStream().use { output ->
                output.write("HTTP/1.1 ${response.status} OK\r\n".toByteArray())
                output.write("Content-Type: application/json\r\n".toByteArray())
                output.write("Content-Length: ${body.size}\r\n".toByteArray())
                output.write("Connection: close\r\n\r\n".toByteArray())
                output.write(body)
            }
        }
    }
}
