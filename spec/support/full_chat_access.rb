# Chat tools are gated by the canonical permission evaluator, so specs that
# exercise tool behavior (not the permission gate itself) opt in with
# `:full_chat_access` to start from the Full access profile for the chat owner.
module FullChatAccessHelper
  SELECTORS = %w[interactive_chat coding_chat local_chat].freeze

  def grant_full_chat_access(account)
    management = Permissions::Management.new(account)
    SELECTORS.each do |selector|
      plan = management.profile_plan(profile_key: "full_access@v1", subject_selector_type: selector)
      management.apply_profile!(plan:, actor: account)
    end
  end
end

RSpec.configure do |config|
  config.include FullChatAccessHelper

  config.before(:each, :full_chat_access) do
    # Specs that reserve the first-user admin slot must create it before the owner.
    _bootstrap_admin if respond_to?(:_bootstrap_admin)
    grant_full_chat_access(respond_to?(:user) ? user : chat_session.user)
  end
end
