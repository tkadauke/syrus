require "rails_helper"

RSpec.describe Admin::PluginDisableGuard, :reset_plugin_registry do
  around do |ex|
    Syrus::PluginRegistry.reset!
    AdminPluginsSpec.register_factory_agent_providers!
    ex.run
    Syrus::PluginRegistry.reset!
  end

  def register(name, depends_on: [], provides: {})
    Syrus::PluginRegistry.register(name: name, version: "1.0.0", depends_on: depends_on, provides: provides)
  end

  def manifest_for(name)
    Syrus::PluginRegistry.all_plugins.find { |m| m.name == name }
  end

  describe ".blockers_for / .ensure_disableable!" do
    it "is unchanged for a plugin with no dependents and no usage" do
      register("solo_plugin")

      expect(described_class.blockers_for(manifest_for("solo_plugin"))).to eq([])
      expect { described_class.ensure_disableable!(manifest_for("solo_plugin")) }.not_to raise_error
    end

    it "still raises Blocked for usage blockers even when the plugin also has enabled dependents" do
      register("ruby", provides: { agent_provider: AdminPluginsSpec::AvailableProvider })
      register("rails", depends_on: [ "ruby" ])
      admin = Factories.user(admin: true)
      admin.update!(agent_provider: "available")

      expect { described_class.ensure_disableable!(manifest_for("ruby")) }
        .to raise_error(described_class::Blocked)
    end

    it "blocks disabling plugins with active WorkUnit-owned workflows" do
      register("ruby", provides: { agent_provider: AdminPluginsSpec::AvailableProvider })
      job = Factories.job_record(agent_provider: "codex")
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "manual",
        agent_provider: "available",
        state: "succeeded"
      )
      intent = WorkIntent.create!(
        kind: "manual",
        state: "requested",
        repository: job.repository,
        scope_type: "job",
        scope_id: job.id,
        actor: job.user,
        source_type: "spec"
      )
      unit = WorkUnit.create!(
        work_intent: intent,
        kind: "manual",
        state: "running",
        repository: job.repository,
        scope_type: "job",
        scope_id: job.id,
        workflow: workflow
      )
      unit.work_unit_members.create!(job: job, role: "primary")

      blockers = described_class.blockers_for(manifest_for("ruby"))

      expect(blockers).to include(have_attributes(kind: "active_workflows", count: 1))
      expect { described_class.ensure_disableable!(manifest_for("ruby")) }
        .to raise_error(described_class::Blocked, /Active workflows use Available/)
    end
  end

  describe "repository content providers" do
    def content_provider(label, serves:)
      Class.new do
        include Syrus::Plugin::RepositoryContentProvider

        define_singleton_method(:provider_key) { label.parameterize }
        define_singleton_method(:display_name) { label }
        define_singleton_method(:role) { :upstream }
        define_singleton_method(:available_for?) { |repository| serves.call(repository) }
      end
    end

    let!(:repository) { Factories.repository }

    it "blocks disabling the only provider that can read an active repository" do
      register("host", provides: { repository_content_provider: content_provider("Host", serves: ->(_) { true }) })

      expect { described_class.ensure_disableable!(manifest_for("host")) }
        .to raise_error(described_class::Blocked, /Repositories read their files only through Host/)
    end

    it "allows disabling it while another enabled provider serves the same repositories" do
      register("host", provides: { repository_content_provider: content_provider("Host", serves: ->(_) { true }) })
      register("mirror", provides: { repository_content_provider: content_provider("Mirror", serves: ->(_) { true }) })

      expect(described_class.blockers_for(manifest_for("host"))).to eq([])
    end

    # A mirror only serves a repository while an upstream hands it
    # credentials; it is not a replacement for the upstream it depends on.
    it "does not count a provider that only serves the repository with this plugin's help" do
      host = content_provider("Host", serves: ->(_) { true })
      register("host", provides: { repository_content_provider: host })
      mirror = content_provider("Mirror", serves: ->(_) { RepositoryContent.provider_classes.include?(host) })
      register("mirror", provides: { repository_content_provider: mirror })

      expect(described_class.blockers_for(manifest_for("host")).map(&:label)).to include(/only through Host/)
      expect(RepositoryContent.provider_classes).to include(host)
    end

    it "ignores repositories the provider never served" do
      register("host", provides: { repository_content_provider: content_provider("Host", serves: ->(_) { false }) })

      expect(described_class.blockers_for(manifest_for("host"))).to eq([])
    end
  end

  describe ".dependents_for" do
    it "returns an empty array when no plugin depends on this one" do
      register("solo_plugin")

      expect(described_class.dependents_for(manifest_for("solo_plugin"))).to eq([])
    end

    it "returns currently-enabled plugins that transitively depend on this one" do
      register("ruby")
      register("rails", depends_on: [ "ruby" ])

      expect(described_class.dependents_for(manifest_for("ruby"))).to contain_exactly("rails")
    end

    it "excludes dependents that are already disabled" do
      register("ruby")
      register("rails", depends_on: [ "ruby" ])
      PluginRecord.find_by!(name: "rails").update!(enabled: false)

      expect(described_class.dependents_for(manifest_for("ruby"))).to eq([])
    end

    it "includes transitive dependents several levels deep" do
      register("python")
      register("django", depends_on: [ "python" ])
      register("django_extras", depends_on: [ "django" ])

      expect(described_class.dependents_for(manifest_for("python"))).to contain_exactly("django", "django_extras")
    end
  end
end
