require "rails_helper"

RSpec.describe Filters::SmartFolderResolution do
  describe "the shared contract" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let!(:archived) { Factories.epic(user: user, repository: repository, state: "archived") }
    let!(:open_epic) { Factories.epic(user: user, repository: repository, state: "ready") }
    let(:subject) { "epic" }
    let(:filter_class) { Epics::Filter }
    let(:builtin_key) { "epics_archived" }
    let(:explicit_chip) { { "field" => "state", "op" => "is", "value" => "ready" } }
    let(:replacement_chip) { { "field" => "state", "op" => "is", "value" => "backlog" } }
    let(:legacy_param_name) { :state }
    let(:legacy_param_value) { "backlog" }
    let(:base_scope) { Epic.all }
    let(:expected_ids) { [ archived.id ] }

    include_examples "a SmartFolder-backed FilterBar"
  end

  it "represents Dashboard attention folders by stable built-in key" do
    user = Factories.user
    SmartFolder.ensure_builtins_for_subject!("job")
    folder = SmartFolder.find_builtin_by_attention("inbox")

    resolution = described_class.call(filter_class: Jobs::Filter, subject: :job, params: {}, active_smart_folder: folder, user: user)

    expect(resolution.filter.to_h).to eq(described_class.preset_tree("inbox"))
  end

  it "preserves persisted user-defined folder filters" do
    user = Factories.user
    tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] }
    folder = SmartFolder.create!(user: user, subject_type: "epic", kind: "user_defined", name: "Ready", filter: tree)
    resolution = described_class.call(filter_class: Epics::Filter, subject: :epic, params: {}, active_smart_folder: folder, user: user)
    expect(resolution.filter.to_h).to eq(tree)
  end
end
