module Tus
  Error           = Class.new(StandardError)
  NotFound        = Class.new(Error)
  MaxSizeExceeded = Class.new(Error)
end
