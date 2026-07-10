module Integrations
  # Any other non-2xx response, or a response we couldn't parse.
  class ApiError < StandardError; end
end
