require './lib/fast_send'

THE_F = '/Users/julik/Downloads/3gb.bin'
SEND_TIMES = 10

class TheBody
  def each_file(&b)
    SEND_TIMES.times { File.open(THE_F, 'rb', &b) }
  end
end

app = ->(env) {
  size = File.size(THE_F) * SEND_TIMES
  [200, {'Content-Length' => size.to_s}, TheBody.new]
}

run FastSend.new(app)