module Integrations
  # Raised when a channel rejects our credentials (HTTP 401/403, or a
  # channel-specific auth failure code in the response body).
  class AuthenticationError < StandardError; end
end
