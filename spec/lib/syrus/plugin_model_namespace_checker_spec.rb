require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginModelNamespaceChecker do
  FakePluginModel = Struct.new(:name, :table_name, :superclass, keyword_init: true) do
    def abstract_class?
      false
    end
  end

  FakePluginSuperclass = Struct.new(:table_name, keyword_init: true)

  def checker_for(model_classes:, root: Rails.root)
    described_class.new(root: root, model_classes: model_classes)
  end

  it "accepts plugin-owned models whose tables start with the namespace prefix" do
    model = FakePluginModel.new(
      name: "Linear::Ticket",
      table_name: "linear_tickets",
      superclass: FakePluginSuperclass.new(table_name: "application_records")
    )

    expect(checker_for(model_classes: [ model ]).call).to be_success
  end

  it "accepts plural plugin namespaces with a root table and singular child table prefix" do
    root_model = FakePluginModel.new(
      name: "DesignDocs::DesignDoc",
      table_name: "design_docs",
      superclass: FakePluginSuperclass.new(table_name: "application_records")
    )
    child_model = FakePluginModel.new(
      name: "DesignDocs::DesignDocVersion",
      table_name: "design_doc_versions",
      superclass: FakePluginSuperclass.new(table_name: "application_records")
    )

    expect(checker_for(model_classes: [ root_model, child_model ]).call).to be_success
  end

  it "rejects plugin-owned models with unprefixed tables" do
    model = FakePluginModel.new(
      name: "Linear::Ticket",
      table_name: "tickets",
      superclass: FakePluginSuperclass.new(table_name: "application_records")
    )

    result = checker_for(model_classes: [ model ]).call

    expect(result.errors).to include(/Linear::Ticket uses table "tickets"/)
  end

  it "rejects unnamespaced plugin models" do
    model = FakePluginModel.new(
      name: "Ticket",
      table_name: "tickets",
      superclass: FakePluginSuperclass.new(table_name: "application_records")
    )

    result = checker_for(model_classes: [ model ]).call

    expect(result.errors).to include(/Ticket must be namespaced/)
  end

  it "allows plugin STI subclasses to share their superclass table" do
    model = FakePluginModel.new(
      name: "InputSources::Linear",
      table_name: "input_sources",
      superclass: FakePluginSuperclass.new(table_name: "input_sources")
    )

    expect(checker_for(model_classes: [ model ]).call).to be_success
  end

  it "rejects plugin migrations that create unprefixed tables" do
    Dir.mktmpdir("syrus-plugin-checker") do |dir|
      root = Pathname.new(dir)
      plugin = root.join("plugins/linear")
      plugin.join("db/migrate").mkpath
      plugin.join("linear.gemspec").write("Gem::Specification.new do |spec|\n  spec.name = \"linear\"\nend\n")
      plugin.join("db/migrate/20260822000000_create_tickets.rb").write(<<~RUBY)
        class CreateTickets < ActiveRecord::Migration[8.1]
          def change
            create_table :tickets do |t|
              t.timestamps
            end
          end
        end
      RUBY

      result = checker_for(model_classes: [], root: root).call

      expect(result.errors).to include(/creates table "tickets"/)
    end
  end
end
