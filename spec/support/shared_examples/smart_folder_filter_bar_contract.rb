RSpec.shared_examples "a SmartFolder-backed FilterBar" do
  let(:preset_field) { Filters::SmartFolderResolution::PRESET_FIELD }
  let(:folder) do
    SmartFolder.ensure_builtins_for_subject!(subject)
    SmartFolder.builtins(subject).find { |candidate| candidate.builtin_key == builtin_key }
  end

  def resolve(params)
    Filters::SmartFolderResolution.call(filter_class: filter_class, subject: subject, params: params,
      active_smart_folder: folder, user: user)
  end

  it "seeds the editable filter with the named built-in preset" do
    resolution = resolve({})
    expect(resolution.filter.to_h).to eq("and" => [ { "field" => preset_field, "op" => "is", "value" => builtin_key } ])
    expect(resolution.navigation).to eq(active_smart_folder_id: folder.id)
  end

  it "treats an explicit q as the complete filter without duplicating the preset" do
    tree = { "and" => [ explicit_chip ] }
    expect(resolve(q: Filters::QueryParam.encode(tree), legacy_param_name => legacy_param_value).filter.to_h).to eq(tree)
    expect(resolve("q" => Filters::QueryParam.encode(tree), legacy_param_name.to_s => legacy_param_value).filter.to_h).to eq(tree)
  end

  it "replaces the old preset when an edited q is submitted" do
    tree = { "and" => [ replacement_chip ] }
    expect(resolve(q: Filters::QueryParam.encode(tree)).filter.to_h).to eq(tree)
  end

  it "does not resurrect the folder after explicit empty removal" do
    empty = { "and" => [] }
    expect(resolve(q: Filters::QueryParam.encode(empty)).filter.to_h).to eq(empty)
  end

  it "applies exactly the filter returned to the FilterBar" do
    resolution = resolve({})
    expect(resolution.filter.apply(base_scope).pluck(:id)).to match_array(expected_ids)
    expect(filter_class.from_tree(resolution.filter.to_h, user: user).apply(base_scope).pluck(:id)).to match_array(expected_ids)
  end
end

# Every request surface backed by a registered SmartFolder subject. The model
# inventory spec checks both registration coverage and that each listed spec
# actually includes the endpoint contract below.
SMART_FOLDER_FILTER_BAR_CONTRACT_INVENTORY = {
  "agent_session" => {
    operator: "plugins/agent_activity/spec/requests/api/v1/app/agent_activity_spec.rb",
    admin: "plugins/agent_activity/spec/requests/api/v1/app/admin/agent_activity_spec.rb"
  },
  "design_doc" => {
    index: "plugins/design_docs/spec/requests/api/v1/app/design_docs_spec.rb"
  },
  "agent_insight" => {
    repository: "plugins/agent_insights/spec/requests/api/v1/app/insight_suggestions_spec.rb",
    admin: "plugins/agent_insights/spec/requests/api/v1/app/admin/insights_spec.rb"
  },
  "worker_timeline" => {
    macro: "plugins/worker_timeline/spec/requests/api/v1/app/admin/worker_timeline_spec.rb"
  }
}.freeze

RSpec.shared_examples "a SmartFolder-backed FilterBar endpoint" do |contract_surface:|
  it "returns and applies the selected folder's effective filter" do
    smart_folder_contract_request.call(smart_folder_id: smart_folder_contract_folder.id)

    expect(response).to have_http_status(:ok)
    expect(smart_folder_contract_body.fetch("active_smart_folder_id")).to eq(smart_folder_contract_folder.id)
    expect(smart_folder_contract_body.fetch("filter")).to eq(smart_folder_contract_seed_filter)
    expect(smart_folder_contract_result_ids).to match_array(smart_folder_contract_seed_ids)
  end

  it "uses an explicit q as the sole returned and applied filter" do
    q = Filters::QueryParam.encode(smart_folder_contract_replacement_filter)
    smart_folder_contract_request.call(smart_folder_id: smart_folder_contract_folder.id, q: q)

    expect(response).to have_http_status(:ok)
    expect(smart_folder_contract_body.fetch("active_smart_folder_id")).to eq(smart_folder_contract_folder.id)
    expect(smart_folder_contract_body.fetch("filter")).to eq(smart_folder_contract_replacement_filter)
    expect(smart_folder_contract_result_ids).to match_array(smart_folder_contract_replacement_ids)
  end

  it "keeps navigation current without resurrecting a folder after explicit-empty q" do
    q = Filters::QueryParam.encode("and" => [])
    smart_folder_contract_request.call(smart_folder_id: smart_folder_contract_folder.id, q: q)

    expect(response).to have_http_status(:ok)
    expect(smart_folder_contract_body.fetch("active_smart_folder_id")).to eq(smart_folder_contract_folder.id)
    expect(smart_folder_contract_body.fetch("filter")).to eq("and" => [])
    expect(smart_folder_contract_result_ids).to match_array(smart_folder_contract_unfiltered_ids)
  end

  it "is declared in the registration-to-test inventory" do
    surfaces = SMART_FOLDER_FILTER_BAR_CONTRACT_INVENTORY.fetch(smart_folder_contract_subject)
    expect(surfaces).to have_key(contract_surface)
  end
end
