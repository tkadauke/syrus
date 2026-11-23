require "rails_helper"

# Telegram is a bundled plugin (plugins/telegram). Core Ruby code may keep
# only generic platform-delivery plumbing: no Telegram constants or classes.
#
# Known gap: Telegram's AppSetting columns, registry entries and Admin
# Settings UI remain in core, exactly as Discord's do today; those are
# settings/data ownership (and move with the follow-up connected-account
# work), so settings files are exempt here.
RSpec.describe "Telegram stays out of core" do
  EXEMPT_FILES = %w[
    app/models/app_setting.rb
    app/models/app_setting_registry.rb
  ].freeze

  it "has no Telegram classes or constants in core Ruby code" do
    files = Dir[Rails.root.join("app/**/*.rb"), Rails.root.join("lib/**/*.rb"), Rails.root.join("config/**/*.rb")]
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .reject { |path| EXEMPT_FILES.include?(path) }

    offenders = files.select { |path| File.read(Rails.root.join(path)).match?(/telegram/i) }

    expect(offenders).to eq([])
  end

  it "does not define the old core Telegram constants" do
    %w[TelegramClient PollTelegramUpdatesJob PlatformDelivery::TelegramAdapter PlatformIdentity::PlatformConfig::Telegram].each do |name|
      expect { name.constantize }.to raise_error(NameError)
    end
  end
end
