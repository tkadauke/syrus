source "https://rubygems.org"

gem "syrus_rails", path: "plugins/rails"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"

# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 for development/test
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# State machines for Job and friends [https://github.com/aasm/aasm]
gem "aasm"

# GitHub API client [https://github.com/octokit/octokit.rb]
gem "octokit", "~> 10.0"

# Faraday middleware that does ETag/Cache-Control conditional requests.
# Wired into GithubClient so 304 Not Modified responses are returned
# from cache and don't count against the GH rate limit.
gem "faraday-http-cache"

# Octokit's default Faraday stack includes retry middleware. Keep this
# available in runtime bundles so sidecar processes do not boot with
# Octokit's Faraday v2 missing-middleware warning.
gem "faraday-retry"

# Model Context Protocol SDK — used for the per-run sidecar that lets
# the agent submit PR copy back to Syrus during its run.
gem "mcp"

# Best-effort text extraction for repository documents exposed to chat agents.
gem "docx"
gem "pdf-reader"

# Runtime XML parsing for Cobertura coverage reports. Ruby 3.4 no longer
# guarantees this default gem is available unless it is bundled explicitly.
gem "rexml"

# CommonMark / GitHub-style markdown renderer for chat messages.
# Used by repositories/chats/_message.html.erb to render user + assistant
# text content. unsafe rendering is off by default so raw HTML in chat
# is escaped.
gem "commonmarker"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# WebAuthn server-side ceremony verification for passkey support
gem "webauthn", "~> 3.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0"

# Bundled plugins. These are installed with Syrus but enabled/disabled through
# PluginRecord at runtime; adding/removing plugin gems still requires restart.
gem "claude_agent",  path: "plugins/claude_agent"
gem "codex_agent",   path: "plugins/codex_agent"
gem "github_source", path: "plugins/github_source"
gem "linear_source", path: "plugins/linear_source"
gem "syrus_dev",     path: "plugins/syrus_dev"
gem "tailscale",     path: "plugins/tailscale"
gem "discord",       path: "plugins/discord"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # RSpec for tests [https://github.com/rspec/rspec-rails]
  gem "rspec-rails", "~> 8.0"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :production do
  # MySQL adapter for production
  gem "mysql2", "~> 0.5"

  # S3-compatible object storage adapter for Active Storage. Production
  # uses an in-cluster MinIO (deployed by green_acres) as the storage
  # service for Job attachments — see config/storage.yml#minio.
  gem "aws-sdk-s3", require: false
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # Stub HTTP and replay GitHub responses [https://github.com/vcr/vcr, https://github.com/bblimke/webmock]
  gem "vcr"
  gem "webmock"

  # Code coverage reporting — produces LCOV output for coverage_analyze step
  gem "simplecov"
  gem "simplecov-lcov"

  gem "parallel_tests", "~> 5.7", require: false
end
