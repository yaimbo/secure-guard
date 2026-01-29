import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:redis/redis.dart';

/// Redis service for pub/sub and caching
class RedisService {
  final String host;
  final int port;
  final String? password;
  final _log = Logger('RedisService');

  RedisConnection? _connection;
  RedisConnection? _pubSubConnection;
  Command? _command;
  PubSub? _pubSub;

  final _subscriptions = <String, StreamController<Map<String, dynamic>>>{};

  RedisService({
    this.host = 'localhost',
    this.port = 6379,
    this.password,
  });

  /// Initialize Redis connections
  Future<void> init() async {
    try {
      // Main connection for commands
      _connection = RedisConnection();
      _command = await _connection!.connect(host, port);

      if (password != null) {
        await _command!.send_object(['AUTH', password]);
      }

      // Separate connection for pub/sub (required by Redis)
      _pubSubConnection = RedisConnection();
      final pubSubCommand = await _pubSubConnection!.connect(host, port);

      if (password != null) {
        await pubSubCommand.send_object(['AUTH', password]);
      }

      _pubSub = PubSub(pubSubCommand);

      _log.info('Redis connected to $host:$port');
    } catch (e) {
      _log.warning('Redis connection failed: $e - running without Redis');
    }
  }

  /// Check if Redis is connected
  bool get isConnected => _command != null;

  /// Publish an event to a channel
  Future<void> publish(String channel, Map<String, dynamic> data) async {
    if (_command == null) return;

    try {
      final json = jsonEncode(data);
      await _command!.send_object(['PUBLISH', channel, json]);
    } catch (e) {
      _log.warning('Failed to publish to $channel: $e');
    }
  }

  /// Subscribe to a channel and get a stream of events
  Stream<Map<String, dynamic>> subscribe(String channel) {
    if (_subscriptions.containsKey(channel)) {
      return _subscriptions[channel]!.stream;
    }

    final controller = StreamController<Map<String, dynamic>>.broadcast();
    _subscriptions[channel] = controller;

    if (_pubSub != null) {
      _pubSub!.subscribe([channel]);

      // Listen to messages
      _pubSub!.getStream().listen((message) {
        if (message is List && message.length >= 3) {
          final type = message[0];
          final msgChannel = message[1];
          final data = message[2];

          if (type == 'message' && msgChannel == channel) {
            try {
              final parsed = jsonDecode(data as String) as Map<String, dynamic>;
              controller.add(parsed);
            } catch (e) {
              _log.warning('Failed to parse message: $e');
            }
          }
        }
      });
    }

    return controller.stream;
  }

  /// Unsubscribe from a channel
  void unsubscribe(String channel) {
    _subscriptions[channel]?.close();
    _subscriptions.remove(channel);
  }

  // ═══════════════════════════════════════════════════════════════════
  // METRICS STORAGE (Time-series data)
  // ═══════════════════════════════════════════════════════════════════

  /// Store a metric value with timestamp
  Future<void> recordMetric(String key, double value, {DateTime? timestamp}) async {
    if (_command == null) return;

    final ts = (timestamp ?? DateTime.now()).millisecondsSinceEpoch;
    try {
      // Use sorted set with timestamp as score
      await _command!.send_object(['ZADD', key, ts.toString(), '$ts:$value']);

      // Trim to keep only last 24 hours of data
      final cutoff = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
      await _command!.send_object(['ZREMRANGEBYSCORE', key, '-inf', cutoff.toString()]);
    } catch (e) {
      _log.warning('Failed to record metric $key: $e');
    }
  }

  /// Get metric values in a time range
  Future<List<MetricPoint>> getMetrics(String key, {DateTime? start, DateTime? end}) async {
    if (_command == null) return [];

    final startTs = (start ?? DateTime.now().subtract(const Duration(hours: 24))).millisecondsSinceEpoch;
    final endTs = (end ?? DateTime.now()).millisecondsSinceEpoch;

    try {
      final result = await _command!.send_object([
        'ZRANGEBYSCORE', key, startTs.toString(), endTs.toString()
      ]);

      if (result is List) {
        return result.map((item) {
          final parts = (item as String).split(':');
          return MetricPoint(
            timestamp: DateTime.fromMillisecondsSinceEpoch(int.parse(parts[0])),
            value: double.parse(parts[1]),
          );
        }).toList();
      }
    } catch (e) {
      _log.warning('Failed to get metrics $key: $e');
    }

    return [];
  }

  // ═══════════════════════════════════════════════════════════════════
  // COUNTERS
  // ═══════════════════════════════════════════════════════════════════

  /// Increment a counter
  Future<int> incrementCounter(String key, {int amount = 1}) async {
    if (_command == null) return 0;

    try {
      final result = await _command!.send_object(['INCRBY', key, amount.toString()]);
      return result as int;
    } catch (e) {
      _log.warning('Failed to increment counter $key: $e');
      return 0;
    }
  }

  /// Get counter value
  Future<int> getCounter(String key) async {
    if (_command == null) return 0;

    try {
      final result = await _command!.send_object(['GET', key]);
      return result != null ? int.tryParse(result.toString()) ?? 0 : 0;
    } catch (e) {
      _log.warning('Failed to get counter $key: $e');
      return 0;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // ONLINE CLIENTS TRACKING
  // ═══════════════════════════════════════════════════════════════════

  /// Mark a client as online (with TTL)
  Future<void> setClientOnline(String clientId, Map<String, dynamic> data) async {
    if (_command == null) return;

    try {
      final key = 'client:online:$clientId';
      final json = jsonEncode(data);
      await _command!.send_object(['SET', key, json, 'EX', '120']); // 2 min TTL
      await _command!.send_object(['SADD', 'client:online:set', clientId]);
    } catch (e) {
      _log.warning('Failed to set client online $clientId: $e');
    }
  }

  /// Get online clients
  Future<List<String>> getOnlineClients() async {
    if (_command == null) return [];

    try {
      final result = await _command!.send_object(['SMEMBERS', 'client:online:set']);
      if (result is List) {
        return result.cast<String>();
      }
    } catch (e) {
      _log.warning('Failed to get online clients: $e');
    }

    return [];
  }

  /// Get count of online clients
  Future<int> getOnlineClientCount() async {
    if (_command == null) return 0;

    try {
      final result = await _command!.send_object(['SCARD', 'client:online:set']);
      return result as int? ?? 0;
    } catch (e) {
      _log.warning('Failed to get online client count: $e');
      return 0;
    }
  }

  /// Mark a client as offline
  Future<void> setClientOffline(String clientId) async {
    if (_command == null) return;

    try {
      await _command!.send_object(['DEL', 'client:online:$clientId']);
      await _command!.send_object(['SREM', 'client:online:set', clientId]);
    } catch (e) {
      _log.warning('Failed to set client offline $clientId: $e');
    }
  }

  /// Get online client data
  Future<Map<String, dynamic>?> getClientOnlineData(String clientId) async {
    if (_command == null) return null;

    try {
      final result = await _command!.send_object(['GET', 'client:online:$clientId']);
      if (result != null) {
        return jsonDecode(result as String) as Map<String, dynamic>;
      }
    } catch (e) {
      _log.warning('Failed to get client online data $clientId: $e');
    }

    return null;
  }

  /// Close connections
  Future<void> close() async {
    for (final controller in _subscriptions.values) {
      await controller.close();
    }
    _subscriptions.clear();

    await _connection?.close();
    await _pubSubConnection?.close();
    _log.info('Redis connections closed');
  }
}

/// A single metric data point
class MetricPoint {
  final DateTime timestamp;
  final double value;

  MetricPoint({required this.timestamp, required this.value});

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'value': value,
  };
}

/// Redis pub/sub channel names
class RedisChannels {
  static const connections = 'channel:connections';
  static const errors = 'channel:errors';
  static const metrics = 'channel:metrics';
  static const audit = 'channel:audit';
}

/// Redis metric keys
class RedisMetrics {
  static const connectionCount = 'metrics:connections:count';
  static const bandwidthTx = 'metrics:bandwidth:tx';
  static const bandwidthRx = 'metrics:bandwidth:rx';
  static const handshakeSuccess = 'metrics:handshakes:success';
  static const handshakeFailed = 'metrics:handshakes:failed';
  static const totalConnections = 'metrics:total:connections';
  static const totalBytesTx = 'metrics:total:bytes_tx';
  static const totalBytesRx = 'metrics:total:bytes_rx';
}
