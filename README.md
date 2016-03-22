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
# We in parallel push data to the Thimble Queue
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
#### Manager Example
```
	m = Thimble::Manager.new(max_workers: 10, batch_size: 100, worker_type: :fork)
	Thimble::Thimble.new(array, m)

```
The manager uses three variables.
* max_workers.  This tells the manager how many workers are allowed to be running at the same time.
* batch_size. This tells the thimble manager how many items to send to each worker.  This should be tuned for job performance.
* worker_type. Two options here :thread, or :fork.  This tells thimble how to do your work.  Choose wisely here.

The manager can be used in multiple thimbles at the same time, so you can share resources to prevent too many workers from going at the same time in multiple thimbles.  

All thimbles require an explicit manager.  
____

#### ThimbleQueue
 This is the underlying queue that thimble is using.  Taking from it is DESTRUCTIVE.  It is designed to be thread safe, so you can use threads and push and pull data from it.  

 ```
  q = Thimble::ThimbleQueue.new(size: 10, "name")

  # THIS WILL NEVER END.  
  # The queue is "open"
  #q.each {|x| puts x}

  q.push(1)

  q.close

  q.each {|x| puts x}
  # => 1

 ```
 If you do not close the queue will wait for more data to come in.  When you create a thimble you are creating a "closed" queue any transformations will create a NEW Queue
