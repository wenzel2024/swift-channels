//
//  Semaphore.swift
//  LightweightSemaphore
//
//  Created by Guillaume Lessard on 2015-04-03.
//  Copyright (c) 2015 Guillaume Lessard. All rights reserved.
//

import Darwin.Mach.task
import Darwin.Mach.semaphore
import Darwin.Mach.mach_time
import Darwin.libkern.OSAtomic
import Dispatch.time

struct SemaphorePool
{
  static private let capacity = 256
  static private let buffer = UnsafeMutablePointer<ChannelSemaphore>.alloc(capacity)
  static private var cursor = 0

  static private var lock = OS_SPINLOCK_INIT

  static func Return(s: ChannelSemaphore)
  {
    OSSpinLockLock(&lock)
    if cursor < capacity
    {
      buffer.advancedBy(cursor).initialize(s)
      cursor += 1
      assert(s.svalue == 0, "Non-zero user-space semaphore count of \(s.svalue) in \(__FUNCTION__)")
    }
    OSSpinLockUnlock(&lock)
  }

  static func Obtain() -> ChannelSemaphore
  {
    OSSpinLockLock(&lock)
    if cursor > 0
    {
      cursor -= 1
      if isUniquelyReferencedNonObjC(&buffer[cursor])
      {
        let s = buffer.advancedBy(cursor).move()
        OSSpinLockUnlock(&lock)
        s.svalue = 0
        s.iptr = nil
        s.currentState = ChannelSemaphoreState.Ready.rawValue
        return s
      }

      // for i in reverse(0..<cursor)
      for var i=cursor-1; i>=0; i--
      {
        if isUniquelyReferencedNonObjC(&buffer[i])
        {
          let s = buffer[i]
          buffer[i] = buffer.advancedBy(cursor).move()
          OSSpinLockUnlock(&lock)
          s.svalue = 0
          s.iptr = nil
          s.currentState = ChannelSemaphoreState.Ready.rawValue
          return s
        }
      }
      cursor += 1
    }
    OSSpinLockUnlock(&lock)
    return ChannelSemaphore(value: 0)
  }
}

// MARK: ChannelSemaphoreState

enum ChannelSemaphoreState: Int32
{
case Ready

// Unbuffered channel data
case Pointer

// End state
case Done
}

// MARK: ChannelSemaphore

/**
  A benaphore: http://www.haiku-os.org/legacy-docs/benewsletter/Issue1-26.html
  Also: http://preshing.com/20120226/roll-your-own-lightweight-mutex/

  Much like dispatch_semaphore_t, with native Swift typing. (And state information.)
  An older version of libdispatch is at: http://libdispatch.macosforge.org/
*/

final public class ChannelSemaphore
{
  private var svalue: Int32
  private var semp = semaphore_t()

  private var currentState = ChannelSemaphoreState.Ready.rawValue
  private var iptr: UnsafeMutablePointer<Void> = nil

  // MARK: init/deinit

  init(value: Int)
  {
    svalue = (value < 0) ? 0 : Int32(min(value, Int(Int32.max)))
  }

  convenience init()
  {
    self.init(value: 0)
  }

  deinit
  {
    if semp != 0
    {
      let kr = semaphore_destroy(mach_task_self_, semp)
      assert(kr == KERN_SUCCESS, __FUNCTION__)
    }
  }

  final private func initSemaphorePort()
  {
    var port = semaphore_t()
    let kr = semaphore_create(mach_task_self_, &port, SYNC_POLICY_FIFO, 0)
    assert(kr == KERN_SUCCESS, __FUNCTION__)

    let success: Bool = { (ptr: UnsafeMutablePointer<UInt32>) -> Bool in
      return OSAtomicCompareAndSwap32Barrier(0, unsafeBitCast(port, Int32.self), UnsafeMutablePointer<Int32>(ptr))
    }(&semp)

    if !success
    { // another initialization attempt succeeded concurrently. Don't leak the port; return it.
      let kr = semaphore_destroy(mach_task_self_, port)
      assert(kr == KERN_SUCCESS, __FUNCTION__)
    }
  }

  // MARK: State Handling

  var rawState: Int32 { return currentState }
  var state: ChannelSemaphoreState { return ChannelSemaphoreState(rawValue: currentState)! }

  func setState(newState: ChannelSemaphoreState) -> Bool
  {
    switch newState
    {
    case .Pointer:
      return OSAtomicCompareAndSwap32Barrier(ChannelSemaphoreState.Ready.rawValue, newState.rawValue, &currentState)

    case .Done:
      // Ideally it would be: __sync_swap(&currentState, ChannelSemaphoreState.Done.rawValue)
      while OSAtomicCompareAndSwap32Barrier(currentState, ChannelSemaphoreState.Done.rawValue, &currentState) == false {}
      return true

    default:
      return false
    }
  }

  // MARK: Data handling

  func setPointer<T>(p: UnsafeMutablePointer<T>)
  {
    pointer = UnsafeMutablePointer(p)
  }

  func getPointer<T>() -> UnsafeMutablePointer<T>
  {
    return UnsafeMutablePointer<T>(pointer)
  }

  var pointer: UnsafeMutablePointer<Void> {
    get {
      if currentState == ChannelSemaphoreState.Pointer.rawValue
      { return iptr }
      else
      { return nil }
    }
    set {
      if currentState == ChannelSemaphoreState.Pointer.rawValue
      { iptr = newValue }
      else
      { iptr = nil }
    }
  }
  
  // MARK: Semaphore functionality

  func signal() -> Bool
  {
    switch OSAtomicIncrement32Barrier(&svalue)
    {
    case let v where v > 0:
      return false

    case Int32.min:
      preconditionFailure("Semaphore signaled too many times")

    default: break
    }

    while semp == 0
    { // if svalue was previously less than zero, there must be a wait() call
      // currently in the process of initializing semp.
      usleep(1)
      OSMemoryBarrier()
    }

    let kr = semaphore_signal(semp)
    assert(kr == KERN_SUCCESS, __FUNCTION__)
    return kr == KERN_SUCCESS
  }

  func wait(timeout: dispatch_time_t) -> Bool
  {
    if OSAtomicDecrement32Barrier(&svalue) >= 0
    {
      return true
    }

    if semp == 0 { initSemaphorePort() }

    var kr: kern_return_t
    switch timeout
    {
    case DISPATCH_TIME_NOW: // will not wait
      kr = semaphore_timedwait(semp, mach_timespec_t())
      assert(kr == KERN_SUCCESS || kr == KERN_OPERATION_TIMED_OUT, __FUNCTION__)

    case DISPATCH_TIME_FOREVER: // will wait forever
      do {
        kr = semaphore_wait(semp)
      } while kr == KERN_ABORTED
      assert(kr == KERN_SUCCESS, __FUNCTION__)

    default: // a timed wait
      do {
        let delta = timeoutDelta(timeout)
        let tspec = mach_timespec_t(tv_sec: UInt32(delta/NSEC_PER_SEC), tv_nsec: Int32(delta%NSEC_PER_SEC))
        kr = semaphore_timedwait(semp, tspec)
      } while kr == KERN_ABORTED
      assert(kr == KERN_SUCCESS || kr == KERN_OPERATION_TIMED_OUT, __FUNCTION__)
   }

    if kr == KERN_OPERATION_TIMED_OUT
    {
      OSAtomicIncrement32Barrier(&svalue)
      return false
    }

    return kr == KERN_SUCCESS
  }

  func wait() -> Bool
  {
    return wait(DISPATCH_TIME_FOREVER)
  }
}

private var scale: mach_timebase_info = {
  var info = mach_timebase_info(numer: 0, denom: 0)
  mach_timebase_info(&info)
  return info
}()

// more or less copied from libdispatch/Source/time.c, _dispatch_timeout()

private func timeoutDelta(time: dispatch_time_t) -> dispatch_time_t
{
  switch time
  {
  case DISPATCH_TIME_FOREVER:
    return DISPATCH_TIME_FOREVER

  case 0: // DISPATCH_TIME_NOW
    return 0

  default:
    let now = mach_absolute_time()*dispatch_time_t(scale.numer)/dispatch_time_t(scale.denom)
    return (time > now) ? (time - now) : 0
  }
}
