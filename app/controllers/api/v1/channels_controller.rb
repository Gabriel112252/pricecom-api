module Api
  module V1
    class ChannelsController < ApplicationController
      def index
        channels = current_tenant.channels.order(name: :asc)

        render json: channels.map { |c| index_json(c) }
      end

      private

      def index_json(channel)
        {
          id:       channel.id,
          name:     channel.name,
          platform: channel.platform,
          active:   channel.active
        }
      end
    end
  end
end
