import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('InterruptJudge', () {
    test('解析有效的 interrupt 响应', () async {
      final judge = InterruptJudge((prompt) async {
        return '''{"decision": "interrupt", "reason": "typo correction", "targetMessageId": "msg-123"}''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': '帮我写个代谢'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': '帮我写个代码'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.interrupt);
      expect(result.reason, 'typo correction');
      expect(result.targetMessageId, 'msg-123');
    });

    test('解析有效的 wait 响应', () async {
      final judge = InterruptJudge((prompt) async {
        return '''{"decision": "wait", "reason": "different topic", "targetMessageId": null}''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': '翻译这段文字'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': '明天天气如何'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, 'different topic');
      expect(result.targetMessageId, isNull);
    });

    test('处理被 markdown 包裹的 JSON', () async {
      final judge = InterruptJudge((prompt) async {
        return '''
Here is the decision:

```json
{"decision": "interrupt", "reason": "cancel", "targetMessageId": "msg-123"}
```
''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': '翻译文字'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': '不用了，取消'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.interrupt);
      expect(result.targetMessageId, 'msg-123');
    });

    test('无效 JSON 降级为 wait', () async {
      final judge = InterruptJudge((prompt) async {
        return 'I think this is a different topic';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': 'test'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': 'test2'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, contains('Failed to extract JSON'));
    });

    test('decision=interrupt 但 targetMessageId 无效时降级为 wait', () async {
      final judge = InterruptJudge((prompt) async {
        return '''{"decision": "interrupt", "reason": "test", "targetMessageId": null}''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': 'test'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': 'test2'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, contains('targetMessageId is missing or invalid'));
    });

    test('decision=wait 但 targetMessageId 非空时降级为 wait', () async {
      final judge = InterruptJudge((prompt) async {
        return '''{"decision": "wait", "reason": "test", "targetMessageId": "msg-123"}''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': 'test'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': 'test2'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, contains('targetMessageId is not null'));
    });

    test('无效 decision 值时降级为 wait', () async {
      final judge = InterruptJudge((prompt) async {
        return '''{"decision": "unknown", "reason": "test", "targetMessageId": null}''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': 'test'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': 'test2'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, contains('Invalid decision value'));
    });

    test('LLM 调用异常时降级为 wait', () async {
      final judge = InterruptJudge((prompt) async {
        throw Exception('Network error');
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': 'test'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': 'test2'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, contains('LLM judgment error'));
    });

    test('LLM 调用超时时降级为 wait', () async {
      final judge = InterruptJudge((prompt) async {
        await Future.delayed(Duration(milliseconds: 20000)); // 超过 15 秒
        return '''{"decision": "wait", "reason": "test", "targetMessageId": null}''';
      });

      final processing = TrackedMessage(
        messageId: 'msg-123',
        messageData: {'content': 'test'},
        status: AgentMessageStatus.processing,
      );
      final queued = [
        TrackedMessage(
          messageId: 'msg-456',
          messageData: {'content': 'test2'},
          status: AgentMessageStatus.queued,
        ),
      ];

      final result = await judge.shouldInterrupt(
        currentProcessing: processing,
        queuedMessages: queued,
      );

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, contains('LLM judgment error'));
    }, timeout: Timeout(Duration(seconds: 20)));
  });

  group('MessageTracker', () {
    test('追踪和更新消息状态', () {
      final tracker = MessageTracker();

      tracker.track('msg-1', {'content': 'test1'});
      tracker.track('msg-2', {'content': 'test2'});

      expect(tracker.allMessages.length, 2);
      expect(tracker.allMessages[0].messageId, 'msg-1');
      expect(tracker.allMessages[0].status, AgentMessageStatus.queued);
      expect(tracker.allMessages[0].content, 'test1');

      tracker.updateStatus('msg-1', AgentMessageStatus.processing);

      expect(tracker.getProcessingMessage()?.messageId, 'msg-1');
      expect(tracker.getQueuedMessages().length, 1);
      expect(tracker.getQueuedMessages()[0].messageId, 'msg-2');
    });

    test('获取处理中和排队中的消息', () {
      final tracker = MessageTracker();

      tracker.track('msg-1', {'content': 'test1'});
      tracker.track('msg-2', {'content': 'test2'});
      tracker.track('msg-3', {'content': 'test3'});

      tracker.updateStatus('msg-2', AgentMessageStatus.processing);

      final processing = tracker.getProcessingMessage();
      expect(processing?.messageId, 'msg-2');

      final queued = tracker.getQueuedMessages();
      expect(queued.length, 2);
      expect(queued.map((m) => m.messageId), ['msg-1', 'msg-3']);
    });

    test('清空追踪', () {
      final tracker = MessageTracker();

      tracker.track('msg-1', {'content': 'test1'});
      tracker.track('msg-2', {'content': 'test2'});

      expect(tracker.allMessages.length, 2);

      tracker.clear();

      expect(tracker.allMessages.length, 0);
      expect(tracker.getProcessingMessage(), isNull);
      expect(tracker.getQueuedMessages(), isEmpty);
    });
  });

  group('InterruptJudgeResult', () {
    test('创建 wait 结果', () {
      final result = InterruptJudgeResult.wait('test reason');

      expect(result.decision, InterruptDecision.wait);
      expect(result.reason, 'test reason');
      expect(result.targetMessageId, isNull);
    });

    test('创建 interrupt 结果', () {
      final result = InterruptJudgeResult.interrupt('test reason', 'msg-123');

      expect(result.decision, InterruptDecision.interrupt);
      expect(result.reason, 'test reason');
      expect(result.targetMessageId, 'msg-123');
    });
  });
}
