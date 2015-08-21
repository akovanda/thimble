require 'thread'
require_relative 'lib/ProcessManager.rb'
require_relative 'lib/ProcessingWork.rb'
require_relative 'lib/Workload.rb'
require_relative 'lib/WorkResult.rb'
require_relative 'lib/Thimble.rb'
require_relative 'lib/Context.rb'

class T 
  include Thimble

  def initialize
    Thimble.prep(context: Context.deterministic)
    a = [1,2,3,4,5,6]
    b = Thimble.map(a) do |x|
      x + 1
    end

    
  end
end

test = T.new



workQueue = Queue.new
mapQueue = Queue.new
count = 1
workSize = 1
workerMax = 1
workload = count/workSize
workload.times {|x| workQueue << Workload.new(x*workSize,(workSize-1)+(x*workSize),workSize)}
puts "Work Count: #{workQueue.length} "
manager = ProcessManager.new(workerMax, workSize, workQueue, mapQueue)
startTime = Time.now
#resQueue = manager.process
resArr = []
while !resQueue.empty?
  resArr<<Marshal.dump(resQueue.pop)
  print "Dumped.. #{((workload-resQueue.length).to_f/workload)*100.round(2)}  \r"
end
print "\n"

File.open('marshalTest.txt', 'w') do |f|
  f.puts resArr
end
endTime = Time.now
puts "Time: #{endTime-startTime}"

