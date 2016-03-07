# Will be used as the logger if Rack passes us no logger at all
module FastSend::NullLogger
  [:debug, :info, :warn, :fatal, :error].each do |m|
    define_method(m) do
    end
  end
  extend self
end
