package dev.syrus.android.ui

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import dev.syrus.android.data.SyrusApiClient
import dev.syrus.android.model.SyrusHomeState
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()

    private lateinit var instanceUrlInput: EditText
    private lateinit var apiTokenInput: EditText
    private lateinit var statusText: TextView
    private lateinit var progress: ProgressBar
    private lateinit var jobList: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildContentView()
        restoreCredentials()
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun buildContentView() {
        val density = resources.displayMetrics.density
        val spacing = (16 * density).toInt()

        instanceUrlInput = EditText(this).apply {
            hint = "Syrus instance URL"
            setSingleLine(true)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        apiTokenInput = EditText(this).apply {
            hint = "API token"
            setSingleLine(true)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_DONE
        }
        statusText = TextView(this).apply {
            text = "Connect to load your Syrus Jobs."
            textSize = 16f
        }
        progress = ProgressBar(this).apply {
            visibility = View.GONE
        }
        jobList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

        val connectButton = Button(this).apply {
            text = "Connect"
            setOnClickListener { connect() }
        }

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(spacing, spacing, spacing, spacing)
            addView(titleView())
            addView(instanceUrlInput)
            addView(apiTokenInput)
            addView(connectButton)
            addView(progress)
            addView(statusText)
            addView(jobList)
        }

        setContentView(ScrollView(this).apply { addView(content) })
    }

    private fun titleView(): TextView {
        return TextView(this).apply {
            text = "Syrus"
            textSize = 28f
            setTextColor(0xFF2E2A27.toInt())
        }
    }

    private fun restoreCredentials() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        instanceUrlInput.setText(prefs.getString(KEY_INSTANCE_URL, ""))
        apiTokenInput.setText(prefs.getString(KEY_API_TOKEN, ""))
    }

    private fun connect() {
        val instanceUrl = instanceUrlInput.text.toString().trim()
        val apiToken = apiTokenInput.text.toString().trim()
        if (instanceUrl.isBlank() || apiToken.isBlank()) {
            statusText.text = "Instance URL and API token are required."
            return
        }

        progress.visibility = View.VISIBLE
        statusText.text = "Loading Syrus..."
        jobList.removeAllViews()

        executor.execute {
            runCatching {
                SyrusApiClient(instanceUrl, apiToken).loadHomeState()
            }.onSuccess { state ->
                saveCredentials(instanceUrl, apiToken)
                runOnUiThread { renderHomeState(state) }
            }.onFailure { error ->
                runOnUiThread {
                    progress.visibility = View.GONE
                    statusText.text = error.message ?: "Could not connect to Syrus."
                }
            }
        }
    }

    private fun saveCredentials(instanceUrl: String, apiToken: String) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_INSTANCE_URL, instanceUrl)
            .putString(KEY_API_TOKEN, apiToken)
            .apply()
    }

    private fun renderHomeState(state: SyrusHomeState) {
        progress.visibility = View.GONE
        statusText.text = "Signed in as ${state.profile.email}"
        jobList.removeAllViews()

        if (state.jobs.isEmpty()) {
            jobList.addView(TextView(this).apply { text = "No Jobs visible for this token yet." })
            return
        }

        state.jobs.forEach { job ->
            jobList.addView(
                TextView(this).apply {
                    val progressLine = job.currentStep.takeIf { it.isNotBlank() } ?: job.state
                    text = "#${job.id}  ${job.summaryState}\n${job.title}\n${job.repositorySlug}\n$progressLine"
                    textSize = 15f
                    setPadding(0, 18, 0, 18)
                },
            )
        }
    }

    private companion object {
        const val PREFS_NAME = "syrus_android"
        const val KEY_INSTANCE_URL = "instance_url"
        const val KEY_API_TOKEN = "api_token"
    }
}
