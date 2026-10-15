module Api
  module V1
    module App
      module Admin
        # Read-only browsing for a single registered KubernetesCluster:
        # namespace-scoped resources support both a list (no `name` param)
        # and a describe (single object, `name` + `namespace` params) through
        # the same action/route, the same "list vs. show" split
        # MysqlSchemaController expresses as separate routes - kept as one
        # route per resource kind here to match the plugin's declared route
        # list one-for-one.
        class KubernetesResourcesController < BaseController
          before_action :require_k8s_cluster_enabled
          before_action :set_cluster
          before_action :validate_resource_identifiers

          DEFAULT_TAIL_LINES = 200

          def namespaces
            render_cluster_scoped(resource_service(::K8sCluster::Namespaces))
          end

          def pods
            render_namespace_scoped(resource_service(::K8sCluster::Pods))
          end

          def pod_logs
            return unless (namespace = require_namespace!)

            render json: resource_service(::K8sCluster::Pods).logs(
              params[:name],
              namespace: namespace,
              container: params[:container].presence,
              tail_lines: params[:tail_lines].presence&.to_i || DEFAULT_TAIL_LINES,
              previous: !!ActiveModel::Type::Boolean.new.cast(params[:previous]),
              timestamps: !!ActiveModel::Type::Boolean.new.cast(params[:timestamps])
            )
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          rescue ::K8sCluster::ResourceService::NotFound => e
            render_not_found(e)
          end

          def deployments
            render_namespace_scoped(resource_service(::K8sCluster::Deployments))
          end

          def statefulsets
            render_namespace_scoped(resource_service(::K8sCluster::StatefulSets))
          end

          def daemonsets
            render_namespace_scoped(resource_service(::K8sCluster::DaemonSets))
          end

          def jobs
            render_namespace_scoped(resource_service(::K8sCluster::Jobs))
          end

          def services
            render_namespace_scoped(resource_service(::K8sCluster::Services))
          end

          def ingresses
            render_namespace_scoped(resource_service(::K8sCluster::Ingresses))
          end

          def configmaps
            render_namespace_scoped(resource_service(::K8sCluster::ConfigMaps))
          end

          def secrets
            render_namespace_scoped(resource_service(::K8sCluster::Secrets))
          end

          def endpoints
            render_namespace_scoped(resource_service(::K8sCluster::Endpoints))
          end

          def events
            render json: resource_service(::K8sCluster::Events).list(namespace: params[:namespace])
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          end

          def pvcs
            render_namespace_scoped(resource_service(::K8sCluster::PersistentVolumeClaims))
          end

          def nodes
            render_cluster_scoped(resource_service(::K8sCluster::Nodes))
          end

          def cronjobs
            render_namespace_scoped(resource_service(::K8sCluster::CronJobs))
          end

          def overview
            render json: resource_service(::K8sCluster::Overview).call
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          end

          private

          def resource_service(service_class)
            service_class.new(
              @cluster,
              context: admin_credential_context,
              tool_name: ::K8sCluster::ClusterCredential::ADMIN_TOOL_NAME
            )
          end

          def admin_credential_context
            McpToolContext.new(surface: :admin, role: nil, user: Current.user)
          end

          # Cluster-scoped kinds (Namespace, Node): `name` alone selects
          # describe over list.
          def render_cluster_scoped(service)
            if params[:name].present?
              render json: service.describe(params[:name])
            else
              render json: service.list
            end
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          rescue ::K8sCluster::ResourceService::NotFound => e
            render_not_found(e)
          end

          # Namespace-scoped kinds: `namespace` alone (no `name`) filters the
          # list to one namespace; omitting it lists across all namespaces,
          # matching `kubectl get <kind> -A`. Describing a single object
          # (`name` present) requires `namespace` too, since Kubernetes has
          # no cross-namespace "get by name" for these kinds.
          def render_namespace_scoped(service)
            if params[:name].present?
              return unless (namespace = require_namespace!)

              render json: service.describe(params[:name], namespace: namespace)
            else
              render json: service.list(namespace: params[:namespace])
            end
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          rescue ::K8sCluster::ResourceService::NotFound => e
            render_not_found(e)
          end

          def require_namespace!
            return params[:namespace] if params[:namespace].present?

            render_error("namespace_required", "namespace is required to describe a specific resource", status: :unprocessable_content)
            nil
          end

          def validate_resource_identifiers
            ::K8sCluster::ResourceService.validate_identifiers!(
              name: params[:name],
              namespace: params[:namespace],
              container: params[:container]
            )
          rescue ::K8sCluster::ResourceService::InvalidArgument => e
            render_error("invalid_argument", e.message, status: :unprocessable_content)
          end

          def render_unavailable(error)
            render_error("connection_unavailable", error.message, status: :bad_gateway)
          end

          def render_not_found(error)
            render_error("not_found", error.message, status: :not_found)
          end

          def set_cluster
            @cluster = KubernetesCluster.find(params[:id])
          end

          def require_k8s_cluster_enabled
            return if ::K8sCluster.enabled?

            render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "k8s_cluster"), status: :not_found)
          end
        end
      end
    end
  end
end
