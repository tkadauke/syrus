require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.
  env_boolean = ->(key, default) { ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default)) }
  app_host = ENV.fetch("SYRUS_APP_HOST")
  default_allowed_hosts = app_host
  allowed_hosts = ENV.fetch("SYRUS_ALLOWED_HOSTS", default_allowed_hosts)
    .split(",")
    .map(&:strip)
    .reject(&:blank?)

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Store uploaded files via an S3-compatible API.
  # See config/storage.yml#minio. Env vars (S3_ENDPOINT, S3_BUCKET,
  # S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY) must be configured for
  # both web and worker processes.
  config.active_storage.service = :minio

  # Production traffic is terminated by the cluster ingress before reaching Rails.
  # Keep generated URLs, redirects, HSTS, and secure cookies aligned with that
  # proxy boundary unless an alternate deploy explicitly opts out.
  config.assume_ssl = env_boolean.call("SYRUS_ASSUME_SSL", "true")
  config.force_ssl = env_boolean.call("SYRUS_FORCE_SSL", "true")
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Enable DNS rebinding protection and other `Host` header attacks. Add extra
  # ingress names with SYRUS_ALLOWED_HOSTS as a comma-separated list.
  config.hosts.concat(allowed_hosts)
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # Log to STDOUT with the current request id as a default log tag.
  # MCP sidecars use stdout as the JSON-RPC protocol stream, so any
  # Rails-side logging in those processes must go to stderr instead.
  config.log_tags = [ :request_id ]
  sidecar_process = ENV["SYRUS_MCP_SIDECAR"].present? || ENV["SYRUS_CHAT_MCP_SIDECAR"].present?
  log_device = sidecar_process ? STDERR : STDOUT
  config.logger = ActiveSupport::TaggedLogging.logger(log_device)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  smtp_configured = ENV["SMTP_ADDRESS"].present?
  config.action_mailer.raise_delivery_errors = env_boolean.call(
    "SYRUS_MAILER_RAISE_DELIVERY_ERRORS",
    smtp_configured.to_s
  )
  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }

  if smtp_configured
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: ENV.fetch("SMTP_ADDRESS"),
      port: ENV.fetch("SMTP_PORT", 587).to_i,
      user_name: ENV["SMTP_USERNAME"],
      password: ENV["SMTP_PASSWORD"],
      authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym,
      enable_starttls_auto: env_boolean.call("SMTP_ENABLE_STARTTLS_AUTO", "true")
    }.compact
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]
end
