import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';

void main() {
  group('New Requirements Tests', () {
    group('GetSessionMessagesByUserCountRequest', () {
      test('should create request with default userMessageLimit', () {
        final request = GetSessionMessagesByUserCountRequest(
          employeeId: 'emp-123',
        );

        expect(request.employeeId, equals('emp-123'));
        expect(request.userMessageLimit, equals(20));
      });

      test('should create request with custom userMessageLimit', () {
        final request = GetSessionMessagesByUserCountRequest(
          employeeId: 'emp-123',
          userMessageLimit: 50,
        );

        expect(request.employeeId, equals('emp-123'));
        expect(request.userMessageLimit, equals(50));
      });

      test('should convert to map correctly', () {
        final request = GetSessionMessagesByUserCountRequest(
          employeeId: 'emp-123',
          userMessageLimit: 30,
        );

        final map = request.toMap();

        expect(map['employeeId'], equals('emp-123'));
        expect(map['userMessageLimit'], equals(30));
      });

      test('should create from map correctly', () {
        final map = {
          'employeeId': 'emp-456',
          'userMessageLimit': 40,
        };

        final request = GetSessionMessagesByUserCountRequest.fromMap(map);

        expect(request.employeeId, equals('emp-456'));
        expect(request.userMessageLimit, equals(40));
      });

      test('should use default userMessageLimit when not provided in map', () {
        final map = {
          'employeeId': 'emp-789',
        };

        final request = GetSessionMessagesByUserCountRequest.fromMap(map);

        expect(request.employeeId, equals('emp-789'));
        expect(request.userMessageLimit, equals(20));
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

      test('should convert to map correctly', () {
        final request = GetUnreceivedMessagesRequest(
          employeeId: 'emp-123',
          receiverDeviceId: 'device-456',
        );

        final map = request.toMap();

        expect(map['employeeId'], equals('emp-123'));
        expect(map['receiverDeviceId'], equals('device-456'));
      });

      test('should create from map correctly', () {
        final map = {
          'employeeId': 'emp-789',
          'receiverDeviceId': 'device-012',
        };

        final request = GetUnreceivedMessagesRequest.fromMap(map);

        expect(request.employeeId, equals('emp-789'));
        expect(request.receiverDeviceId, equals('device-012'));
      });
    });

    group('MarkMessagesAsReceivedRequest', () {
      test('should create request correctly', () {
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

      test('should convert to map correctly', () {
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

        expect(map['employeeId'], equals('emp-123'));
        expect(map['receiverDeviceId'], equals('device-456'));
        expect(map['messageReceiveList'], isA<List>());
        expect((map['messageReceiveList'] as List).length, equals(1));
      });

      test('should create from map correctly', () {
        final map = {
          'employeeId': 'emp-789',
          'receiverDeviceId': 'device-012',
          'messageReceiveList': [
            {
              'messageId': 'msg-1',
              'updateTime': '2026-04-07T10:00:00',
            },
            {
              'messageId': 'msg-2',
              'updateTime': '2026-04-07T11:00:00',
            },
          ],
        };

        final request = MarkMessagesAsReceivedRequest.fromMap(map);

        expect(request.employeeId, equals('emp-789'));
        expect(request.receiverDeviceId, equals('device-012'));
        expect(request.messageReceiveList.length, equals(2));
        expect(request.messageReceiveList[0].messageId, equals('msg-1'));
        expect(request.messageReceiveList[1].messageId, equals('msg-2'));
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

      test('should convert to map correctly', () {
        final request = GetSessionMessagesPagedRequest(
          employeeId: 'emp-123',
          pageSize: 30,
          offset: 60,
        );

        final map = request.toMap();

        expect(map['employeeId'], equals('emp-123'));
        expect(map['pageSize'], equals(30));
        expect(map['offset'], equals(60));
      });

      test('should create from map correctly', () {
        final map = {
          'employeeId': 'emp-456',
          'pageSize': 40,
          'offset': 80,
        };

        final request = GetSessionMessagesPagedRequest.fromMap(map);

        expect(request.employeeId, equals('emp-456'));
        expect(request.pageSize, equals(40));
        expect(request.offset, equals(80));
      });

      test('should use default values when not provided in map', () {
        final map = {
          'employeeId': 'emp-789',
        };

        final request = GetSessionMessagesPagedRequest.fromMap(map);

        expect(request.employeeId, equals('emp-789'));
        expect(request.pageSize, equals(20));
        expect(request.offset, equals(0));
      });
    });

    group('MessageReceiveInfo', () {
      test('should create message receive info correctly', () {
        final updateTime = DateTime.parse('2026-04-07T10:00:00');
        final info = MessageReceiveInfo(
          messageId: 'msg-123',
          updateTime: updateTime,
        );

        expect(info.messageId, equals('msg-123'));
        expect(info.updateTime, equals(updateTime));
      });

      test('should convert to map correctly', () {
        final updateTime = DateTime.parse('2026-04-07T10:00:00');
        final info = MessageReceiveInfo(
          messageId: 'msg-123',
          updateTime: updateTime,
        );

        final map = info.toMap();

        expect(map['messageId'], equals('msg-123'));
        expect(map['updateTime'], equals('2026-04-07T10:00:00'));
      });

      test('should create from map correctly', () {
        final map = {
          'messageId': 'msg-456',
          'updateTime': '2026-04-07T11:30:00',
        };

        final info = MessageReceiveInfo.fromMap(map);

        expect(info.messageId, equals('msg-456'));
        expect(info.updateTime, equals(DateTime.parse('2026-04-07T11:30:00')));
      });
    });
  });
}
