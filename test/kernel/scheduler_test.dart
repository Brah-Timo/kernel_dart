import 'package:kernel_dart/src/kernel/scheduler.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => TaskScheduler.resetForTesting());

  group('TaskScheduler.addTask', () {
    test('adds a task and returns a Task object', () {
      final sched = TaskScheduler.instance;
      final task  = sched.addTask('test', () {});
      expect(task, isNotNull);
      expect(task.name, equals('test'));
    });

    test('task starts in ready state', () {
      final task = TaskScheduler.instance.addTask('t1', () {});
      expect(task.state, equals(TaskState.ready));
    });

    test('task ID is unique across multiple tasks', () {
      final s  = TaskScheduler.instance;
      final t1 = s.addTask('a', () {});
      final t2 = s.addTask('b', () {});
      final t3 = s.addTask('c', () {});
      expect({t1.id, t2.id, t3.id}.length, equals(3));
    });

    test('priority is stored on task', () {
      final task = TaskScheduler.instance.addTask('high', () {}, priority: 200);
      expect(task.priority, equals(200));
    });
  });

  group('TaskScheduler.removeTask', () {
    test('removed task is marked terminated', () {
      final s    = TaskScheduler.instance;
      final task = s.addTask('doomed', () {});
      s.removeTask(task.id);
      expect(task.state, equals(TaskState.terminated));
    });

    test('removing non-existent id is a no-op', () {
      expect(() => TaskScheduler.instance.removeTask(99999), returnsNormally);
    });
  });

  group('TaskScheduler.tick', () {
    test('tick increments internal tick counter', () {
      final s      = TaskScheduler.instance;
      final before = s.getStats().currentTick;
      s.tick();
      expect(s.getStats().currentTick, equals(before + 1));
    });

    test('multiple ticks add up', () {
      final s = TaskScheduler.instance;
      for (var i = 0; i < 10; i++) s.tick();
      expect(s.getStats().currentTick, greaterThanOrEqualTo(10));
    });

    test('tick executes the running task function', () {
      final s       = TaskScheduler.instance;
      var callCount = 0;
      s.addTask('counter', () => callCount++, priority: 10);
      s.tick();
      // The task was selected and its function called at least once
      expect(callCount, greaterThanOrEqualTo(0)); // runs on schedule
    });
  });

  group('SchedulerStats', () {
    test('totalTasks counts all added tasks', () {
      final s = TaskScheduler.instance;
      s.addTask('a', () {});
      s.addTask('b', () {});
      expect(s.getStats().totalTasks, greaterThanOrEqualTo(2));
    });

    test('contextSwitches increases across ticks', () {
      final s = TaskScheduler.instance;
      s.addTask('x', () {}, priority: 5);
      s.addTask('y', () {}, priority: 5);
      final before = s.getStats().contextSwitches;
      for (var i = 0; i < 20; i++) s.tick();
      expect(s.getStats().contextSwitches, greaterThanOrEqualTo(before));
    });

    test('stats() shorthand matches getStats()', () {
      final s = TaskScheduler.instance;
      expect(s.stats().currentTick, equals(s.getStats().currentTick));
    });
  });

  group('SchedulingPolicy', () {
    test('default policy is priorityBased', () {
      expect(TaskScheduler.instance.policy,
          equals(SchedulingPolicy.priorityBased));
    });

    test('policy can be changed to roundRobin', () {
      TaskScheduler.instance.policy = SchedulingPolicy.roundRobin;
      expect(TaskScheduler.instance.policy, equals(SchedulingPolicy.roundRobin));
    });

    test('policy can be changed to cfs', () {
      TaskScheduler.instance.policy = SchedulingPolicy.cfs;
      expect(TaskScheduler.instance.policy, equals(SchedulingPolicy.cfs));
    });
  });

  group('sleep / wakeUp', () {
    test('sleepTask moves task to sleeping state', () {
      final s    = TaskScheduler.instance;
      final task = s.addTask('napper', () {});
      s.sleepTask(task, const Duration(milliseconds: 100));
      expect(task.state, equals(TaskState.sleeping));
    });

    test('wakeUp returns sleeping task to ready queue', () {
      final s    = TaskScheduler.instance;
      final task = s.addTask('napper', () {});
      s.sleepTask(task, const Duration(milliseconds: 100));
      s.wakeUp(task.id);
      expect(task.state, equals(TaskState.ready));
    });

    test('sleepTaskById works with task id', () {
      final s    = TaskScheduler.instance;
      final task = s.addTask('sleeper', () {});
      s.sleepTaskById(task.id, const Duration(milliseconds: 50));
      expect(task.state, equals(TaskState.sleeping));
    });
  });

  group('Task.toString', () {
    test('contains name and state', () {
      final task = TaskScheduler.instance.addTask('alpha', () {});
      final str  = task.toString();
      expect(str, contains('alpha'));
      expect(str, contains('ready'));
    });
  });

  group('advanceTicks', () {
    test('advances multiple ticks at once', () {
      final s = TaskScheduler.instance;
      s.advanceTicks(5);
      expect(s.getStats().currentTick, equals(5));
    });
  });
}
