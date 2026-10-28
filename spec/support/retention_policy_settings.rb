module RetentionPolicySettingHelpers
  def set_retention(key, value)
    RetentionPolicySetting.write!(RetentionPolicyRegistry.fetch(key), retention_value: value)
  end

  def set_retention_archive(key, value)
    RetentionPolicySetting.write!(RetentionPolicyRegistry.fetch(key), archive_before_delete: value)
  end
end

RSpec.configure do |config|
  config.include RetentionPolicySettingHelpers
end
