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
