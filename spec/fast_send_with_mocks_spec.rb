require_relative '../lib/fast_send'
require 'logger'
require 'tempfile'

describe 'FastSend when used with a mock Socket' do
  let(:logger) {
    Logger.new(nil).tap{|l| l.level = Logger::DEBUG }
  }
  let(:described_class) { FastSend }
  
  class FakeSocket
    def initialize(with_output)
      @out = with_output
    end
    
    def closed?
      !!@closed
    end
    
    def close
      @closed = true
    end
    
    def write(data)
      raise 'closed' if @closed
      @out << data
      data.bytesize
    end
  end
  
  class FakeSocketWithSendfile < FakeSocket
    def sendfile(file, read_at_offset, send_this_time)
      raise 'closed' if @closed
      file.pos = read_at_offset
      @out << file.read(send_this_time)
      send_this_time 
    end
    
    def trysendfile(file, read_at_offset, send_this_time)
      raise 'closed' if @closed
      file.pos = read_at_offset
      @out << file.read(send_this_time)
      send_this_time
    end
    
    undef :write
  end
  
  class EachFileResponse
    def each_file
      f1 = Tempfile.new('x').tap{|f| 64.times{ f << Random.new.bytes(1024 * 1024)}; f.flush; f.rewind }
      f2 = Tempfile.new('x').tap{|f| 54.times{ f << Random.new.bytes(1024 * 1024)}; f.flush; f.rewind }
      yield f1
      yield f2
    end
  end
  
  class FailingResponse
    def initialize(err_class = RuntimeError)
      @err = err_class
    end
    
    def each_file
      raise @err.new("This should not happen")
    end
  end
  
  it 'returns the upstream response with a response that does not support each_file' do
  
    app = ->(env) { [200, {}, ["Hello"]] }
    
    handler = described_class.new(app)
    res = handler.call({})
    expect(res[0]).to eq(200)
    expect(res[2]).to eq(["Hello"])
  end
  
  context 'within a server that has no hijack support (using NaiveEach)' do
    it 'sets the X-Fast-Send-Dispatch header to "each"' do
      source_size = (64 + 54) * 1024 * 1024
      app = ->(env) { [200, {}, EachFileResponse.new] }
      handler = described_class.new(app)
      
      s, h, b = handler.call({})
      expect(h['X-Fast-Send-Dispatch']).to eq('each')
    end
    
    it 'returns a naive each wrapper' do
      source_size = (64 + 54) * 1024 * 1024
      app = ->(env) { [200, {}, EachFileResponse.new] }
      handler = described_class.new(app)
      
      s, h, b = handler.call({})
      expect(s).to eq(200)
      
      tf = Tempfile.new('out')
      b.each{|data| tf << data }
      expect(tf.size).to eq((64 + 54) * 1024 * 1024)
    end
    
    it 'executes the aborted callback, the error callback and the cleanup callback if the response raises during reads' do
      source_size = (64 + 54) * 1024 * 1024
      aborted_cb = ->(e) { expect(e).to be_kind_of(StandardError) }
      error_cb = ->(e) { expect(e).to be_kind_of(StandardError) }
      cleanup_cb = ->(sent) { expect(sent).to be_zero }
      
      app = ->(env) {
        [200, {'fast_send.aborted' => aborted_cb, 'fast_send.error' => error_cb, 'fast_send.cleanup' => cleanup_cb},
          FailingResponse.new]
      }
      
      handler = described_class.new(app)
      
      s, h, b = handler.call({})
      expect(s).to eq(200)
      expect(h.keys.grep(/fast\_send/)).to be_empty
      
      expect(error_cb).to receive(:call)
      expect(aborted_cb).to receive(:call)
      expect(cleanup_cb).to receive(:call)
      
      tf = Tempfile.new('out')
      expect {
        b.each{|data| tf << data }
      }.to raise_error(RuntimeError)
    end
    
    it 'executes the aborted callback and the cleanup callback, but not the error callback on an EPIPE' do
      source_size = (64 + 54) * 1024 * 1024
      aborted_cb = ->(e) { expect(e).to be_kind_of(StandardError) }
      error_cb = ->(e) { raise "Should never be called" }
      cleanup_cb = ->(sent) { expect(sent).to be_zero }
      
      app = ->(env) { [200, {'fast_send.aborted' => aborted_cb, 'fast_send.error' => error_cb, 'fast_send.cleanup' => cleanup_cb},
          FailingResponse.new(Errno::EPIPE)] }
      
      handler = described_class.new(app)
      
      s, h, b = handler.call({})
      expect(s).to eq(200)
      expect(h.keys.grep(/fast\_send/)).to be_empty
      
      expect(error_cb).not_to receive(:call)
      expect(aborted_cb).to receive(:call)
      expect(cleanup_cb).to receive(:call)
      
      tf = Tempfile.new('out')
      b.each{|data| tf << data } # Raises an exception but it gets suppressed
    end
    
    it 'executes the bytes sent callback on each send of 64 kilobytes' do
      source_size = (64 + 54) * 1024 * 1024
      
      callbacks = []
      sent_cb = ->(written, total_so_far) { callbacks << [written, total_so_far] }
      
      app = ->(env) { [200, {'fast_send.bytes_sent' => sent_cb},
          EachFileResponse.new] }
      
      handler = described_class.new(app)
      
      s, h, b = handler.call({})
      
      expect(s).to eq(200)
      expect(h.keys.grep(/fast\_send/)).to be_empty
      
      b.each{|data| }
      
      expect(callbacks).not_to be_empty
      expect(callbacks.length).to eq(1888)
    end
  end
  
  it 'raises about an unknown callback in the response headers if it finds one' do
    app = ->(env) { [200, {'fast_send.mistyped_header'=> Proc.new{} }, EachFileResponse.new] }
    handler = described_class.new(app)
    
    expect {
      handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    }.to raise_error(/Unknown callback \"fast_send\.mistyped\_header\"/)
  end
  
  it 'sets the X-Fast-Send-Dispatch header to "hijack"' do
    source_size = (64 + 54) * 1024 * 1024
    app = ->(env) { [200, {}, EachFileResponse.new] }
    
    handler = described_class.new(app)
    
    status, headers, body = handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    expect(headers['X-Fast-Send-Dispatch']).to eq('hijack')
  end
  
  it 'sends the files to the socket using sendfile()' do
    source_size = (64 + 54) * 1024 * 1024
    app = ->(env) { [200, {}, EachFileResponse.new] }
    
    handler = described_class.new(app)
    
    status, headers, body = handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    output = Tempfile.new('response_body')
    
    fake_socket = FakeSocketWithSendfile.new(output)
    if described_class::SocketHandler::USE_BLOCKING_SENDFILE
      expect(fake_socket).to receive(:sendfile).at_least(:once).and_call_original
    else
      expect(fake_socket).to receive(:trysendfile).at_least(:once).and_call_original
    end
    
    # The socket MUST get closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
    
    expect(output.size).to eq(source_size)
  end
  
  it 'sends the files to the socket using write()' do
    source_size = (64 + 54) * 1024 * 1024
    app = ->(env) { [200, {}, EachFileResponse.new] }
    
    handler = described_class.new(app)
    
    status, headers, body = handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    output = Tempfile.new('response_body')
    
    fake_socket = FakeSocket.new(output)
    # The socket MUST get closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
    
    expect(output.size).to eq(source_size)
  end

  it 'calls the cleanup proc even if the socket enters the handler in a closed state' do
    source_size = (64 + 54) * 1024 * 1024
    cleanup_proc = double('Cleanup')
    app = ->(env) { [200, {'fast_send.cleanup' => cleanup_proc}, EachFileResponse.new] }
    
    handler = described_class.new(app)
    
    status, headers, body = handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    output = Tempfile.new('response_body')
    
    already_closed_socket = FakeSocket.new(output)
    already_closed_socket.close

    hijack = headers.fetch('rack.hijack')

    # The cleanup proc gets called with the number of bytes transferred
    expect(cleanup_proc).to receive(:call).with(0)
    hijack.call(already_closed_socket)
  end
  
  it 'can execute the hijack proc twice without resending the data' do
    source_size = (64 + 54) * 1024 * 1024
    app = ->(env) { [200, {}, EachFileResponse.new] }
    
    handler = described_class.new(app)
    
    status, headers, body = handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    output = Tempfile.new('response_body')
    
    fake_socket = FakeSocket.new(output)
    # The socket MUST get closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    
    hijack.call(fake_socket)
    hijack.call(fake_socket)
  end
  
  it 'sets up the hijack proc and sends the file to the socket using write()' do
    source_size = (64 + 54) * 1024 * 1024
    app = ->(env) { [200, {}, EachFileResponse.new] }
    
    handler = described_class.new(app)
    
    status, headers, body = handler.call({'rack.hijack?' => true, 'rack.logger' => logger})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    output = Tempfile.new('response_body')
    
    fake_socket = FakeSocketWithSendfile.new(output)
    # The socket MUST get closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
    
    expect(output.size).to eq(source_size)
  end
  
  it 'calls all the supplied callback procs set in the headers' do
    source_size = (64 + 54) * 1024 * 1024
    callbacks = []
    
    app = ->(env) {
      [200, {
        'fast_send.started' => ->(b){ callbacks << [:started, b] },
        'fast_send.complete' => ->(b){ callbacks << [:complete, b] },
        'fast_send.bytes_sent' => ->(now, total) { callbacks << [:bytes_sent, now, total] },
        'fast_send.cleanup' => ->(b){ callbacks << [:cleanup, b] },
      }, EachFileResponse.new]
    }
    
    handler = described_class.new(app)
    status, headers, body = handler.call({'rack.hijack?' => true})
    
    keys = headers.keys
    expect(keys.grep(/fast\_send/)).to be_empty # The callback headers should be removed
    
    expect(status).to eq(200)
    expect(body).to eq([])
    
    fake_socket = double('Socket')
    
    allow(fake_socket).to receive(:respond_to?).with(:sendfile) { false }
    allow(fake_socket).to receive(:respond_to?).with(:to_path) { false } # called by IO.copy_stream
    
    expect(fake_socket).to receive(:closed?) { false }
    allow(fake_socket).to receive(:write) {|data| data.bytesize }
    
    expect(fake_socket).to receive(:closed?) { false }
    expect(fake_socket).to receive(:close) # The socket MUST be closed at the end of hijack
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
    
    expect(callbacks.length).to eq(62)
    
    expect(callbacks[0]).to eq([:started, 0])
    expect(callbacks[-2]).to eq([:complete, 123731968])
    expect(callbacks[-1]).to eq([:cleanup, 123731968])
    
    bytes_sent_cbs = callbacks[1..-3]
    bytes_sent_cbs.each_with_index do | c, i |
      expect(c[1]).to be_kind_of(Integer)
      expect(c[2]).to be_kind_of(Integer)
    end
  end
  
  it 'closes the socket even when the cleanup proc raises' do
    source_size = (64 + 54) * 1024 * 1024
    callbacks = []
    
    app = ->(env) {
      [200, {
        'fast_send.cleanup' => ->(b){ raise "Failed when executing the cleanup callbacks" },
      }, EachFileResponse.new]
    }
    
    handler = described_class.new(app)
    status, headers, body = handler.call({'rack.hijack?' => true})
    
    keys = headers.keys
    expect(keys.grep(/fast\_send/)).to be_empty # The callback headers should be removed
    
    expect(status).to eq(200)
    expect(body).to eq([])
    
    fake_socket = double('Socket')
    
    allow(fake_socket).to receive(:respond_to?).with(:sendfile) { false }
    allow(fake_socket).to receive(:respond_to?).with(:to_path) { false } # called by IO.copy_stream
    
    expect(fake_socket).to receive(:closed?) { false }
    allow(fake_socket).to receive(:write) {|data| data.bytesize }
    
    expect(fake_socket).to receive(:closed?) { false }
    expect(fake_socket).to receive(:close) # The socket MUST be closed at the end of hijack
    
    hijack = headers.fetch('rack.hijack')
    expect {
      hijack.call(fake_socket)
    }.to raise_error(/Failed when executing the cleanup callback/)
  end
  
  it 'passes the exception to the fast_send.error proc' do
    source_size = (64 + 54) * 1024 * 1024
    
    error_proc = ->(e){ expect(e).to be_kind_of(RuntimeError) }
    expect(error_proc).to receive(:call).and_call_original
    
    app = ->(env) {
      [200, {
        'Content-Length' => source_size.to_s,
        'fast_send.error' => error_proc,
      }, FailingResponse.new]
    }
    
    handler = described_class.new(app)
    status, headers, body = handler.call({'rack.hijack?' => true})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    fake_socket = FakeSocketWithSendfile.new(Tempfile.new('tt'))
    # The socket MUST be closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
  end
  
  it 'does not pass an EPIPE to the fast_send.error proc' do
    source_size = (64 + 54) * 1024 * 1024
    
    error_proc = ->(*){ throw :no }
    expect(error_proc).not_to receive(:call)
    
    app = ->(env) {
      [200, {
        'Content-Length' => source_size.to_s,
        'fast_send.error' => error_proc,
      }, FailingResponse.new(Errno::EPIPE)]
    }
    
    handler = described_class.new(app)
    status, headers, body = handler.call({'rack.hijack?' => true})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    fake_socket = FakeSocketWithSendfile.new(Tempfile.new('tt'))
    # The socket MUST be closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
  end
  
  it 'passes the exception to the fast_send.aborted proc' do
    source_size = (64 + 54) * 1024 * 1024
    
    abort_proc = ->(e){ expect(e).to be_kind_of(RuntimeError) }
    expect(abort_proc).to receive(:call).and_call_original
    
    app = ->(env) {
      [200, {
        'Content-Length' => source_size.to_s,
        'fast_send.aborted' => abort_proc,
      }, FailingResponse.new]
    }
    
    handler = described_class.new(app)
    status, headers, body = handler.call({'rack.hijack?' => true})
    expect(status).to eq(200)
    expect(body).to eq([])
    
    fake_socket = FakeSocketWithSendfile.new(Tempfile.new('tt'))
    # The socket MUST be closed at the end of hijack
    expect(fake_socket).to receive(:close).and_call_original
    
    hijack = headers.fetch('rack.hijack')
    hijack.call(fake_socket)
  end
  
  it 'halts the response when the socket times out in IO.select'
  it 'halts the response when the socket errors in IO.select'
end
