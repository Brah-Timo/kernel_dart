/// Preemptive multi-task scheduler for the kernel_dart microkernel.
///
/// Supports:
///   • Priority-based scheduling (0 = lowest, 255 = highest)
///   • Round-Robin within the same priority class
///   • Task sleep / wake-up
///   • Inter-task message passing (simple mailbox model)
///   • Context-switch accounting (simulated; real switch in Assembly)
library;

import 'dart:collection';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TaskState
// ─────────────────────────────────────────────────────────────────────────────

/// Lifecycle state of a kernel task.
enum TaskState {
  ready,       // In the ready queue, waiting to run
  running,     // Currently on the CPU
  sleeping,    // Waiting for a timer wake-up
  blocked,     // Waiting for an event / message
  terminated,  // Finished execution
}

// ─────────────────────────────────────────────────────────────────────────────
// Task
// ─────────────────────────────────────────────────────────────────────────────

/// A schedulable unit of execution.
final class Task {
  static int _nextId = 1;

  /// Unique task identifier.
  final int id;

  /// Human-readable name (for debugging).
  final String name;

  /// Callable invoked on each scheduler tick.
  final void Function() function;

  /// Priority (0–255; higher = runs first).
  int priority;

  /// Current lifecycle state.
  TaskState state;

  /// Simulated stack pointer (physical address).
  int stackPointer;

  /// Simulated program counter (physical address).
  int? pc;

  /// Absolute tick at which a sleeping task should wake.
  int? wakeUpTick;

  /// Number of CPU ticks consumed by this task.
  int cpuTicks;

  /// Mailbox for inter-task messages.
  final Queue<Object> mailbox;

  Task({
    required this.name,
    required this.function,
    this.priority    = 0,
    this.stackPointer = 0,
    this.state       = TaskState.ready,
  })  : id       = _nextId++,
        cpuTicks = 0,
        mailbox  = Queue<Object>();

  @override
  String toString() =>
      'Task(id=$id, name="$name", priority=$priority, state=${state.name})';
}

// ─────────────────────────────────────────────────────────────────────────────
// SchedulerStats
// ─────────────────────────────────────────────────────────────────────────────

/// Scheduler performance snapshot.
final class SchedulerStats {
  final int totalTasks;
  final int readyTasks;
  final int sleepingTasks;
  final int blockedTasks;
  final int terminatedTasks;
  final int contextSwitches;
  final int currentTick;

  const SchedulerStats({
    required this.totalTasks,
    required this.readyTasks,
    required this.sleepingTasks,
    required this.blockedTasks,
    required this.terminatedTasks,
    required this.contextSwitches,
    required this.currentTick,
  });

  @override
  String toString() =>
      'SchedulerStats(total=$totalTasks, ready=$readyTasks, '
      'sleeping=$sleepingTasks, blocked=$blockedTasks, '
      'switches=$contextSwitches, tick=$currentTick)';
}

// ─────────────────────────────────────────────────────────────────────────────
// SchedulingPolicy
// ─────────────────────────────────────────────────────────────────────────────

/// Determines which task runs next.
enum SchedulingPolicy {
  /// Simple round-robin — no priorities.
  roundRobin,

  /// Priority-based; round-robin within each priority level.
  priorityBased,

  /// Completely Fair Scheduler — tasks with least CPU time run first.
  cfs,
}

// ─────────────────────────────────────────────────────────────────────────────
// TaskScheduler
// ─────────────────────────────────────────────────────────────────────────────

/// Preemptive multi-task scheduler.
///
/// ```dart
/// final sched = TaskScheduler.instance;
///
/// sched.addTask('blink', () => gpio.blinkLED(17), priority: 5);
/// sched.addTask('sensor', () => readSensor(), priority: 10);
///
/// // Called by timer ISR on every tick
/// sched.tick();
/// ```
final class TaskScheduler {
  // ─── Singleton ─────────────────────────────────────────────────────────────

  static TaskScheduler? _instance;

  static TaskScheduler get instance {
    _instance ??= TaskScheduler._();
    return _instance!;
  }

  // ─── State ─────────────────────────────────────────────────────────────────

  final List<Task> _allTasks         = [];
  final List<Task> _readyQueue       = [];
  final List<Task> _sleepingTasks    = [];
  final List<Task> _blockedTasks     = [];

  Task? currentTask;
  int _tick              = 0;
  int _contextSwitches   = 0;
  SchedulingPolicy policy = SchedulingPolicy.priorityBased;

  static final _log = Logger('TaskScheduler');

  TaskScheduler._();

  // ─── Task management ──────────────────────────────────────────────────────

  /// Create and enqueue a new task.
  ///
  /// [stackSize] is the size (in bytes) of the simulated stack.
  Task addTask(
    String name,
    void Function() taskFunction, {
    int priority  = 0,
    int stackSize = 8192,
  }) {
    final task = Task(
      name:         name,
      function:     taskFunction,
      priority:     priority,
      stackPointer: _allocateStack(stackSize),
    );
    _allTasks.add(task);
    _enqueue(task);

    _log.info('addTask: $task');
    return task;
  }

  /// Remove a task by ID.
  void removeTask(int taskId) {
    final task = _findById(taskId);
    if (task == null) return;

    task.state = TaskState.terminated;
    _readyQueue.remove(task);
    _sleepingTasks.remove(task);
    _blockedTasks.remove(task);
    _log.info('removeTask: $task');
  }

  // ─── Scheduler tick ───────────────────────────────────────────────────────

  /// Called by the timer ISR on every hardware timer interrupt.
  ///
  /// Performs:
  ///   1. Tick counter increment
  ///   2. Wake up sleeping tasks whose timer has expired
  ///   3. Pre-empt the current task if it has consumed its quantum
  ///   4. Context switch to the next task
  void tick() {
    _tick++;

    // Wake sleeping tasks
    _wakeExpiredTasks();

    // Pre-emptive context switch every tick (quantum = 1 tick for simplicity)
    _contextSwitch();
  }

  /// Advance the scheduler by [ticks] ticks (useful for testing).
  @visibleForTesting
  void advanceTicks(int ticks) {
    for (var i = 0; i < ticks; i++) tick();
  }

  // ─── Blocking primitives ──────────────────────────────────────────────────

  /// Put the calling task to sleep for [duration].
  ///
  /// In a real kernel this would be called from within a task's function
  /// and would yield the CPU until the timer fires.
  void sleepTask(Task task, Duration duration) {
    final ticks   = _durationToTicks(duration);
    task.state    = TaskState.sleeping;
    task.wakeUpTick = _tick + ticks;
    _readyQueue.remove(task);
    _sleepingTasks.add(task);
    _log.fine('sleepTask: $task wakes at tick ${task.wakeUpTick}');
  }

  /// Block [task] waiting for an event.
  void blockTask(Task task) {
    task.state = TaskState.blocked;
    _readyQueue.remove(task);
    _blockedTasks.add(task);
    _log.fine('blockTask: $task');
  }

  /// Unblock [task] (wake it from a blocked state).
  void unblockTask(Task task) {
    if (task.state != TaskState.blocked) return;
    _blockedTasks.remove(task);
    _enqueue(task);
    _log.fine('unblockTask: $task');
  }

  // ─── Inter-task messaging ─────────────────────────────────────────────────

  /// Send [message] to [task]'s mailbox.
  ///
  /// If [task] was blocked waiting for a message, it is unblocked.
  void sendMessage(Task task, Object message) {
    task.mailbox.addLast(message);
    if (task.state == TaskState.blocked) unblockTask(task);
    _log.fine('sendMessage → Task(${task.name}): $message');
  }

  /// Receive the next message from the current task's mailbox.
  ///
  /// Blocks the current task if the mailbox is empty.
  Object? receiveMessage({Task? fromTask}) {
    final task = fromTask ?? currentTask;
    if (task == null) return null;

    if (task.mailbox.isEmpty) {
      blockTask(task);
      return null;
    }

    return task.mailbox.removeFirst();
  }

  // ─── Convenience aliases ─────────────────────────────────────────────────

  /// Shorthand for [getStats] — returns a scheduler statistics snapshot.
  SchedulerStats stats() => getStats();

  /// Put the task with [taskId] to sleep for [duration].
  ///
  /// Convenience wrapper around [sleepTask] that accepts an ID instead of
  /// a [Task] reference.
  void sleepTaskById(int taskId, Duration duration) {
    final task = _findById(taskId);
    if (task != null) sleepTask(task, duration);
  }

  /// Wake a sleeping task by ID (moves it back to the ready queue).
  void wakeUp(int taskId) {
    final task = _findById(taskId);
    if (task == null || task.state != TaskState.sleeping) return;
    _sleepingTasks.remove(task);
    task.wakeUpTick = null;
    _enqueue(task);
    _log.fine('wakeUp(id=$taskId): $task');
  }

  // ─── Testing helpers ──────────────────────────────────────────────────────

  /// Reset the singleton so tests always start from a clean state.
  ///
  /// Annotated [@visibleForTesting] — do not call in production code.
  @visibleForTesting
  static void resetForTesting() {
    _instance = TaskScheduler._();
  }

  // ─── Statistics ──────────────────────────────────────────────────────────

  SchedulerStats getStats() => SchedulerStats(
        totalTasks:      _allTasks.length,
        readyTasks:      _readyQueue.length,
        sleepingTasks:   _sleepingTasks.length,
        blockedTasks:    _blockedTasks.length,
        terminatedTasks: _allTasks.where((t) => t.state == TaskState.terminated).length,
        contextSwitches: _contextSwitches,
        currentTick:     _tick,
      );

  // ─── Internal helpers ─────────────────────────────────────────────────────

  void _contextSwitch() {
    if (_readyQueue.isEmpty) return;

    // Save current task (if any)
    if (currentTask != null && currentTask!.state == TaskState.running) {
      currentTask!.state = TaskState.ready;
      _enqueue(currentTask!);
    }

    // Select next task according to policy
    final next = switch (policy) {
      SchedulingPolicy.roundRobin    => _readyQueue.removeAt(0),
      SchedulingPolicy.priorityBased => _selectHighestPriority(),
      SchedulingPolicy.cfs           => _selectLeastCpu(),
    };

    next.state = TaskState.running;
    next.cpuTicks++;
    currentTask = next;
    _contextSwitches++;

    _log.fine('ctx-switch → $next (tick=$_tick)');

    // Execute task function (in a real kernel this is done by restoring registers)
    try {
      next.function();
    } on Exception catch (e) {
      _log.severe('Task "${next.name}" threw: $e');
      next.state = TaskState.terminated;
    }
  }

  Task _selectHighestPriority() {
    // _readyQueue is kept sorted by _enqueue
    return _readyQueue.removeAt(0);
  }

  Task _selectLeastCpu() {
    var minTicks = _readyQueue.first.cpuTicks;
    var best     = 0;
    for (var i = 1; i < _readyQueue.length; i++) {
      if (_readyQueue[i].cpuTicks < minTicks) {
        minTicks = _readyQueue[i].cpuTicks;
        best     = i;
      }
    }
    return _readyQueue.removeAt(best);
  }

  void _enqueue(Task task) {
    task.state = TaskState.ready;

    if (policy == SchedulingPolicy.priorityBased) {
      // Insert in descending priority order
      var i = 0;
      while (i < _readyQueue.length && _readyQueue[i].priority >= task.priority) {
        i++;
      }
      _readyQueue.insert(i, task);
    } else {
      _readyQueue.add(task);
    }
  }

  void _wakeExpiredTasks() {
    final toWake = _sleepingTasks.where((t) => t.wakeUpTick! <= _tick).toList();
    for (final t in toWake) {
      _sleepingTasks.remove(t);
      t.wakeUpTick = null;
      _enqueue(t);
      _log.fine('wake: $t at tick $_tick');
    }
  }

  int _durationToTicks(Duration d) {
    // Assuming 1 ms per tick (1 kHz timer)
    return math.max(1, d.inMilliseconds);
  }

  int _allocateStack(int size) {
    // In a real kernel: allocate from MemoryManager
    // Here: simulate with a counter
    return 0x00400000 + (_allTasks.length * size);
  }

  Task? _findById(int id) {
    for (final t in _allTasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ignore: unused_import
  static final math = _Math();
}

// Tiny math helper (avoid importing dart:math just for max)
final class _Math {
  int max(int a, int b) => a > b ? a : b;
}

// ignore: unused_element
final math = _Math();
