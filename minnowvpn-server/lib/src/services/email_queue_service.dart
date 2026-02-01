import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'email_service.dart';
import 'redis_service.dart';

/// Email job type
enum EmailJobType {
  enrollment,
  test,
}

/// Email job for queue processing
class EmailJob {
  final String id;
  final EmailJobType type;
  final String toEmail;
  final String toName;
  final Map<String, dynamic> data;
  final int retries;
  final DateTime createdAt;
  final String? lastError;

  EmailJob({
    required this.id,
    required this.type,
    required this.toEmail,
    required this.toName,
    required this.data,
    this.retries = 0,
    DateTime? createdAt,
    this.lastError,
  }) : createdAt = createdAt ?? DateTime.now();

  factory EmailJob.fromJson(Map<String, dynamic> json) {
    return EmailJob(
      id: json['id'] as String,
      type: EmailJobType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => EmailJobType.enrollment,
      ),
      toEmail: json['to_email'] as String,
      toName: json['to_name'] as String,
      data: json['data'] as Map<String, dynamic>? ?? {},
      retries: json['retries'] as int? ?? 0,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      lastError: json['last_error'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'to_email': toEmail,
        'to_name': toName,
        'data': data,
        'retries': retries,
        'created_at': createdAt.toIso8601String(),
        if (lastError != null) 'last_error': lastError,
      };

  EmailJob copyWith({int? retries, String? lastError}) {
    return EmailJob(
      id: id,
      type: type,
      toEmail: toEmail,
      toName: toName,
      data: data,
      retries: retries ?? this.retries,
      createdAt: createdAt,
      lastError: lastError ?? this.lastError,
    );
  }
}

/// Email job result
class EmailJobResult {
  final String jobId;
  final bool success;
  final String? error;

  EmailJobResult({
    required this.jobId,
    required this.success,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'job_id': jobId,
        'success': success,
        if (error != null) 'error': error,
      };
}

/// Service for async email sending with Redis queue and retries
class EmailQueueService {
  final RedisService redis;
  final EmailService emailService;
  final _log = Logger('EmailQueueService');
  final _uuid = const Uuid();

  Timer? _processorTimer;
  bool _isProcessing = false;

  /// Redis keys for email queue
  static const _queueKey = 'email:queue';
  static const _failedKey = 'email:failed';
  static const _sentCountKey = 'email:sent:count';

  /// Maximum retry attempts before moving to failed queue
  static const _maxRetries = 3;

  /// Processing interval
  static const _processInterval = Duration(seconds: 5);

  EmailQueueService({
    required this.redis,
    required this.emailService,
  });

  /// Queue an email for async sending
  /// Returns the job ID for tracking
  Future<String> queueEmail({
    required EmailJobType type,
    required String toEmail,
    required String toName,
    required Map<String, dynamic> data,
  }) async {
    final jobId = _uuid.v4();

    final job = EmailJob(
      id: jobId,
      type: type,
      toEmail: toEmail,
      toName: toName,
      data: data,
    );

    final jobJson = jsonEncode(job.toJson());

    // Push to Redis queue (left side - FIFO when using RPOP)
    if (redis.isConnected) {
      await _lpush(_queueKey, jobJson);
      _log.info('Email job queued: $jobId to $toEmail');
    } else {
      // If Redis is not available, try to send immediately
      _log.warning('Redis not available - sending email synchronously');
      await _sendEmail(job);
    }

    return jobId;
  }

  /// Queue an enrollment email
  Future<String> queueEnrollmentEmail({
    required String toEmail,
    required String toName,
    required String enrollmentCode,
    required String deepLink,
    required String serverDomain,
    required String expiresIn,
  }) async {
    return queueEmail(
      type: EmailJobType.enrollment,
      toEmail: toEmail,
      toName: toName,
      data: {
        'code': enrollmentCode,
        'deep_link': deepLink,
        'server_domain': serverDomain,
        'expires_in': expiresIn,
      },
    );
  }

  /// Start the background email processor
  void startProcessor() {
    if (_processorTimer != null) {
      _log.warning('Email processor already running');
      return;
    }

    _log.info('Starting email queue processor');
    _processorTimer = Timer.periodic(_processInterval, (_) => _processQueue());
  }

  /// Stop the background email processor
  void stopProcessor() {
    _processorTimer?.cancel();
    _processorTimer = null;
    _log.info('Email queue processor stopped');
  }

  /// Process the email queue
  Future<void> _processQueue() async {
    if (_isProcessing || !redis.isConnected) return;

    _isProcessing = true;

    try {
      // Pop job from queue (right side for FIFO)
      final jobJson = await _rpop(_queueKey);
      if (jobJson == null) {
        _isProcessing = false;
        return;
      }

      final job = EmailJob.fromJson(jsonDecode(jobJson) as Map<String, dynamic>);

      try {
        await _sendEmail(job);
        _log.info('Email sent successfully: ${job.id} to ${job.toEmail}');

        // Increment sent counter
        await _incr(_sentCountKey);
      } catch (e) {
        _log.warning('Email send failed: ${job.id} - $e');

        final newRetries = job.retries + 1;
        if (newRetries < _maxRetries) {
          // Re-queue with incremented retry count
          final retryJob = job.copyWith(
            retries: newRetries,
            lastError: e.toString(),
          );
          await _lpush(_queueKey, jsonEncode(retryJob.toJson()));
          _log.info('Email job re-queued (retry $newRetries/$_maxRetries): ${job.id}');
        } else {
          // Move to failed queue
          final failedJob = job.copyWith(
            retries: newRetries,
            lastError: e.toString(),
          );
          await _lpush(_failedKey, jsonEncode(failedJob.toJson()));
          _log.severe('Email job moved to failed queue after $_maxRetries retries: ${job.id}');
        }
      }
    } catch (e) {
      _log.warning('Error processing email queue: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Send an email based on job type
  Future<void> _sendEmail(EmailJob job) async {
    switch (job.type) {
      case EmailJobType.enrollment:
        await emailService.sendEnrollmentEmail(
          toEmail: job.toEmail,
          toName: job.toName,
          enrollmentCode: job.data['code'] as String,
          deepLink: job.data['deep_link'] as String,
          serverDomain: job.data['server_domain'] as String,
          expiresIn: job.data['expires_in'] as String,
        );
        break;

      case EmailJobType.test:
        await emailService.sendTestEmail(job.toEmail);
        break;
    }
  }

  /// Get queue statistics
  Future<Map<String, dynamic>> getStats() async {
    if (!redis.isConnected) {
      return {
        'queue_length': 0,
        'failed_count': 0,
        'total_sent': 0,
        'redis_connected': false,
      };
    }

    final queueLen = await _llen(_queueKey);
    final failedLen = await _llen(_failedKey);
    final sentCount = await _get(_sentCountKey);

    return {
      'queue_length': queueLen,
      'failed_count': failedLen,
      'total_sent': sentCount,
      'redis_connected': true,
    };
  }

  /// Get failed jobs (for admin review)
  Future<List<EmailJob>> getFailedJobs({int limit = 50}) async {
    if (!redis.isConnected) return [];

    final jobs = await _lrange(_failedKey, 0, limit - 1);
    return jobs
        .map((j) => EmailJob.fromJson(jsonDecode(j) as Map<String, dynamic>))
        .toList();
  }

  /// Retry a failed job
  Future<void> retryFailedJob(String jobId) async {
    if (!redis.isConnected) return;

    // Get all failed jobs
    final jobs = await getFailedJobs(limit: 100);
    final job = jobs.where((j) => j.id == jobId).firstOrNull;

    if (job == null) {
      throw Exception('Job not found: $jobId');
    }

    // Remove from failed queue and re-queue with reset retries
    await _lrem(_failedKey, jobId);
    final retryJob = job.copyWith(retries: 0, lastError: null);
    await _lpush(_queueKey, jsonEncode(retryJob.toJson()));

    _log.info('Failed job re-queued for retry: $jobId');
  }

  /// Clear failed queue
  Future<void> clearFailedJobs() async {
    if (!redis.isConnected) return;
    await _del(_failedKey);
    _log.info('Failed email queue cleared');
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Redis helper methods
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _lpush(String key, String value) async {
    await redis.sendCommand(['LPUSH', key, value]);
  }

  Future<String?> _rpop(String key) async {
    final result = await redis.sendCommand(['RPOP', key]);
    return result as String?;
  }

  Future<int> _llen(String key) async {
    final result = await redis.sendCommand(['LLEN', key]);
    return result as int? ?? 0;
  }

  Future<List<String>> _lrange(String key, int start, int stop) async {
    final result = await redis.sendCommand(['LRANGE', key, start.toString(), stop.toString()]);
    if (result is List) {
      return result.cast<String>();
    }
    return [];
  }

  Future<void> _lrem(String key, String value) async {
    // Remove all occurrences of value matching job id
    // We need to find and remove by iterating since we're matching by job content
    final jobs = await _lrange(key, 0, -1);
    for (final jobJson in jobs) {
      if (jobJson.contains('"id":"$value"')) {
        await redis.sendCommand(['LREM', key, '1', jobJson]);
        break;
      }
    }
  }

  Future<void> _del(String key) async {
    await redis.sendCommand(['DEL', key]);
  }

  Future<void> _incr(String key) async {
    await redis.sendCommand(['INCR', key]);
  }

  Future<int> _get(String key) async {
    final result = await redis.sendCommand(['GET', key]);
    if (result != null) {
      return int.tryParse(result.toString()) ?? 0;
    }
    return 0;
  }
}
