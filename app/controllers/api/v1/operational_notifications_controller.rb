module Api
  module V1
    class OperationalNotificationsController < ApplicationController
      before_action :require_admin!

      def whatsapp_test
        OperationalAlerts::WhatsappTestNotificationJob.perform_later(current_tenant.id)

        render json: {
          status: "queued",
          message: "Teste de WhatsApp enfileirado."
        }, status: :accepted
      end
    end
  end
end
