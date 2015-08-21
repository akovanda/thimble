require 'thread'
require 'io/wait'

rd, wr = IO.pipe
rd2, wr2 = IO.pipe

fork do
  rd.close
  wr.puts "Hello"
  puts "in fork #{rd2.gets}"
end
sleep 1
wr.close
puts rd.gets
wr2.puts "hi back at ya"