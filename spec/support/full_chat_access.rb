# Chat tools are gated by the canonical permission evaluator, so specs that
# exercise tool behavior (not the permission gate itself) opt in with
# `:full_chat_access` to start from the Full access profile for the chat owner.
module FullChatAccessHelper
  DEFAULT_SELECTORS = %w[interactive_chat].freeze
  ALL_SELECTORS = %w[interactive_chat coding_chat local_chat].freeze

  # Each selector writes a rule per descriptor, so grant only what a spec
  # needs; coding and local chats opt in with `full_chat_access: :all`.
  def grant_full_chat_access(account, selectors = DEFAULT_SELECTORS)
    management = Permissions::Management.new(account)
    selectors.each do |selector|
      next if PermissionRule.active.where(owner_user: account, subject_selector_type: selector).exists?

      plan = management.profile_plan(profile_key: "full_access@v1", subject_selector_type: selector)
      management.apply_profile!(plan:, actor: account)
    end
  end
end

RSpec.configure do |config|
  config.include FullChatAccessHelper

  # Specs also act as other users (repository members, admins); every chat
  # session created while the grant is active gets its owner the same profile.
  ChatSession.after_create do |session|
    selectors = Thread.current[:full_chat_access_selectors]
    next unless selectors && session.user

    Object.new.extend(FullChatAccessHelper).grant_full_chat_access(session.user, selectors)
  end

  config.after(:each, :full_chat_access) { Thread.current[:full_chat_access_selectors] = nil }

  config.before(:each, :full_chat_access) do |example|
    # Specs that reserve the first-user admin slot must create it before the owner.
    _bootstrap_admin if respond_to?(:_bootstrap_admin)
    selectors = example.metadata[:full_chat_access] == :all ? FullChatAccessHelper::ALL_SELECTORS : FullChatAccessHelper::DEFAULT_SELECTORS
    Thread.current[:full_chat_access_selectors] = selectors
    grant_full_chat_access(respond_to?(:user) ? user : chat_session.user, selectors)
  end
end
