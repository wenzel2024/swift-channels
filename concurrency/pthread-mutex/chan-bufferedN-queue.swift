//
//  chan-bufferedN-queue.swift
//  concurrency
//
//  Created by Guillaume Lessard on 2014-11-19.
//  Copyright (c) 2014 Guillaume Lessard. All rights reserved.
//

import Darwin

/**
  A channel that uses a N-element queue as a backing store.
*/

final class BufferedQChan<T>: pthreadChan<T>
{
  private final let capacity: Int
  private final var q = AnythingQueue<T>()

  // housekeeping variables

  private final var elements = 0

  // Initialization

  init(_ capacity: Int)
  {
    self.capacity = (capacity < 1) ? 1 : capacity
    super.init()
  }

  convenience override init()
  {
    self.init(1)
  }

  // Computed property accessors

  final override var isEmpty: Bool
  {
    return elements <= 0
//     return q.isEmpty
  }

  final override var isFull: Bool
  {
    return elements >= capacity
//     return q.count >= capacity
  }

  /**
    Append an element to the channel

    If no reader is waiting, this call will block.
    If the channel has been closed, no action will be taken.

    :param: element the new element to be added to the channel.
  */

  override func put(newElement: T)
  {
    if self.closed { return }

    pthread_mutex_lock(channelMutex)
    while (elements >= capacity) && !self.closed
    { // block while channel is full
      blockedWriters += 1
      pthread_cond_wait(writeCondition, channelMutex)
      blockedWriters -= 1
    }

    if !self.closed
    {
      q.enqueue(newElement)
      elements += 1
    }

    // Channel is not empty; signal if appropriate
    if self.closed && blockedWriters > 0
    {
      pthread_cond_signal(writeCondition)
    }
    if blockedReaders > 0
    {
      pthread_cond_signal(readCondition)
    }

    pthread_mutex_unlock(channelMutex)
  }

  /**
    Return the oldest element from the channel.

    If the channel is empty, this call will block.
    If the channel is empty and closed, this will return nil.

    :return: the oldest element from the channel.
  */

  override func get() -> T?
  {
    pthread_mutex_lock(channelMutex)

    while (elements <= 0) && !self.closed
    { // block while channel is empty
      blockedReaders += 1
      pthread_cond_wait(readCondition, channelMutex)
      blockedReaders -= 1
    }

    let oldElement = q.dequeue()
    elements -= 1

    if self.closed && blockedReaders > 0
    {
      pthread_cond_signal(readCondition)
    }
    if blockedWriters > 0
    {
      pthread_cond_signal(writeCondition)
    }

    pthread_mutex_unlock(channelMutex)
    return oldElement
  }
}