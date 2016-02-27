# FastSend

Is a Rack middleware to send large, long-running Rack responses via _file buffers._
When you send a lot of data, you can saturate the Ruby GC because you have to pump
strings to the socket through the runtime. If you already have a file handle with
the contents that you want to send, you can let the operating system do the socket
writes at optimum speed, without loading your Ruby VM with all the string
cleanup. This helps to reduce GC pressure, CPU use and memory use.

## Usage

FastSend is a Rack middleware. Insert it before your application.

    use FastSend

In normal circumstances FastSend will just do nothing. You have to explicitly trigger it
by returning a special response body object. The convention is that this object must respond
to `each_file` instead of the standard Rack `each`. Note that you _must_ return a real Ruby `File`
object or it's subclass, because some fairly low-level operations will be done to it - so a duck-typed
"file-like" object is not good enough.

    class BigResponse
      def each_file
        File.open('/large_file.bin', 'rb'){|fh| yield(fh) }
      end
    end
    
    # and in your application
    [200, {'Content-Length' => big_size}, BigResponse.new]

The response object must yield File objects from that method. It is possible to yield an unlimited
number of files, they will all be sent to the socket in succession. The `yield` will block
for as long as the file is not sent in full.

## Bandwidth metering and callbacks

Because FastSend uses Rack hijacking, it takes the usual Rack handling out of the response writing.
So you can effectively do two things if you want to have wrapping actions performed at the start of
the download, or at the end of the download, or at an abort:

* Make use of the custom fast_send headers. They will be removed by the middleware
* Add the method calls to your `each_file` method, using `ensure` and `rescue`

For example, to receive a callback every time some bytes get sent to the client
  
    bytes_sent_proc = ->(sent,written_so_far_entire_response) {
      bandwith_metering.increment(sent)
    }
    
    [200, {'fast_send.bytes_sent' => bytes_sent_proc}, large_body]

There are also more callbacks you can use, read the class documentation for more information on them.
For example, you can subscribe to a callback when the client suddenly disconnects - you will get an idea
of how much data the client could read/buffer so far before the connection went down.

## Implementation details

Fundamentally, FastSend takes your Ruby File handles, one by one (you can `yield` multiple times from `each_file`)
and uses the fastest way possible, as available in your Ruby runtime, to send the file to the Rack webserver socket.
The options it tries are:

* non-blocking `sendfile(2)` call - if you have the "sendfile" gem, only on MRI/Rubinius, only on Linux
* blocking `sendfile(2)` call - if you have the "sendfile" gem, only on MRI/Rubinius, also works on OSX
* Java's NIO transferTo() call - if you are on jRuby
* IO.copy_stream() for all other cases

For the "sendfile" gem to work you need to add it to your application and `require` it before FastSend
has to dispatch a request (you do not have to `require` these two in a particular order).

## Webserver compatibility

Your webserver (Rack adapter) _must_ support partial Rack hijacking. We use FastSend on Puma pretty much
exclusively, and it works well. Note that WebBrick only supports partial hijacking using a self-pipe, which
is not compatible with the socket operations in FastSend. Just like we require _real_ File objects for the
input, we _require_ a real Rack socket (raw TCP) for the output. Sorry 'bout that.

If those preconditions are not met, FastSend will revert to a standard Rack body that just reads your
yielded file into the Ruby runtime and yields it's parts to the caller. It does inflate memory and is
slow, but it helps sometimes

## Without Rack hijacking support or when using rack-test

If you need to test FastSend as part of your application, your custom `each_file`-supporting Body object
will be wrapped with a `FastSend::NaiveEach` in your `rack-test` test case. This way the response will
be read into the Rack client buffer, and will use the standard string-pumping that is used for long Rack
responses. All the callbacks you define for FastSend will work.