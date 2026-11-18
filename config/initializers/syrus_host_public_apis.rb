Rails.application.config.after_initialize do
  require "syrus/host/public_apis"
  require_dependency "syrus/host/domain_apis"
end
