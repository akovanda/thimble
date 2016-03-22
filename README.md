# Thimble
Thimble is a ruby gem for parallelism and concurrency.  It allows you to decide if you want to use separate processes, or if you want to use threads in ruby.  
____
### Example 1
```
  require 'thimble'
    
  manager = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
  thimble = Thimble::Thimble.new((1..100).to_a, manager)
  results = thimble.map do |x|
    x * 1000
  end 

```
#### Example 2
```
require 'thimble'
# We create a queue to store intermediate work
queue = Thimble::ThimbleQueue.new(3, "stage 2")
# Our array of data
ary = (1 .. 10).to_a
# A separate thread worker who will be processing the intermediate queue
thread = Thimble::Thimble.a_sync do
  queue.each {|x| puts "I did work on #{x}!"; sleep 1}
end
# Our Thimble, plus it's manager.  Note we are using Thread in this example.
thim = Thimble::Thimble.new(ary, Thimble::Manager.new(batch_size: 1, worker_type: :thread))
# We in parallel push data to the thimble array
thim.map { |e| queue.push(e); sleep 3; puts "I pushed #{e} to the queue!" }
#I pushed 1 to the queue!
#I did work on 1!
#I pushed 5 to the queue!
#I pushed 3 to the queue!
#I pushed 2 to the queue!
#I did work on 5!
#I pushed 9 to the queue!
#I did work on 3!
#I pushed 8 to the queue!
#I did work on 2!
#I pushed 10 to the queue!
#I did work on 9!
#I pushed 6 to the queue!
#I did work on 8!
#I pushed 4 to the queue!
#I did work on 10!
#I pushed 7 to the queue!
#I did work on 6!
#I did work on 4!
#I did work on 7!
# The queue is closed (no more work can come in)
queue.close
# join the thread
thread.join
```

You must pass an explicit manager to your thimble.  They can be used in multiple thimbles at the same time.  

batch_size is how many chunks of work you will send with the worker.
