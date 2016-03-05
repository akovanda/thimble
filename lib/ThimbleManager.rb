class ThimbleManager
  attr_reader :maxWorkers, :batchSize, :queueSize, :workerType, :currentWorkers
  def initialize(maxWorkers: 6,batchSize: 1000, queueSize: 1000, workerType: :fork)
    raise "worker type must be either :fork or :thread" unless workerType == :thread || workerType == :fork
    raise "Your system does not respond to fork please use threads." unless workerType == :thread || Process.respond_to?(:fork)
    raise "maxWorkers must be greater than 0" if maxWorkers < 1
    raise "batch size must be greater than 0" if batchSize < 1
    @workerType = workerType
    @maxWorkers = maxWorkers
    @batchSize = batchSize
    @queueSize = queueSize
    @currentWorkers = []
  end

  def workerAvailable?
    @currentWorkers.size < @maxWorkers
  end

  def working?
    @currentWorkers.size > 0
  end

  def subWorker(worker)
    raise "Worker must contain a pid!" if worker.pid.nil?
    @currentWorkers << worker
  end

  def remWorker(worker)
    @currentWorkers.delete(worker)
  end

  def getWorker (batch)
    if @workerType == :fork
      getForkWorker(batch, &Proc.new)    
    else
      getThreadWorker(batch, &Proc.new)
    end
  end

  def getForkWorker(batch)
    rd, wr = IO.pipe
    tup = OpenStruct.new
    pid = fork do
      Signal.trap("HUP") {exit}
      rd.close 
      t = Marshal.dump(batch.item.map do |item|
        yield (item.item)
      end)
      wr.write(t)
      wr.close
    end
    wr.close
    tup.pid = pid
    tup.reader = rd
    tup
  end

  def getThreadWorker(batch)
    tup = OpenStruct.new
    tup.pid = Thread.new do
      tup.result = batch.item.map do |item|
        yield item.item
      end
      tup.done = true
    end
    tup
  end

  def self.deterministic
    self.new(maxWorkers: 1, batchSize: 1, queueSize: 1)
  end

  def self.small
    self.new(maxWorkers: 1, batchSize: 3, queueSize: 3)
  end
end