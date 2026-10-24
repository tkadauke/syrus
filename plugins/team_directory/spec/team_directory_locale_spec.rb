require "rails_helper"
require "json"

RSpec.describe "Team Directory frontend locales", type: :unit do
  let(:root) { Rails.root.join("plugins/team_directory/app/frontend/i18n/locales") }
  def locale(name) = JSON.parse(File.read(root.join(name, "team_directory.json")))

  it "describes people rather than images in Latin" do
    expect(locale("la").dig("profiles", "load_error")).to eq("Personae onerari non potuerunt.")
  end
end
