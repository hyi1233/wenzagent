import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';

void main() {
  group('Unreceived Messages Mechanism Tests', () {
    group('MessageReceiveInfo', () {
      test('should serialize and deserialize correctly', () {
        final updateTime = DateTime.parse('2026-04-07T10:00:00');
        final info = MessageReceiveInfo(
          messageId: 'msg-123',
          updateTime: updateTime,
        );

        final map = info.toMap();
        final deserialized = MessageReceiveInfo.fromMap(map);

        expect(deserialized.messageId, equals(info.messageId));
        expect(deserialized.updateTime, equals(info.updateTime));
      });
    });

    group('GetUnreceivedMessagesRequest', () {
      test('should create request correctly', () {
        final request = GetUnreceivedMessagesRequest(
          employeeId: 'emp-123',
          receiverDeviceId: 'device-456',
        );

        expect(request.employeeId, equals('emp-123'));
        expect(request.receiverDeviceId, equals('device-456'));
      });

      test('should serialize and deserialize correctly', () {
        final request = GetUnreceivedMessagesRequest(
          employeeId: 'emp-123',
          receiverDeviceId: 'device-456',
        );

        final map = request.toMap();
        final deserialized = GetUnreceivedMessagesRequest.fromMap(map);

        expect(deserialized.employeeId, equals(request.employeeId));
        expect(deserialized.receiverDeviceId, equals(request.receiverDeviceId));
      });
    });

    group('MarkMessagesAsReceivedRequest', () {
      test('should create request with message list', () {
        final receiveList = [
          MessageReceiveInfo(
            messageId: 'msg-1',
            updateTime: DateTime.parse('2026-04-07T10:00:00'),
          ),
          MessageReceiveInfo(
            messageId: 'msg-2',
            updateTime: DateTime.parse('2026-04-07T11:00:00'),
          ),
        ];

        final request = MarkMessagesAsReceivedRequest(
          employeeId: 'emp-123',
          receiverDeviceId: 'device-456',
          messageReceiveList: receiveList,
        );

        expect(request.employeeId, equals('emp-123'));
        expect(request.receiverDeviceId, equals('device-456'));
        expect(request.messageReceiveList.length, equals(2));
      });

      test('should serialize and deserialize correctly', () {
        final receiveList = [
          MessageReceiveInfo(
            messageId: 'msg-1',
            updateTime: DateTime.parse('2026-04-07T10:00:00'),
          ),
        ];

        final request = MarkMessagesAsReceivedRequest(
          employeeId: 'emp-123',
          receiverDeviceId: 'device-456',
          messageReceiveList: receiveList,
        );

        final map = request.toMap();
        final deserialized = MarkMessagesAsReceivedRequest.fromMap(map);

        expect(deserialized.employeeId, equals(request.employeeId));
        expect(deserialized.receiverDeviceId, equals(request.receiverDeviceId));
        expect(deserialized.messageReceiveList.length, equals(1));
        expect(
          deserialized.messageReceiveList[0].messageId,
          equals('msg-1'),
        );
      });
    });

    group('GetSessionMessagesPagedRequest', () {
      test('should create request with default values', () {
        final request = GetSessionMessagesPagedRequest(
          employeeId: 'emp-123',
        );

        expect(request.employeeId, equals('emp-123'));
        expect(request.pageSize, equals(20));
        expect(request.offset, equals(0));
      });

      test('should create request with custom values', () {
        final request = GetSessionMessagesPagedRequest(
          employeeId: 'emp-123',
          pageSize: 50,
          offset: 100,
        );

        expect(request.employeeId, equals('emp-123'));
        expect(request.pageSize, equals(50));
        expect(request.offset, equals(100));
      });

      test('should serialize and deserialize correctly', () {
        final request = GetSessionMessagesPagedRequest(
          employeeId: 'emp-123',
          pageSize: 30,
          offset: 60,
        );

        final map = request.toMap();
        final deserialized = GetSessionMessagesPagedRequest.fromMap(map);

        expect(deserialized.employeeId, equals(request.employeeId));
        expect(deserialized.pageSize, equals(request.pageSize));
        expect(deserialized.offset, equals(request.offset));
      });
    });

    group('Message Update Time Tracking', () {
      test('should track message update time correctly', () {
        final updateTime = DateTime.parse('2026-04-07T10:00:00');
        final message = AgentMessage(
          id: 'msg-123',
          role: 'user',
          content: 'Hello',
          createdAt: DateTime.parse('2026-04-07T09:00:00'),
          metadata: {'updateTime': updateTime.toIso8601String()},
        );

        // Verify updateTime is stored in metadata
        expect(message.metadata?['updateTime'], equals(updateTime.toIso8601String()));
      });

      test('should handle messages without updateTime in metadata', () {
        final createdAt = DateTime.parse('2026-04-07T09:00:00');
        final message = AgentMessage(
          id: 'msg-123',
          role: 'user',
          content: 'Hello',
          createdAt: createdAt,
        );

        // When no updateTime in metadata, should use createdAt
        expect(message.createdAt, equals(createdAt));
        expect(message.metadata?['updateTime'], isNull);
      });
    });
  });
}
