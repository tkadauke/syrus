require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.secret_key_base = "eval_secret_key_base_for_local_dev_image_only"

  config.enable_reloading = false
  config.eager_load = true

  config.consider_all_requests_local = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  config.cache_store = :memory_store
  config.active_storage.service = :local
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.default_url_options = { host: "localhost" }

  config.active_support.deprecation = :stderr
  config.active_record.dump_schema_after_migration = false

  # `bin/syrus dev` drives RunJob synchronously and skips callback enqueues while
  # walking the local workflow, so the eval image does not need Solid Queue.
  config.active_job.queue_adapter = :async

  # Fixed eval-only keys let the public local-dev image create encrypted User
  # rows without requiring the deploy-only Rails master key.
  config.active_record.encryption.primary_key = "eval_primary_key_at_least_32_bytes_xx"
  config.active_record.encryption.deterministic_key = "eval_deterministic_key_32_bytes_x"
  config.active_record.encryption.key_derivation_salt = "eval_key_derivation_salt_min_32_b"
end
