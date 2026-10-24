require "rails_helper"
require "json"

RSpec.describe "GitHub Source frontend locales", type: :unit do
  let(:root) { Rails.root.join("plugins/github_source/app/frontend/i18n/locales") }
  def locale(name) = JSON.parse(File.read(root.join(name, "github_source.json")))

  it "uses directional German copy and translates user-facing GitHub issue labels" do
    expect(locale("de").fetch("tab_issues")).to eq("GitHub-Vorgänge")
    expect(locale("de").dig("repository", "column_down")).to eq("Nach unten")
  end

  it "does not leak English Inbox labels into Latin" do
    expect(locale("la").dig("repository", "folder_inbox")).to eq("Receptaculum")
    expect(locale("la").dig("repository", "empty_delegated_action")).to eq("Receptaculum videre")
  end
end
