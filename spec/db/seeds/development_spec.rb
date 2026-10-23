require "rails_helper"

RSpec.describe "development seeds" do
  before do
    allow(Rails.env).to receive(:development?).and_return(true)
  end

  it "makes preview chat available and enables the Tool Card Catalog" do
    Rails.application.load_seed

    demo_user = User.find_by!(email_address: "demo@syrus.local")
    teammate_user = User.find_by!(email_address: "ada@syrus.local")

    expect(demo_user).to be_chat_available
    expect(teammate_user).to be_chat_available
    expect(demo_user).to have_attributes(
      codex_auth_mode: "api_key",
      codex_api_key: "sk-preview-placeholder"
    )
    expect(teammate_user).to have_attributes(
      codex_auth_mode: "api_key",
      codex_api_key: "sk-preview-placeholder"
    )
    expect(AppSetting.current).to be_beta_mode_enabled
    expect(PluginRecord.find_by!(name: "syrus_dev")).to be_enabled
    expect(Syrus::PluginRegistry.providers_for(:admin_page)).to include(SyrusDev::AdminPages)
    expect(SyrusDev::AdminPages.admin_pages).to include(hash_including(path: "/admin/tool_cards"))
  end
end
