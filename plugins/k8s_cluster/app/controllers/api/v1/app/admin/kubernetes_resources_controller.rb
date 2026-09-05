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

          DEFAULT_TAIL_LINES = 200

          def namespaces
            render_cluster_scoped(::K8sCluster::Namespaces.new(@cluster))
          end

          def pods
            render_namespace_scoped(::K8sCluster::Pods.new(@cluster))
          end

          def pod_logs
            return unless (namespace = require_namespace!)

            render json: ::K8sCluster::Pods.new(@cluster).logs(
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
            render_namespace_scoped(::K8sCluster::Deployments.new(@cluster))
          end

          def services
            render_namespace_scoped(::K8sCluster::Services.new(@cluster))
          end

          def events
            render json: ::K8sCluster::Events.new(@cluster).list(namespace: params[:namespace])
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          end

          def pvcs
            render_namespace_scoped(::K8sCluster::PersistentVolumeClaims.new(@cluster))
          end

          def nodes
            render_cluster_scoped(::K8sCluster::Nodes.new(@cluster))
          end

          def cronjobs
            render_namespace_scoped(::K8sCluster::CronJobs.new(@cluster))
          end

          def overview
            render json: ::K8sCluster::Overview.new(@cluster).call
          rescue ::K8sCluster::ResourceService::Unavailable => e
            render_unavailable(e)
          end

          private

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

            render_error("plugin_disabled", "The k8s_cluster plugin is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
