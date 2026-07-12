require "json"
require "faraday"

class YampiOrdersDiagnostic
  MAX_REQUESTS = 5
  BASE_URL = Integrations::YampiAdapter::BASE_URL
  SAFE_URL = "https://api.dooki.com.br/v2/[REDACTED_ALIAS]/orders".freeze

  def self.call
    new.call
  rescue => e
    warn JSON.pretty_generate(
      diagnostic: "yampi_orders",
      requests_performed: 0,
      error_class: e.class.name,
      error_message: e.message.to_s
    )
    exit 1
  end

  def initialize
    @request_count = 0
    @last_request_at = nil
    @credential = find_credential
    @credentials = @credential.credentials.to_h.with_indifferent_access
    @adapter = Integrations::YampiAdapter.new(@credential.credentials)
    @connection = @adapter.send(:connection, BASE_URL)
    @path = @adapter.send(:alias_path, "/orders")
    @results = []
  end

  def call
    since_date = 2.days.ago.to_date.iso8601
    until_date = Time.zone.today.iso8601
    created_filter = "created_at:#{since_date}|#{until_date}"
    updated_filter = "updated_at:#{since_date}|#{until_date}"

    run_request(
      name: "created_at_limit_1",
      params: base_params.merge(date: created_filter, limit: 1)
    )

    run_request(
      name: "created_at_limit_100",
      params: base_params.merge(date: created_filter, limit: 100)
    )

    run_request(
      name: "created_at_per_page_1",
      params: base_params.merge(date: created_filter, per_page: 1)
    )

    run_request(
      name: "updated_at_limit_1",
      params: base_params.merge(date: updated_filter, limit: 1)
    )

    run_request(
      name: "created_at_limit_1_skip_cache",
      params: base_params.merge(date: created_filter, limit: 1, skipCache: true)
    )

    output = {
      diagnostic: "yampi_orders",
      tenant_id: @credential.tenant_id,
      channel_credential_id: @credential.id,
      requested_window: {
        since_date: since_date,
        until_date: until_date
      },
      requests_performed: @request_count,
      results: @results,
      summary: build_summary
    }

    puts JSON.pretty_generate(output)
  rescue => e
    warn JSON.pretty_generate(
      diagnostic: "yampi_orders",
      requests_performed: @request_count,
      error_class: e.class.name,
      error_message: sanitize(e.message)
    )
    exit 1
  end

  private

  def find_credential
    scope = ChannelCredential.includes(:tenant).where(channel: "yampi")
    scope = scope.joins(:tenant).where(tenants: { slug: ENV["YAMPI_TENANT_SLUG"] }) if ENV["YAMPI_TENANT_SLUG"].present?
    credential = scope.where(status: "active").order(:id).first || scope.order(:id).first

    raise "No Yampi ChannelCredential found" unless credential
    raise "Yampi ChannelCredential has no credentials" if credential.credentials.blank?

    credential
  end

  def base_params
    {
      page: 1,
      include: "items,customer,status"
    }
  end

  def run_request(name:, params:)
    raise "Request cap exceeded" if @request_count >= MAX_REQUESTS

    wait_for_minimum_interval

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = @connection.get(@path, params) do |req|
      req.headers["User-Token"] = @credentials[:token]
      req.headers["User-Secret-Key"] = @credentials[:secret_key]
    end
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    @request_count += 1
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    body = parse_body(response.body)
    data = body.is_a?(Hash) && body["data"].is_a?(Array) ? body["data"] : []
    first_order = data.first

    @results << {
      name: name,
      url: SAFE_URL,
      params: sanitize_params(params),
      status: response.status,
      content_type: response.headers["content-type"],
      x_rate_limit_limit: response.headers["x-ratelimit-limit"],
      x_rate_limit_remaining: response.headers["x-ratelimit-remaining"],
      retry_after: response.headers["retry-after"],
      body_class: body.class.name,
      top_level_keys: body.is_a?(Hash) ? body.keys : [],
      data_count: data.size,
      meta_pagination: body.is_a?(Hash) ? body.dig("meta", "pagination") : nil,
      first_order_keys: first_order.is_a?(Hash) ? first_order.keys : [],
      first_order_shape: first_order.is_a?(Hash) ? shape_for(first_order) : nil,
      date_fields: first_order.is_a?(Hash) ? date_fields_for(first_order) : [],
      duration_ms: duration_ms
    }
  rescue => e
    duration_ms = defined?(started) ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1) : nil
    @request_count += 1
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    @results << {
      name: name,
      url: SAFE_URL,
      params: sanitize_params(params),
      error_class: e.class.name,
      error_message: sanitize(e.message),
      duration_ms: duration_ms
    }
  end

  def wait_for_minimum_interval
    return unless @last_request_at

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request_at
    sleep(1.0 - elapsed) if elapsed < 1.0
  end

  def parse_body(body)
    return body unless body.is_a?(String)

    JSON.parse(body)
  rescue JSON::ParserError
    body
  end

  def sanitize_params(params)
    params.transform_values { |value| sanitize(value.to_s) }
  end

  def sanitize(value)
    text = value.to_s.dup
    sensitive_values.each do |secret|
      next if secret.blank?

      text.gsub!(secret.to_s, "[REDACTED]")
    end
    text
  end

  def sensitive_values
    @sensitive_values ||= %i[alias token secret_key webhook_secret access_token].filter_map { |key| @credentials[key] }
  end

  def shape_for(hash)
    hash.each_with_object({}) do |(key, value), memo|
      memo[key] = value_shape(value)
    end
  end

  def value_shape(value)
    case value
    when Hash
      {
        type: "Hash",
        keys: value.keys
      }
    when Array
      {
        type: "Array",
        count: value.size,
        first_item_type: value.first.class.name
      }
    else
      {
        type: value.class.name
      }
    end
  end

  def date_fields_for(object, prefix = nil)
    return [] unless object.is_a?(Hash)

    object.flat_map do |key, value|
      path = [prefix, key].compact.join(".")
      nested = value.is_a?(Hash) ? date_fields_for(value, path) : []
      matches_date_key?(key) ? [ { path: path, value_type: value.class.name } ] + nested : nested
    end
  end

  def matches_date_key?(key)
    normalized = key.to_s.downcase
    normalized == "date" ||
      normalized.end_with?("_at") ||
      normalized.include?("date") ||
      normalized.include?("time")
  end

  def build_summary
    limit_100 = result_named("created_at_limit_100")
    per_page_1 = result_named("created_at_per_page_1")
    updated = result_named("updated_at_limit_1")
    skip_cache = result_named("created_at_limit_1_skip_cache")

    {
      limit_100_respected: limit_respected?(limit_100, 100),
      limit_100_pagination_per_page: limit_100&.dig(:meta_pagination, "per_page"),
      per_page_1_respected: limit_respected?(per_page_1, 1),
      per_page_1_pagination_per_page: per_page_1&.dig(:meta_pagination, "per_page"),
      updated_at_filter_status: updated&.dig(:status),
      updated_at_filter_error: updated&.dig(:error_message),
      updated_at_filter_returned_data_count: updated&.dig(:data_count),
      skip_cache_status: skip_cache&.dig(:status),
      skip_cache_data_count: skip_cache&.dig(:data_count),
      observed_rate_limit_headers: @results.map { |result|
        {
          name: result[:name],
          x_rate_limit_limit: result[:x_rate_limit_limit],
          x_rate_limit_remaining: result[:x_rate_limit_remaining],
          retry_after: result[:retry_after]
        }
      }
    }
  end

  def result_named(name)
    @results.find { |result| result[:name] == name }
  end

  def limit_respected?(result, limit)
    return nil unless result && result[:data_count]

    result[:data_count].to_i <= limit
  end
end

YampiOrdersDiagnostic.call
