# frozen_string_literal: true

module K8sCluster
  module Cli
    class Base < Syrus::Host::CliCommandHandler
      private

      def authorize!(user)
        raise Pundit::NotAuthorizedError unless user&.admin?
      end

      def cluster_for(value)
        return Syrus::Host::KubernetesCluster.find(value) if value.present?

        clusters = Syrus::Host::KubernetesCluster.order(:label).to_a
        raise ArgumentError, "no Kubernetes clusters are registered" if clusters.empty?
        raise ArgumentError, "multiple clusters are registered; pass --cluster ID (see `syrus k8s clusters`)" if clusters.many?

        clusters.first
      end

      def service(type, cluster, user)
        type.new(cluster, context: Syrus::Host::ToolContext.new(surface: :admin, role: nil, user: user), tool_name: ClusterCredential::ADMIN_TOOL_NAME)
      end

      def value_or_dash(value) = value.to_s.strip.presence || "-"
      def yes_no(value) = value ? "yes" : "no"
    end
  end
end
