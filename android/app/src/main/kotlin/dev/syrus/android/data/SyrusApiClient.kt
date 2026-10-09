package dev.syrus.android.data

import dev.syrus.android.model.BootstrapProfile
import dev.syrus.android.model.JobSummary
import dev.syrus.android.model.SyrusHomeState
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

class SyrusApiClient(
    private val instanceUrl: String,
    private val apiToken: String,
) {
    fun loadHomeState(limit: Int = 20): SyrusHomeState {
        val profile = loadBootstrap()
        val jobs = loadJobs(limit)
        return SyrusHomeState(profile, jobs)
    }

    fun loadBootstrap(): BootstrapProfile {
        val payload = getJson("/api/v1/app/bootstrap")
        val whoami = payload.optJSONObject("whoami")
            ?: throw IOException("Bootstrap response did not include whoami.")
        val email = whoami.optString("email").takeIf { it.isNotBlank() }
            ?: throw IOException("API token did not resolve to a signed-in Syrus user.")
        return BootstrapProfile(email, whoami.optString("token_suffix"))
    }

    fun loadJobs(limit: Int = 20): List<JobSummary> {
        val safeLimit = limit.coerceIn(1, 100)
        val payload = getJson("/api/v1/app/jobs?limit=$safeLimit&state=all&include_active_work=true")
        val jobs = payload.optJSONArray("jobs") ?: return emptyList()
        return buildList {
            for (index in 0 until jobs.length()) {
                val job = jobs.optJSONObject(index) ?: continue
                add(
                    JobSummary(
                        job.optLong("id"),
                        job.optString("title", "Untitled job"),
                        job.optString("state", "unknown"),
                        job.optString("summary_state", job.optString("state", "unknown")),
                        job.optString("current_step", ""),
                        repositorySlug(job),
                    ),
                )
            }
        }
    }

    private fun repositorySlug(job: JSONObject): String {
        val repository = job.optJSONObject("repository")
        val slug = repository?.optString("slug").orEmpty()
        if (slug.isNotBlank()) return slug

        return job.optString("repository_slug", "")
    }

    private fun getJson(pathAndQuery: String): JSONObject {
        val connection = openConnection(pathAndQuery)
        try {
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (code !in 200..299) {
                val message = errorMessage(body).ifBlank { "Syrus API request failed with HTTP $code." }
                throw IOException(message)
            }
            return JSONObject(body)
        } finally {
            connection.disconnect()
        }
    }

    private fun openConnection(pathAndQuery: String): HttpURLConnection {
        val base = instanceUrl.trim().trimEnd('/')
        require(base.isNotBlank()) { "Syrus instance URL is required." }
        require(apiToken.isNotBlank()) { "Syrus API token is required." }

        return (URL("$base$pathAndQuery").openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            requestMethod = "GET"
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Authorization", "Bearer ${apiToken.trim()}")
        }
    }

    private fun errorMessage(body: String): String {
        return runCatching {
            JSONObject(body).optJSONObject("error")?.optString("message").orEmpty()
        }.getOrDefault("")
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
        const val READ_TIMEOUT_MS = 10_000
    }
}
