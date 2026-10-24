require "rails_helper"
require "tempfile"
require "yaml"
require Rails.root.join("spec/support/ruby_i18n_debt_audit")

RSpec.describe "Ruby source localization debt", type: :unit do
  let(:audit) { RubyI18nDebtAudit.new }
  let(:manifest) { YAML.load_file(Rails.root.join("config/i18n_ruby_debt.yml")).fetch("maximums") }

  it "does not let untranslated server-side copy grow" do
    actual = audit.counts
    growth = actual.filter_map do |category, count|
      maximum = manifest.fetch(category)
      "#{category}: #{count} (reviewed maximum #{maximum})" if count > maximum
    end

    expect(growth).to be_empty, <<~MESSAGE
      Ruby localization debt grew. Translate the new copy with I18n.t; do not
      increase config/i18n_ruby_debt.yml. New totals:
      #{growth.join("\n")}
    MESSAGE
  end

  it "keeps every audited category in the reviewed manifest" do
    expect(manifest.keys.sort).to eq(RubyI18nDebtAudit::CATEGORIES.map(&:to_s).sort)
  end

  it "detects the user-visible Ruby call shapes without counting internal channels" do
    allow(audit).to receive(:serializer_surface?).and_return(true)

    Tempfile.create([ "ruby-i18n-audit", ".rb" ], Rails.root.join("tmp")) do |file|
      file.write(<<~RUBY)
        render_error(
          "invalid",
          "Choose a Job",
          status: :unprocessable_content
        )
        render json: {
          message: "Saved"
        }
        flash.now[
          :alert
        ] = "Try again"
        record.errors.add(
          :name,
          "is unavailable"
        )
        serializer = {
          label: "Owner"
        }
        Rails.logger.info(message: "worker started")
        raise "internal invariant failed"
      RUBY
      file.flush

      findings = audit.findings_for(file.path)
      expect(findings.map(&:category)).to contain_exactly(
        :render_error,
        :response_field,
        :response_field,
        :model_error,
        :serializer_label
      )
    end
  end
end
