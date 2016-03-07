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
  VERSION = '1.0.2'
  
  # How many seconds we will wait before considering a client dead.
  SOCKET_TIMEOUT = 185
  
  # The time between select() calls when a socket is blocking on write
  SELECT_TIMEOUT_ON_BLOCK = 5
  
  # Is raised when it is not possible to send a chunk of data
  # to the client using non-blocking sends for longer than
  # the SOCKET_TIMEOUT seconds.
  SlowLoris = Class.new(StandardError)
  
  # Gets raised if a fast_send.something is mentioned in
  # the response headers but is not supported as a callback
  # (the dangers of hashmaps as datastructures is that you
  # can sometimes mistype keys)
  UnknownCallback = Class.new(StandardError)
  
  # Whether we are forced to use blocking IO for sendfile()
  USE_BLOCKING_SENDFILE = !!(RUBY_PLATFORM =~ /darwin/)
  
  # The amount of bytes we will try to fit in a single sendfile()/copy_stream() call
  # We need to send it chunks because otherwise we have no way to have throughput
  # stats that we need for load-balancing. Also, the sendfile() call is limited to the size
  # of  off_t, which is platform-specific. In general, it helps to stay small on this for
  # more control.C
  SENDFILE_CHUNK_SIZE = 2*1024*1024
  
  # Cache some strings for mem use
  NOOP = ->(*){}.freeze
  NULL_LOGGER = Logger.new($stderr)
  
  # All exceptions that get raised when the client closes a connection before receiving the entire response
  CLIENT_DISCONNECTS = [SlowLoris, Errno::EPIPE, Errno::ECONNRESET, Errno::ENOTCONN, Errno::EPROTOTYPE]
  
  C_Connection = 'Connection'.freeze
  C_close = 'close'.freeze
  C_rack_hijack = 'rack.hijack'.freeze
  C_dispatch = 'X-Fast-Send-Dispatch'.freeze
  C_hijack = 'hijack'.freeze
  C_naive = 'each'.freeze
  
  if RUBY_PLATFORM =~ /java/
    require 'java'
    CLIENT_DISCONNECTS << Java::JavaIo::IOException
  end
  
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
  
  def initialize(with_rack_app)
    @app = with_rack_app
  end
  
  def call(env)
    s, h, b = @app.call(env)
    return [s, h, b] unless b.respond_to?(:each_file) 
    
    @logger = env.fetch('rack.logger') { NULL_LOGGER }
    
    server = env['SERVER_SOFTWARE']
    
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
  
  CALLBACK_HEADER_NAMES = %w( 
    fast_send.started
    fast_send.aborted
    fast_send.error
    fast_send.complete
    fast_send.bytes_sent
    fast_send.cleanup
  ).freeze
  
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
    
  def response_via_hijack(s, h, b)
    h[C_rack_hijack] = create_hijack_proc(b, *callbacks_from_headers(h))
    [s, h, []]
  end
  
  # Set up the hijack response with sendfile() use.
  def create_hijack_proc(stream, started_proc, aborted_proc, error_proc, done_proc, written_proc, cleanup_proc)
    lambda do | socket |
      return if socket.closed?
      
      writer_method_name = if socket.respond_to?(:sendfile)
        :sendfile
      elsif RUBY_PLATFORM == 'java'
        :copy_nio
      else
        :copy_stream
      end
      
      @logger.debug { "Will do file-to-socket using %s" % writer_method_name }
      
      begin
        @logger.debug { "Starting the response" }
        
        bytes_written = 0
        
        started_proc.call(bytes_written)
        
        stream.each_file do | file |
          @logger.debug { "Sending %s" % file.inspect }
          # Run the sending method, depending on the implementation
          send(writer_method_name, socket, file) do |n_bytes_sent|
            bytes_written += n_bytes_sent
            @logger.debug { "Written %d bytes" % bytes_written }
            written_proc.call(n_bytes_sent, bytes_written)
          end
        end
        
        @logger.info { "Response written in full - %d bytes" % bytes_written }
        done_proc.call(bytes_written)
      rescue *CLIENT_DISCONNECTS => e
        @logger.warn { "Client closed connection: #{e.class}(#{e.message})" }
        aborted_proc.call(e)
      rescue Exception => e
        @logger.fatal { "Aborting response due to error: #{e.class}(#{e.message})" }
        (e.backtrace || [])[0..50].each{|line| @logger.fatal { line } }
        aborted_proc.call(e)
        error_proc.call(e)
      ensure
        @logger.debug { "Performing cleanup" }
        cleanup_proc.call(bytes_written)
        # With rack.hijack the consensus seems to be that the hijack
        # proc is responsible for closing the socket. We also use no-keepalive
        # so this should not pose any problems.
        socket.close unless socket.closed?
      end
    end
  end
  
  # This is majorly useful - if the socket is not selectable after a certain
  # timeout, it might be a slow loris or a connection that hung up on us. So if
  # the return from select() is nil, we know that we still cannot write into
  # the socket for some reason. Kill the request, it is dead, jim.
  #
  # Note that this will not work on OSX due to a sendfile() bug.
  def fire_timeout_using_select(writable_socket)
    at = Time.now
    loop do
      return if IO.select(nil, [writable_socket], [writable_socket], SELECT_TIMEOUT_ON_BLOCK)
      if (Time.now - at) > SOCKET_TIMEOUT
        raise SlowLoris, "Receiving socket timed out on sendfile(), probably a dead slow loris"
      end
    end
  end
  
  
  # Copies the file to the socket using sendfile().
  # If we are not running on Darwin we are going to use a non-blocking version of
  # sendfile(), and send the socket into a select() wait loop. If no data can be written
  # after 3 minutes the request will be terminated.
  # On Darwin a blocking sendfile() call will be used instead.
  #
  # @param socket[Socket] the socket to write to
  # @param file[File] the file you can read from
  # @yields num_bytes_written[Fixnum] the number of bytes written by each `IO.copy_stream() call`
  # @return [void]
  def sendfile(socket, file)
    chunk = SENDFILE_CHUNK_SIZE
    remaining = file.size
    
    loop do
      break if remaining < 1
      
      # Use exact offsets to avoid boobytraps
      send_this_time = remaining < chunk ? remaining : chunk
      read_at_offset = file.size - remaining
      
      # We have to use blocking "sendfile" on Darwin because the non-blocking version
      # is buggy
      # (in an end-to-end test the number of bytes received varies).
      written = if USE_BLOCKING_SENDFILE
        socket.sendfile(file, read_at_offset, send_this_time)
      else
        socket.trysendfile(file, read_at_offset, send_this_time)
      end
      
      # Will be only triggered when using non-blocking "trysendfile", i.e. on Linux.
      if written == :wait_writable
        fire_timeout_using_select(socket) # Used to evict slow lorises
      elsif written.nil? # Also only relevant for "trysendfile"
        yield(0) # We are done, nil == EOF
        return
      else
        remaining -= written
        yield(written)
      end
    end
  end
  
  # Copies the file to the socket using `IO.copy_stream`.
  # This allows the strings flowing from file to the socket to bypass
  # the Ruby VM and be managed within the calls without allocations.
  # This method gets used when Socket#sendfile is not available on the
  # system we run on (for instance, on Jruby).
  #
  # @param socket[Socket] the socket to write to
  # @param file[File] the IO you can read from
  # @yields num_bytes_written[Fixnum] the number of bytes written on each `IO.copy_stream() call`
  # @return [void]
  def copy_stream(socket, file)
    chunk = SENDFILE_CHUNK_SIZE
    remaining = file.size
    
    loop do
      break if remaining < 1
      
      # Use exact offsets to avoid boobytraps
      send_this_time = remaining < chunk ? remaining : chunk
      num_bytes_written = IO.copy_stream(file, socket, send_this_time)
      
      if num_bytes_written.nonzero?
        remaining -= num_bytes_written
        yield(num_bytes_written)
      end
    end
  end
  
  # The closest you can get to sendfile with Java's NIO
  # http://www.ibm.com/developerworks/library/j-zerocopy
  def copy_nio(socket, file)
    chunk = SENDFILE_CHUNK_SIZE
    remaining = file.size
    
    # We need a Java stream for this, and we cannot really initialize
    # it from a jRuby File in a convenient way. Since we need it briefly
    # and we know that the file is on the filesystem at the given path,
    # we can just open it using the Java means, and go from there
    input_stream = java.io.FileInputStream.new(file.path)
    input_channel = input_stream.getChannel
    output_channel = socket.to_channel
    
    loop do
      break if remaining < 1
      
      # Use exact offsets to avoid boobytraps
      send_this_time = remaining < chunk ? remaining : chunk
      read_at = file.size - remaining
      num_bytes_written = input_channel.transferTo(read_at, send_this_time, output_channel)
      
      if num_bytes_written.nonzero?
        remaining -= num_bytes_written
        yield(num_bytes_written)
      end
    end
  ensure
    input_channel.close
    input_stream.close
  end
end
