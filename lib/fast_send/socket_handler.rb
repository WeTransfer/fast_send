require 'io/wait'

# Handles the TCP socket within the Rack hijack. Is used instead of a Proc object for better
# testability and better deallocation
class FastSend::SocketHandler < Struct.new(:stream, :logger, :started_proc, :aborted_proc, :error_proc, 
  :done_proc, :written_proc, :cleanup_proc)
  
  # How many seconds we will wait before considering a client dead.
  SOCKET_TIMEOUT = 60
  
  # The time between select() calls when a socket is blocking on write
  SELECT_TIMEOUT_ON_BLOCK = 5
  
  # Is raised when it is not possible to send a chunk of data
  # to the client using non-blocking sends for longer than the preset timeout
  SlowLoris = Class.new(StandardError)

  # Exceptions that indicate a client being too slow or dropping out
  # due to failing reads/writes
  CLIENT_DISCONNECT_EXCEPTIONS = [SlowLoris] + ::FastSend::CLIENT_DISCONNECTS
  
  # Whether we are forced to use blocking IO for sendfile()
  USE_BLOCKING_SENDFILE = !!(RUBY_PLATFORM =~ /darwin/)
  
  # The amount of bytes we will try to fit in a single sendfile()/copy_stream() call
  # We need to send it chunks because otherwise we have no way to have throughput
  # stats that we need for load-balancing. Also, the sendfile() call is limited to the size
  # of  off_t, which is platform-specific. In general, it helps to stay small on this for
  # more control.C
  SENDFILE_CHUNK_SIZE = 2*1024*1024

  def call(socket)
    return if socket.closed?
    
    writer_method_name = if socket.respond_to?(:sendfile)
      :sendfile
    elsif RUBY_PLATFORM == 'java'
      :copy_nio
    else
      :copy_stream
    end
    
    logger.debug { "Will do file-to-socket using %s" % writer_method_name }
    
    begin
      logger.debug { "Starting the response" }
      
      bytes_written = 0
      
      started_proc.call(bytes_written)
      
      stream.each_file do | file |
        logger.debug { "Sending %s" % file.inspect }
        # Run the sending method, depending on the implementation
        send(writer_method_name, socket, file) do |n_bytes_sent|
          bytes_written += n_bytes_sent
          logger.debug { "Written %d bytes" % bytes_written }
          written_proc.call(n_bytes_sent, bytes_written)
        end
      end
      
      logger.info { "Response written in full - %d bytes" % bytes_written }
      done_proc.call(bytes_written)
    rescue *CLIENT_DISCONNECT_EXCEPTIONS => e
      logger.warn { "Client closed connection: #{e.class}(#{e.message})" }
      aborted_proc.call(e)
    rescue Exception => e
      logger.fatal { "Aborting response due to error: #{e.class}(#{e.message}) and will propagate" }
      aborted_proc.call(e)
      error_proc.call(e)
      raise e unless StandardError === e # Re-raise system errors, signals and other Exceptions
    ensure
      # With rack.hijack the consensus seems to be that the hijack
      # proc is responsible for closing the socket. We also use no-keepalive
      # so this should not pose any problems.
      socket.close unless socket.closed?
      logger.debug { "Performing cleanup" }
      cleanup_proc.call(bytes_written)
    end
  end

  # This is majorly useful - if the socket is not selectable after a certain
  # timeout, it might be a slow loris or a connection that hung up on us. So if
  # the return from select() is nil, we know that we still cannot write into
  # the socket for some reason. Kill the request, it is dead, jim.
  #
  # Note that this will not work on OSX due to a sendfile() bug.
  def fire_timeout_using_select(writable_socket)
    started_polling_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    select_timeout_secs = 0.25
    sleep_after_select_timeout_secs = 0.5
    loop do
      socket_or_nil = writable_socket.wait_writable(SELECT_TIMEOUT_ON_BLOCK)
      return if socket_or_nil # socket became writable
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if (now - started_polling_at) > SOCKET_TIMEOUT
        raise SlowLoris, "Receiving socket timed out on sendfile(), probably a dead slow loris"
      end
      sleep(sleep_after_select_timeout_secs)
    end
  end

  # Copies the file to the socket using sendfile().
  # If we are not running on Darwin we are going to use a non-blocking version of
  # sendfile(), and send the socket into a select() wait loop. If no data can be written
  # after 3 minutes the request will be terminated.
  # On Darwin a blocking sendfile() call will be used instead.
  #
  # @param socket[Socket] the socket to write to
  # @param file[File] the IO you can read from
  # @yields num_bytes_written[Integer] the number of bytes written on each `IO.copy_stream() call`
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
        return # We are done, nil == EOF
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
  # @yields num_bytes_written[Integer] the number of bytes written on each `IO.copy_stream() call`
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
  #
  # @param socket[Socket] the socket to write to
  # @param file[File] the IO you can read from
  # @yields num_bytes_written[Integer] the number of bytes written on each `IO.copy_stream() call`
  # @return [void]
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