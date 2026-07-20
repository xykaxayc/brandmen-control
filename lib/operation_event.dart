import 'dart:convert';

import 'logger.dart';

/// Машиночитаемое событие рядом с обычным русским логом.
class OperationEvent {
  OperationEvent._();

  static void log({
    required String event,
    required String device,
    String? operationId,
    String? deploymentId,
    String? from,
    String? to,
    String? errorCode,
    int? durationMs,
    int? bytesTransferred,
    int? retry,
  }) {
    AppLogger.log('[EVENT] ${jsonEncode({
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'device': device,
          'event_type': event,
          if (operationId != null) 'operation_id': operationId,
          if (deploymentId != null) 'deployment_id': deploymentId,
          if (from != null) 'state_from': from,
          if (to != null) 'state_to': to,
          if (errorCode != null) 'error_code': errorCode,
          if (durationMs != null) 'duration_ms': durationMs,
          if (bytesTransferred != null) 'bytes_transferred': bytesTransferred,
          if (retry != null) 'retry_number': retry,
        })}');
  }
}
