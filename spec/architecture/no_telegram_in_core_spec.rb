require "rails_helper"

# Telegram is a bundled platform_delivery plugin (plugins/telegram). Core keeps
# only generic platform-delivery and polling plumbing and must not name it.
#
# The one allowed gap is the settings storage: like Discord's bot token, the
# Telegram handle/offset/token columns still live on AppSetting and in the
# core registry/admin settings UI. A follow-up moves the token onto connected
# accounts; these files are allowlisted until then.
RSpec.describe "Telegram stays out of core" do
  SETTINGS_ALLOWLIST = %w[
    app/models/app_setting.rb
    app/models/app_setting_registry.rb
  ].freeze

  def core_ruby_files
    %w[app lib config].flat_map { |dir| Dir[Rails.root.join(dir, "**/*.rb")] }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .reject { |path| SETTINGS_ALLOWLIST.include?(path) }
  end

  it "has no Telegram references in core Ruby code" do
    offenders = core_ruby_files.select { |path| File.read(Rails.root.join(path)).match?(/telegram/i) }

    expect(offenders).to be_empty, "Telegram belongs in plugins/telegram, found in: #{offenders.join(', ')}"
  end

  it "has no Telegram class constants anywhere outside the plugin" do
    constants = /TelegramClient|TelegramAdapter|PollTelegramUpdatesJob|PlatformConfig::Telegram/
    offenders = (%w[app lib config spec].flat_map { |dir| Dir[Rails.root.join(dir, "**/*.rb")] } - [ __FILE__ ])
      .select { |path| File.read(path).match?(constants) }

    expect(offenders).to be_empty
  end
end
