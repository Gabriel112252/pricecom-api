module Integrations
  # Raised on HTTP 429 (or a channel-specific throttling response). Carries
  # `retry_after` (seconds) when the channel sends a Retry-After header, so
  # callers can decide whether to back off.
  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(message = "Rate limited", retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
end
