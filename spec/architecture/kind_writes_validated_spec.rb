require "rails_helper"

# DOC-44 plugin host: a Job, Workflow, Step or Run gets a kind only through
# model validation, which requires it to be installed when it is set or
# changed. Existing rows keep theirs after the owning plugin goes away, so
# the only way an unknown kind enters the database is a write that skips
# validation (`update_all`, `update_column(s)`, `upsert(_all)`, `insert_all`),
# and none may set a kind column (formal/SyrusModel/PluginDisableRecovery.lean).
RSpec.describe "kind columns are written through validation" do
  def bulk_write
    /\b(?:update_all|update_columns?|upsert(?:_all)?|insert_all!?)\b/
  end

  def kind_key
    /(?<![\w.])(?:trigger_kind|kind)(?::|\s*=>|["']\s*=>)|[:"']\b(?:trigger_kind|kind)\b["']?\s*,/
  end

  it "never sets kind or trigger_kind around model validation in app code" do
    offenders = Dir[Rails.root.join("{app,lib,plugins}/**/*.rb")].reject { |path| path.include?("/spec/") }.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.match?(bulk_write) && line.match?(kind_key)

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, "set kinds through validated saves:\n#{offenders.join("\n")}"
  end

  it "recognises a validation-skipping kind write" do
    expect('step.update_columns(kind: "x")').to match(bulk_write).and match(kind_key)
    expect('Workflow.where(id: 1).update_all(trigger_kind: "x")').to match(bulk_write).and match(kind_key)
    expect("run.update_columns(state: 'failed')").not_to match(kind_key)
  end
end
