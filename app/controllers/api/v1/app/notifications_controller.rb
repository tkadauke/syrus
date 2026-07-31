module Api
  module V1
    module App
      class NotificationsController < BaseController
        PER_PAGE = 20

        def index
          render json: notifications_payload
        end

        def mark_all_read
          read_at = Time.current
          Current.user.notifications.unread.update_all(read_at: read_at)
          broadcast_read_update(all_read: true, read_at: read_at)

          render json: notifications_payload
        end

        def mark_read
          notification = Current.user.notifications.find(params[:id])
          unless notification.read_at?
            notification.update!(read_at: Time.current)
            broadcast_read_update(notification_ids: [ notification.id ], read_at: notification.read_at)
          end

          render json: {
            notification: notification_json(notification.reload),
            unread_count: unread_count
          }
        end

        private

        def notifications_payload
          relation = filtered_notifications
          total = relation.count
          page = page_param
          total_pages = (total.to_f / PER_PAGE).ceil
          notifications = relation
            .recent
            .offset((page - 1) * PER_PAGE)
            .limit(PER_PAGE)

          {
            notifications: notifications.map { |notification| notification_json(notification) },
            unread_count: unread_count,
            pagination: {
              page: page,
              per_page: PER_PAGE,
              total: total,
              total_pages: total_pages
            }
          }
        end

        def filtered_notifications
          notifications = Current.user.notifications.includes(:job)
          return notifications.unread if ActiveModel::Type::Boolean.new.cast(params[:unread])

          notifications
        end

        def notification_json(notification)
          payload = {
            id: notification.id,
            kind: notification.kind,
            body: notification.body,
            read_at: notification.read_at&.iso8601,
            pr_url: notification.pr_url,
            job_id: notification.job_id,
            job_title: notification.job&.title,
            created_at: notification.created_at.iso8601
          }
          if AppSetting.simple?
            payload.merge(pr_url: nil, job_id: nil, job_title: nil)
          else
            payload
          end
        end

        def unread_count
          Current.user.notifications.unread.count
        end

        def broadcast_read_update(notification_ids: [], all_read: false, read_at:)
          AppUserChannel.broadcast_to(
            Current.user,
            {
              type: "notification_read",
              unread_count: unread_count,
              payload: {
                notification_ids: notification_ids,
                all_read: all_read,
                read_at: read_at.iso8601
              }
            }.as_json
          )
        end

        def page_param
          page = params[:page].to_i
          page.positive? ? page : 1
        end
      end
    end
  end
end
