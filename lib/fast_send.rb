require 'logger'
# A Rack middleware that sends the response using file buffers. If the response body
# returned by the upstream application supports "each_file", then the middleware will
# call this method, grab each yielded file in succession and use the fastest possible
# way to send it to the client (using a response wrapper or Rack hijacking). If
# sendfile support is available on the client socket, sendfile() will be used to stream
# the file via the OS.
# 
# A sample response body object will look like this:
#
#     class Files
#       def each_file
#         File.open('data1.bin','r') {|f| yield(f) }
#         File.open('data2.bin','r') {|f| yield(f) }
#       end
#     end
#     
#     # and then in your Rack app
#     return [200, {'Content-Type' => 'binary/octet-stream'}, Files.new]
#
# Note that the receiver of `each_file` is responsbble for closing and deallocating
# the file if necessary.
#
#
# You can also supply the following response headers that will be used as callbacks
# during the response send on the way out.
#
#    `fast_send.started' => ->(zero_bytes) { } # When the response is started
#    `fast_send.bytes_sent' => ->(sent_this_time, sent_total) { } # Called on each sent chunk
#    `fast_send.complete' => ->(sent_total) { } # When response completes without exceptions
#    `fast_send.aborted' => ->(exception) { } # When the response is not sent completely, both for exceptions and client closes
#    `fast_send.error' => ->(exception) { } # the response is not sent completely due to an error in the application
#    `fast_send.cleanup' => ->(sent_total) { } # Called at the end of the response, in an ensure block
class FastSend
  require_relative 'fast_send/socket_handler'
  
  VERSION = '1.0.2'
  
  # All exceptions that get raised when the client closes a connection before receiving the entire response
  CLIENT_DISCONNECTS = [Errno::EPIPE, Errno::ECONNRESET, Errno::ENOTCONN, Errno::EPROTOTYPE]
  
  if RUBY_PLATFORM =~ /java/
    require 'java'
    CLIENT_DISCONNECTS << Java::JavaIo::IOException
  end
  
  
  # Gets raised if a fast_send.something is mentioned in
  # the response headers but is not supported as a callback
  # (the dangers of hashmaps as datastructures is that you
  # can sometimes mistype keys)
  UnknownCallback = Class.new(StandardError)

  # Gets used as a response body wrapper if the server does not support Rack hijacking.
  # The wrapper will be automatically applied by FastSend and will also ensure that all the
  # callbacks get executed.
  class NaiveEach < Struct.new(:body_with_each_file, :started, :aborted, :error, :complete, :sent, :cleanup)
    def each
      written = 0
      started.call(0)
      body_with_each_file.each_file do | file |
        while data = file.read(64 * 1024)
          written += data.bytesize
          yield(data)
          sent.call(data.bytesize, written)
        end
      end
      complete.call(written)
    rescue *CLIENT_DISCONNECTS => e
      aborted.call(e)
    rescue Exception => e
      aborted.call(e)
      error.call(e)
      raise e
    ensure
      cleanup.call(written)
    end
  end
  
  NOOP = ->(*){}.freeze
  NULL_LOGGER = Logger.new($stderr)
  C_Connection = 'Connection'.freeze
  C_close = 'close'.freeze
  C_rack_hijack = 'rack.hijack'.freeze
  C_dispatch = 'X-Fast-Send-Dispatch'.freeze
  C_hijack = 'hijack'.freeze
  C_naive = 'each'.freeze
  C_rack_logger = 'rack.logger'.freeze
  C_SERVER_SOFTWARE = 'SERVER_SOFTWARE'.freeze
  
  private_constant :C_Connection, :C_close, :C_rack_hijack, :C_dispatch, :C_hijack, :C_naive, :NOOP, :NULL_LOGGER,
    :C_rack_logger, :C_SERVER_SOFTWARE
  
  CALLBACK_HEADER_NAMES = %w( 
    fast_send.started
    fast_send.aborted
    fast_send.error
    fast_send.complete
    fast_send.bytes_sent
    fast_send.cleanup
  ).freeze
  
  def initialize(with_rack_app)
    @app = with_rack_app
  end
  
  def call(env)
    s, h, b = @app.call(env)
    return [s, h, b] unless b.respond_to?(:each_file) 
    
    @logger = env.fetch(C_rack_logger) { NULL_LOGGER }
    
    server = env[C_SERVER_SOFTWARE]
    
    if has_robust_hijack_support?(env)
      @logger.debug { 'Server (%s) allows partial hijack, setting up Connection: close'  % server }
      h[C_Connection] = C_close
      h[C_dispatch] = C_hijack
      response_via_hijack(s, h, b)
    else
      @logger.warn {
        msg = 'Server (%s) has no hijack support or hijacking is broken. Unwanted buffering possible.'
        msg % server
      }
      h[C_dispatch] = C_naive
      response_via_naive_each(s, h, b)
    end
  end
  
  private
  
  def has_robust_hijack_support?(env)
    return false unless env['rack.hijack?']
    return false if env['SERVER_SOFTWARE'] =~ /^WEBrick/ # WEBrick implements hijack using a pipe
    true
  end
    
  def response_via_naive_each(s, h, b)
    body = NaiveEach.new(b, *callbacks_from_headers(h))
    [s, h, body]
  end
  
  def callbacks_from_headers(h)
    headers_related = h.keys.grep(/^fast\_send\./i)
    headers_related.each do | header_name |
      unless CALLBACK_HEADER_NAMES.include?(header_name)
        msg = "Unknown callback #{header_name.inspect} (supported: #{CALLBACK_HEADER_NAMES.join(', ')})"
        raise UnknownCallback, msg
      end
    end 
    CALLBACK_HEADER_NAMES.map{|cb_name| h.delete(cb_name) || NOOP }
  end
    
  def response_via_hijack(status, headers, each_file_body)
    headers[C_rack_hijack] = SocketHandler.new(each_file_body, @logger, *callbacks_from_headers(headers))
    [status, headers, []]
  end
end
