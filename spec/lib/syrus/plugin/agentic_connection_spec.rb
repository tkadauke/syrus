require "rails_helper"

RSpec.describe Syrus::Plugin::AgenticConnection do
  let(:host_class) do
    Class.new do
      extend Syrus::Plugin::AgenticConnection
    end.tap do |klass|
      # `class Foo; end` inside this block would define Foo in the spec's
      # lexical scope, not on klass - const_set is required to attach these
      # error classes to the anonymous host class itself.
      klass.const_set(:NotFoundError, Class.new(StandardError))
      klass.const_set(:AccessDisabledError, Class.new(StandardError))
      klass.const_set(:WriteAccessDisabledError, Class.new(StandardError))
    end
  end

  # A self-contained fake record/model pair standing in for a real agentic
  # connection model (MysqlConnection, KubernetesCluster, ...) so this spec
  # doesn't depend on any specific plugin's domain model existing.
  let(:record_class) do
    Struct.new(:id, :label, :agentic_access_enabled, :allow_writes) do
      def self.registry
        @registry ||= {}
      end

      def self.find_by(id:)
        registry[id]
      end

      def agentic_access_enabled? = agentic_access_enabled
      def allow_writes? = allow_writes
    end
  end

  def build_record(record_class, id: 1, label: "Test", agentic_access_enabled: false, allow_writes: false)
    record = record_class.new(id, label, agentic_access_enabled, allow_writes)
    record_class.registry[id] = record
    record
  end

  describe "#find_agentic!" do
    it "returns the record when agentic access is enabled" do
      record = build_record(record_class, agentic_access_enabled: true)

      result = host_class.find_agentic!(
        record_class, record.id,
        resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
        not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError
      )

      expect(result).to eq(record)
    end

    it "raises the given not_found_error for an unknown id, using resource_name in the message" do
      expect {
        host_class.find_agentic!(
          record_class, -1,
          resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
          not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError
        )
      }.to raise_error(host_class::NotFoundError, "MySQL connection -1 was not found.")
    end

    it "raises the given access_disabled_error when agentic access has not opted in, naming settings_location" do
      record = build_record(record_class, label: "Homelab", agentic_access_enabled: false)

      expect {
        host_class.find_agentic!(
          record_class, record.id,
          resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
          not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError
        )
      }.to raise_error(
        host_class::AccessDisabledError,
        "Agentic access is disabled for the \"Homelab\" connection. " \
          "An admin must enable it from DB Browser connection settings before agents can query it."
      )
    end
  end

  describe "#find_agentic_with_write_access!" do
    it "returns the record when both agentic access and writes are enabled" do
      record = build_record(record_class, agentic_access_enabled: true, allow_writes: true)

      result = host_class.find_agentic_with_write_access!(
        record_class, record.id,
        resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
        not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError,
        write_access_disabled_error: host_class::WriteAccessDisabledError
      )

      expect(result).to eq(record)
    end

    it "raises write_access_disabled_error when writes are off even though agentic access is on" do
      record = build_record(record_class, label: "Homelab", agentic_access_enabled: true, allow_writes: false)

      expect {
        host_class.find_agentic_with_write_access!(
          record_class, record.id,
          resource_name: "Kubernetes cluster", settings_location: "K8s Cluster connection settings",
          not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError,
          write_access_disabled_error: host_class::WriteAccessDisabledError
        )
      }.to raise_error(
        host_class::WriteAccessDisabledError,
        "Write access is disabled for the \"Homelab\" cluster. " \
          "An admin must enable \"Allow writes\" for this cluster from K8s Cluster connection settings " \
          "before agents can run mutating actions against it."
      )
    end

    it "raises access_disabled_error (not write_access_disabled_error) when agentic access itself is off" do
      record = build_record(record_class, agentic_access_enabled: false, allow_writes: true)

      expect {
        host_class.find_agentic_with_write_access!(
          record_class, record.id,
          resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
          not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError,
          write_access_disabled_error: host_class::WriteAccessDisabledError
        )
      }.to raise_error(host_class::AccessDisabledError, /Agentic access is disabled/)
    end

    it "raises not_found_error for an unknown id" do
      expect {
        host_class.find_agentic_with_write_access!(
          record_class, -1,
          resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
          not_found_error: host_class::NotFoundError, access_disabled_error: host_class::AccessDisabledError,
          write_access_disabled_error: host_class::WriteAccessDisabledError
        )
      }.to raise_error(host_class::NotFoundError)
    end
  end

  describe "#require_write_access!" do
    it "returns the record without re-checking agentic_access_enabled" do
      record = build_record(record_class, agentic_access_enabled: false, allow_writes: true)

      result = host_class.require_write_access!(
        record,
        resource_name: "MySQL connection", settings_location: "DB Browser connection settings",
        write_access_disabled_error: host_class::WriteAccessDisabledError
      )

      expect(result).to eq(record)
    end

    it "raises write_access_disabled_error when allow_writes is off" do
      record = build_record(record_class, label: "Homelab", allow_writes: false)

      expect {
        host_class.require_write_access!(
          record,
          resource_name: "Kubernetes cluster", settings_location: "K8s Cluster connection settings",
          write_access_disabled_error: host_class::WriteAccessDisabledError
        )
      }.to raise_error(
        host_class::WriteAccessDisabledError,
        "Write access is disabled for the \"Homelab\" cluster. " \
          "An admin must enable \"Allow writes\" for this cluster from K8s Cluster connection settings " \
          "before agents can run mutating actions against it."
      )
    end
  end
end
