require File.dirname(__FILE__) + '/../lib/fast_send'

require 'bundler'
Bundler.require(:development)

TF = Tempfile.new('xx')
TF.binmode
64.times { TF << Random.new.bytes(1024*1024) }
TF.flush
TF.rewind

use FastSend

class Eacher
  def each_file
    yield(TF)
  ensure
    TF.rewind
  end
end

run ->(env) {
  [200, {'Content-Length' => TF.size.to_s, 'X-Source-Path' => TF.path}, Eacher.new]
}