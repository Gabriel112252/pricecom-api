module Integrations
  # Raised by an adapter method whose remote operation is real but not yet
  # safely implementable — e.g. the write endpoint exists but its exact
  # path/schema isn't confirmed, or the read side doesn't expose an
  # identifier the write side requires. Deliberately distinct from
  # NotImplementedError (BaseChannelAdapter's "subclass must override
  # this") — this means "the interface method IS implemented, and it has
  # decided, on purpose, not to make the call."
  class UnsupportedOperationError < StandardError; end
end
