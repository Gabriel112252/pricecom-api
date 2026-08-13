module Api
  module V1
    class UserActivityLogsController < ApplicationController
      before_action :require_admin!

      PER_PAGE_DEFAULT = 25
      PER_PAGE_MAX     = 100

      # GET /api/v1/user_activity_logs?user_id=&action=&from=&to=&page=
      def index
        logs = apply_filters(current_tenant.user_activity_logs.includes(:user)).recent

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = logs.page(params[:page]).per(per)

        render json: {
          logs: paged.map { |log| log_json(log) },
          meta: {
            current_page: paged.current_page,
            total_pages:  paged.total_pages,
            total_count:  paged.total_count,
            per_page:     paged.limit_value
          }
        }
      end

      private

      def apply_filters(scope)
        scope = scope.by_user(params[:user_id]) if params[:user_id].present?
        scope = scope.by_action(params[:action_type]) if params[:action_type].present?
        scope = scope.where(created_at: parse_date(params[:from])..) if params[:from].present?
        scope = scope.where(created_at: ..parse_date(params[:to])) if params[:to].present?
        scope
      end

      def parse_date(value)
        Time.zone.parse(value.to_s)
      end

      def log_json(log)
        {
          id: log.id,
          action: log.action,
          user: log.user && { id: log.user.id, name: log.user.name, email: log.user.email },
          target_type: log.target_type,
          target_id: log.target_id,
          metadata: log.metadata,
          created_at: log.created_at
        }
      end
    end
  end
end
