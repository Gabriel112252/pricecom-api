# frozen_string_literal: true

require "faraday"
require "json"

module Integrations
  class YampiIdworksIntegratorClient
    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    TIMEOUT = 15

    def configured?
      base_url.present? && token.present?
    end

    def operational_issues
      request(:get, "/api/v1/operational_issues")
    end

    def daily_operational_issues(date: nil)
      path = "/api/v1/operational_issues/daily"
      path = "#{path}?date=#{date}" if date.present?
      request(:get, path)
    end

    def reprocess(issue_id)
      request(:post, "/api/v1/operational_issues/#{issue_id}/reprocess")
    end

    private

    def request(method, path)
      raise Error, "Yampi/IDWorks integrator is not configured" unless configured?

      response = connection.public_send(method, path) do |request|
        request.headers["Accept"] = "application/json"
        request.headers["Authorization"] = "Bearer #{token}"
      end

      body = parse_body(response.body)
      return body if response.success?

      message = body["error"].presence || body["message"].presence || "Integrator request failed with HTTP #{response.status}"
      raise Error.new(message, status: response.status, body: body)
    rescue Faraday::Error => error
      raise Error, "Integrator connection failed: #{error.message}"
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |faraday|
        faraday.options.timeout = TIMEOUT
        faraday.options.open_timeout = TIMEOUT
        faraday.adapter Faraday.default_adapter
      end
    end

    def base_url
      @base_url ||= ENV.fetch("YAMPI_IDWORKS_INTEGRATOR_URL", "").to_s.sub(%r{/+\z}, "")
    end

    def token
      @token ||= ENV.fetch("YAMPI_IDWORKS_INTEGRATOR_TOKEN", "").to_s
    end

    def parse_body(body)
      return {} if body.blank?

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : { "data" => parsed }
    rescue JSON::ParserError
      { "raw" => body.to_s }
    end
  end
end
