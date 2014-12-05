require 'thread'
require 'io/wait'

class ProcessManager
  def initialize(workerMax, chunk, workQueue, resultQueue)
    @workerMax = workerMax
    @chunk = chunk
    @workQueue = workQueue
    @resultQueue = resultQueue
    @pidPipe = {}
    @workMax = workQueue.length
    @workMax.freeze
  end

  # This will work through all of the workload before it hands control back
  # to the driver.
  def process
    while @resultQueue.length != @workMax
      while @pidPipe.length <= @workerMax && !@workQueue.empty?
        launchWorker(@workQueue.pop) unless @workQueue.empty?
      end
      @pidPipe.each do |pid, rd|
        if rd.ready?
          @resultQueue<<Marshal.load(rd.read)
          rd.close
          @pidPipe.delete(pid)
        end
      end
      print "Completed: #{((@resultQueue.length.to_f/@workMax)*100).round(2)}% \r"
    end
    print "\n"
    puts @resultQueue.length
    @resultQueue
  end

  # Takes a workload with a class and start method and puts it into it's own thread.
  def launchWorker(work)
    puts (work.methods.include? :className && work.methods.include? :start)
    if work.methods.include? :className && (work.methods.include? :start)
      raise "There was a missing method in the workload #{p work}"
    end
    rd, wr = IO.pipe
    pid = fork do
      # Instantiate the object based on the name of the workload class method.
      worker = Object.const_get(work.className).new(work, wr)
      worker.start
    end
    wr.close
    @pidPipe[pid] = rd
  end

end
