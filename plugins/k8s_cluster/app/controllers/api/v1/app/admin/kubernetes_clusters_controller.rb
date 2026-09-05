module Api
  module V1
    module App
      module Admin
        class KubernetesClustersController < BaseController
          before_action :require_k8s_cluster_enabled

          def index
            render json: { kubernetes_clusters: KubernetesCluster.order(:label).map { |cluster| cluster_json(cluster) } }
          end

          def create
            cluster = KubernetesCluster.new(cluster_params)
            apply_kubeconfig!(cluster, require_kubeconfig: true)

            if cluster.errors.empty? && cluster.save
              render json: { kubernetes_cluster: cluster_json(cluster) }, status: :created
            else
              render_error("validation_failed", cluster.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def update
            cluster = find_cluster
            cluster.assign_attributes(cluster_params)
            apply_kubeconfig!(cluster, require_kubeconfig: false)

            if cluster.errors.empty? && cluster.save
              render json: { kubernetes_cluster: cluster_json(cluster) }
            else
              render_error("validation_failed", cluster.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def destroy
            find_cluster.destroy!
            head :no_content
          end

          def test_connection
            result = params[:id].present? ? test_existing_cluster : test_draft_cluster
            render json: result
          end

          private

          def test_existing_cluster
            cluster = find_cluster
            kubeconfig = params.dig(:kubernetes_cluster, :kubeconfig)
            return K8sCluster::ConnectionTester.test(cluster) if kubeconfig.blank?

            with_parsed_kubeconfig(kubeconfig) do |parsed|
              K8sCluster::ConnectionTester.test_params(
                api_server_url: parsed.api_server_url,
                token: parsed.credentials["token"],
                client_cert: parsed.credentials["client_cert"],
                client_key: parsed.credentials["client_key"],
                ca_data: parsed.credentials["ca_data"],
                insecure_skip_tls_verify: cluster.insecure_skip_tls_verify
              )
            end
          end

          def test_draft_cluster
            kubeconfig = params.dig(:kubernetes_cluster, :kubeconfig)
            insecure_skip_tls_verify = ActiveModel::Type::Boolean.new.cast(params.dig(:kubernetes_cluster, :insecure_skip_tls_verify))

            with_parsed_kubeconfig(kubeconfig) do |parsed|
              K8sCluster::ConnectionTester.test_params(
                api_server_url: parsed.api_server_url,
                token: parsed.credentials["token"],
                client_cert: parsed.credentials["client_cert"],
                client_key: parsed.credentials["client_key"],
                ca_data: parsed.credentials["ca_data"],
                insecure_skip_tls_verify: insecure_skip_tls_verify
              )
            end
          end

          def with_parsed_kubeconfig(kubeconfig)
            parsed = K8sCluster::KubeconfigParser.parse(kubeconfig)
            yield parsed
          rescue K8sCluster::KubeconfigParser::ParseError => e
            { success: false, error: e.message }
          end

          def apply_kubeconfig!(cluster, require_kubeconfig:)
            kubeconfig = params.dig(:kubernetes_cluster, :kubeconfig)
            return if kubeconfig.blank? && !require_kubeconfig

            if kubeconfig.blank?
              cluster.errors.add(:base, "kubeconfig is required")
              return
            end

            parsed = K8sCluster::KubeconfigParser.parse(kubeconfig)
            cluster.api_server_url = parsed.api_server_url
            cluster.credentials = parsed.credentials
          rescue K8sCluster::KubeconfigParser::ParseError => e
            cluster.errors.add(:base, e.message)
          end

          def find_cluster
            KubernetesCluster.find(params[:id])
          end

          def cluster_params
            params.require(:kubernetes_cluster).permit(:label, :agentic_access_enabled, :allow_writes, :insecure_skip_tls_verify)
          end

          def cluster_json(cluster)
            {
              id: cluster.id,
              label: cluster.label,
              api_server_url: cluster.api_server_url,
              agentic_access_enabled: cluster.agentic_access_enabled,
              allow_writes: cluster.allow_writes,
              insecure_skip_tls_verify: cluster.insecure_skip_tls_verify,
              credential_kind: credential_kind(cluster),
              created_at: cluster.created_at.iso8601,
              updated_at: cluster.updated_at.iso8601
            }
          end

          def credential_kind(cluster)
            return "token" if cluster.token.present?
            return "client_cert" if cluster.client_cert.present?

            nil
          end

          def require_k8s_cluster_enabled
            return if ::K8sCluster.enabled?

            render_error("plugin_disabled", "The k8s_cluster plugin is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
