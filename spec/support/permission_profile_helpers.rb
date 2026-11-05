module PermissionProfileHelpers
  def grant_full_chat_access(user, subject: "interactive_chat")
    @full_access_users ||= {}
    key = [ user.id, subject ]
    return if @full_access_users[key]

    management = Permissions::Management.new(user)
    plan = management.profile_plan(profile_key: "full_access@v1", subject_selector_type: subject)
    management.apply_profile!(plan: plan, actor: user)
    @full_access_users[key] = true
  end
end

RSpec.configure { |config| config.include PermissionProfileHelpers }
