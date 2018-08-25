require_relative '../lib/fast_send'
require 'net/http'
require 'tempfile'

describe 'FastSend when used in combination with Puma' do
  before :all do
#   @server = Thread.new {
#     ``
#   }
    command = 'bundle exec puma --port 9293 %s/test_app.ru' % __dir__
    @server_pid = spawn(command)
  end

  it 'offers the file for download, sends the entire file' do
    begin
      require 'sendfile'
    rescue LoadError # jruby et al
    end
    
    tries = 0
    begin
      headers = {}
      uri = URI('http://127.0.0.1:9293')
      conn = Net::HTTP.new(uri.host, uri.port)
      conn.read_timeout = 1
      conn.open_timeout = 1
      conn.start do |http|
        req = Net::HTTP::Get.new(uri.request_uri)
        http.request(req) do |res|
        
          dispatch = res.header['X-Fast-Send-Dispatch']
          expect(dispatch).to eq('hijack')
        
          downloaded_copy = Tempfile.new('cpy')
          downloaded_copy.binmode
          
          res.read_body {|chunk| downloaded_copy << chunk }
          downloaded_copy.rewind
          
          expect(downloaded_copy.size).to eq(res.header['Content-Length'].to_i)
          
          File.open(res.header['X-Source-Path'], 'rb') do |source_file|
            loop do
              pos = source_file.pos
              from_source = source_file.read(5)
              downloaded = downloaded_copy.read(5)
              break if from_source
              expect(downloaded.unpack("C*")).to eq(from_source.unpack("C*"))
            end
          end
        end
      end
    rescue Errno::ECONNREFUSED => e # Puma hasn't started yet
      raise e if (tries += 1) > 100
      sleep 0.5
      retry
    end
  end
  
  after :all do
    Process.kill('TERM', @server_pid)
    Process.wait(@server_pid)
  end
end
