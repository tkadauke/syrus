# Load all PendingActions command classes so their `inherited` hooks
# fire and populate PendingActions::REGISTRY. In production, eager_load
# handles this automatically; this initializer covers development/test
# where eager_load is disabled.
#
# Every file in app/services/pending_actions/ is loaded rather than a
# hand-kept list: a list missed archive_epic, approve_job, unapprove_job,
# and run_visual_review, so confirming one of those found no handler
# outside production. Plugin-owned handlers load through their plugin.
Rails.application.config.to_prepare do
  directory = Rails.root.join("app/services/pending_actions")
  paths = Dir[directory.join("*.rb")].map { |path| "pending_actions/#{File.basename(path, ".rb")}" }.sort
  ([ "pending_actions/base" ] | paths).each { |path| require_dependency path }
end
