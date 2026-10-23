package dev.syrus.android.data

import android.content.Context
import dev.syrus.android.R

interface UserMessages {
    fun bootstrapMissingUser(): String
    fun tokenUserMissing(): String
    fun untitledJob(): String
    fun unknownState(): String
    fun apiHttpError(statusCode: Int): String
    fun instanceUrlRequired(): String
    fun apiTokenRequired(): String
}

class AndroidUserMessages(context: Context) : UserMessages {
    private val resources = context.applicationContext.resources

    override fun bootstrapMissingUser() = resources.getString(R.string.bootstrap_missing_user)
    override fun tokenUserMissing() = resources.getString(R.string.token_user_missing)
    override fun untitledJob() = resources.getString(R.string.untitled_job)
    override fun unknownState() = resources.getString(R.string.unknown_state)
    override fun apiHttpError(statusCode: Int) = resources.getString(R.string.api_http_error, statusCode)
    override fun instanceUrlRequired() = resources.getString(R.string.instance_url_required)
    override fun apiTokenRequired() = resources.getString(R.string.api_token_required)
}
