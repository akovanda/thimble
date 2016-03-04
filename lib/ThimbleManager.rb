class ThimbleManager
  attr_reader :maxWorkers, :batchSize, :queueSize, :workerType
  def initialize(maxWorkers: 6,batchSize: 1000, queueSize: 1000, workerType: :fork)
    raise "worker type must be either :fork or :thread" unless workerType == :thread || workerType == :fork
    raise "Your system does not respond to fork please use threads." unless workerType == :thread || Process.respond_to?(:fork)
    raise "maxWorkers must be greater than 0" if maxWorkers < 1
    raise "batch size must be greater than 0" if batchSize < 1
    @workerType = workerType
    puts workerType
    puts @workerType
    @maxWorkers = maxWorkers
    @batchSize = batchSize
    @queueSize = queueSize
    @currentWorkers = []
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
    thread = Thread.new do
      batch.item.map do |item|
        yield item.item
      end
    end
  end

  def manageWork(batches)
    if @workerType == :thread
      manageThreadWork(batches)
    else
      manageForkWork(batches)
    end
  end

  def createWorkers(batch)
    
  end

  def manageThreadWork(batches)
    
  end

  def manageForkWork(batches)
    while (@currentWorkers.size < @maxWorkers && batch = getBatch)
      @currentWorkers << getWorker(batch, &Proc.new)
    end
      @currentWorkers.each do |tup|
        while tup.reader.ready?
          t = tup.reader.read
          @result.push(Marshal.load(t))
          Process.kill("HUP", tup.pid)
          @currentWorkers.delete(tup)
        end
      end
  end

  def self.deterministic
    self.new(maxWorkers: 1, batchSize: 1, queueSize: 1)
  end

  def self.small
    self.new(maxWorkers: 1, batchSize: 3, queueSize: 3)
  end
end