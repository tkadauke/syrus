module Api
  module V1
    module App
      module Admin
        class InvitationsController < BaseController
          PER_PAGE = 100
          MAX_PER_PAGE = 200
          SORTS = {
            "email" => { email_address: :asc },
            "expires_at" => { expires_at: :asc },
            "created_at" => { created_at: :asc }
          }.freeze
          DEFAULT_SORT = "created_at"
          FILTER_SCHEMA = [
            {
              bucket: "text",
              field: "email",
              label: "Email",
              operators: [ "contains" ]
            }
          ].freeze

          def index
            render json: invitations_payload
          end

          def create
            invitation = Invitation.new(invitation_params.merge(invited_by: Current.user))

            if invitation.save
              InvitationMailer.invite(invitation).deliver_later

              render json: invitations_payload.merge(message: I18n.t("api.admin_invitations.created", email: invitation.email_address)),
                     status: :created
            else
              render_error("validation_failed", invitation.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          def destroy
            invitation = Invitation.find(params[:id])
            invitation.destroy!

            render json: invitations_payload.merge(message: I18n.t("api.admin_invitations.revoked"))
          end

          private

          def invitations_payload
            filter = filter_tree
            scope = apply_filter(Invitation.pending.includes(:invited_by), filter)
            total = scope.count
            {
              invitations: apply_sort(scope).offset(offset).limit(per_page).map { |invitation| invitation_json(invitation) },
              filter: filter,
              filter_schema: FILTER_SCHEMA,
              filters: flat_filters(filter),
              total: total,
              pagination: pagination_payload(total),
              sort: sort_payload
            }
          end

          def filter_tree
            decoded = ::Filters::QueryParam.decode(params[:q] || params["q"]) if (params[:q] || params["q"]).present?
            return ::Filters::Ast.serialize(::Filters::Ast.parse(decoded)) if decoded

            email = params[:email].presence || params["email"].presence
            return { "and" => [] } if email.blank?

            { "and" => [ { "field" => "email", "op" => "contains", "value" => email } ] }
          rescue ArgumentError
            { "and" => [] }
          end

          def apply_filter(scope, tree)
            email = flat_filters(tree)["email"]
            return scope if email.blank?

            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(email.to_s)}%"
            scope.where("email_address LIKE ?", pattern)
          end

          def flat_filters(tree)
            chips = []
            collect_chips(::Filters::Ast.parse(tree), chips)
            chips.to_h { |chip| [ chip.field, chip.value ] }
          end

          def collect_chips(node, chips)
            if node.is_a?(::Filters::Ast::Chip)
              chips << node
            elsif node.respond_to?(:children)
              node.children.each { |child| collect_chips(child, chips) }
            elsif node.respond_to?(:child)
              collect_chips(node.child, chips)
            end
            chips
          end

          def page
            [ params[:page].to_i, 1 ].max
          end

          def per_page
            raw = params[:per_page].to_i
            return PER_PAGE unless raw.positive?

            [ raw, MAX_PER_PAGE ].min
          end

          def offset
            (page - 1) * per_page
          end

          def sort_column
            SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : DEFAULT_SORT
          end

          def sort_direction
            params[:direction].to_s == "asc" ? "asc" : "desc"
          end

          def apply_sort(scope)
            direction = sort_direction.to_sym
            scope.order(SORTS.fetch(sort_column).transform_values { direction }).order(id: direction)
          end

          def sort_payload
            {
              column: sort_column,
              direction: sort_direction
            }
          end

          def pagination_payload(total)
            total_pages = (total.to_f / per_page).ceil
            {
              page: page,
              per_page: per_page,
              total: total,
              total_pages: total_pages,
              has_previous_page: page > 1,
              has_next_page: total_pages > page,
              previous_page: page > 1 ? page - 1 : nil,
              next_page: total_pages > page ? page + 1 : nil,
              first_item: total.zero? ? 0 : offset + 1,
              last_item: [ offset + per_page, total ].min
            }
          end

          def invitation_json(invitation)
            {
              id: invitation.id,
              email_address: invitation.email_address,
              token: invitation.token,
              share_url: new_user_url(token: invitation.token),
              expires_at: invitation.expires_at.iso8601,
              created_at: invitation.created_at.iso8601,
              invited_by_email_address: invitation.invited_by.email_address
            }
          end

          def invitation_params
            params.expect(invitation: [ :email_address ])
          end
        end
      end
    end
  end
end
