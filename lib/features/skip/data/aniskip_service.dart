/// AniSkip (api.aniskip.com) intro/outro skip times for anime.
///
/// A different database from the older anime-skip.com integration
/// ([AnimeSkipService]): AniSkip is keyed by MyAnimeList id and episode
/// number, needs no key and no login, and is the one the user asked for
/// (+55, "ok aniskip intregate karenge for anime"). Verified live
/// 2026-11-16: Demon Slayer (MAL 38000) ep 1 returns OP 5.617–95.617
/// and ED 1295.128–1385.128; One Piece (MAL 21) ep 1000 returns OP
/// 13.891–123.834.
///
/// Coverage is community-driven: most popular anime have data, obscure
/// titles may have none. A missing answer is a missing convenience —
/// every failure path returns an empty list, never throws, and the
/// player shows no button and no error.
///
/// The MAL id comes from the plugin's sync ids when it filed one, and
/// otherwise from AniList's public GraphQL API (`Media(id) { idMal }`,
/// no key), because the plugins file AniList ids far more often than
/// MAL ids. The episode length is required by the AniSkip API, so the
/// player only asks once mpv knows it (see `_maybeLoadAniSkip` in the
/// mpv screen).
library;

import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/dio_client_provider.dart';
import 'skip_service.dart';

/// Plain provider (no codegen): the sibling skip services use
/// `@riverpod`, whose `.g.dart` is committed and cannot be regenerated
/// on this VM, so a plain [Provider] keeps this file self-contained.
final aniskipServiceProvider = Provider<AniskipService>(
  (ref) => AniskipService(ref.watch(dioClientProvider)),
);

class AniskipService {
  AniskipService(this._dio);

  final Dio _dio;

  static const String _baseUrl = 'https://api.aniskip.com/v2';

  // Cache MAL resolutions and skip answers for an hour, keyed by
  // anilistId and malId:episode. Without this, fast-skipping through
  // anime episodes re-resolves and re-fetches on every seek.
  static const int _cacheMax = 500;
  static const Duration _cacheTtl = Duration(hours: 1);
  static final LinkedHashMap<int, _CachedMal> _malCache =
      LinkedHashMap<int, _CachedMal>();
  static final LinkedHashMap<String, _CachedSegments> _segmentsCache =
      LinkedHashMap<String, _CachedSegments>();

  /// The MAL id, if the plugin filed one under any of the key spellings
  /// plugins use.
  static int? malIdFromSyncData(Map<String, String>? sync) {
    if (sync == null) return null;
    final raw = sync['mal'] ?? sync['malId'] ?? sync['mal_id'];
    return raw == null ? null : int.tryParse(raw);
  }

  /// The AniList id, if the plugin filed one under any of the key
  /// spellings plugins use (same readings as `skip_segments.dart`).
  static int? anilistIdFromSyncData(Map<String, String>? sync) {
    if (sync == null) return null;
    final raw = sync['anilist'] ?? sync['anilistId'] ?? sync['anilist_id'];
    return raw == null ? null : int.tryParse(raw);
  }

  /// Skip segments for [episode] of an anime title.
  ///
  /// [malId] wins when the plugin filed one; otherwise [anilistId] is
  /// resolved to a MAL id through AniList. Returns [] when no MAL id
  /// resolves, when AniSkip has no data for the episode, or on any
  /// error.
  Future<List<SkipSegment>> getSkipSegments({
    int? malId,
    int? anilistId,
    required int episode,
    required int duration,
  }) async {
    final resolvedMalId = malId ?? await _resolveMalId(anilistId);
    if (resolvedMalId == null) return const [];

    final key = '$resolvedMalId:$episode';
    final cached = _lookupSegments(key);
    if (cached != null) return cached;

    final segments = await _fetch(resolvedMalId, episode, duration);
    _storeSegments(key, segments);
    return segments;
  }

  /// AniList id → MAL id through AniList's public GraphQL API (no key).
  /// Only a successful resolution is cached: caching a miss would
  /// poison the whole session for a title AniList simply had not
  /// indexed yet.
  Future<int?> _resolveMalId(int? anilistId) async {
    if (anilistId == null) return null;
    final cached = _lookupMal(anilistId);
    if (cached != null) return cached;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'https://graphql.anilist.co',
        data: {
          'query': r'query ($id: Int) { Media(id: $id) { idMal } }',
          'variables': {'id': anilistId},
        },
      );
      final idMal = response.data?['data']?['Media']?['idMal'];
      final mal = idMal is num
          ? idMal.toInt()
          : int.tryParse(idMal?.toString() ?? '');
      if (mal != null) _storeMal(anilistId, mal);
      return mal;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AniSkip: AniList idMal lookup failed: $e');
      }
      return null;
    }
  }

  Future<List<SkipSegment>> _fetch(int malId, int episode, int duration) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/skip-times/$malId/$episode',
        queryParameters: {
          'types[]': const ['op', 'ed'],
          'episodeLength': duration,
        },
      );
      return parseResponse(
        response.data ?? {},
        durationSec: duration.toDouble(),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('AniSkip lookup failed: $e');
      return const [];
    }
  }

  /// Parses an AniSkip v2 skip-times response into sanitized segments.
  /// Pure, so it is unit-tested (see `aniskip_service_test.dart`).
  ///
  /// Only `op` (opening) and `ed` (ending) are mapped; anything else
  /// the API ever returns is ignored rather than shown as a mystery
  /// button.
  static List<SkipSegment> parseResponse(
    Map<String, dynamic> json, {
    double? durationSec,
  }) {
    if (json['found'] != true) return const [];
    final results = json['results'];
    if (results is! List) return const [];
    final segments = <SkipSegment>[];
    for (final entry in results) {
      if (entry is! Map) continue;
      final interval = entry['interval'];
      if (interval is! Map) continue;
      final start = (interval['startTime'] as num?)?.toDouble();
      final end = (interval['endTime'] as num?)?.toDouble();
      if (start == null || end == null) continue;
      final type = switch ((entry['skipType'] as String?)?.toLowerCase()) {
        'op' => SkipType.intro,
        'ed' => SkipType.outro,
        _ => null,
      };
      if (type == null) continue;
      segments.add(SkipSegment(startTime: start, endTime: end, type: type));
    }
    return SkipSegment.sanitize(segments, durationSec: durationSec);
  }

  int? _lookupMal(int anilistId) {
    final entry = _malCache[anilistId];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _malCache.remove(anilistId);
      return null;
    }
    _malCache.remove(anilistId);
    _malCache[anilistId] = entry;
    return entry.malId;
  }

  void _storeMal(int anilistId, int malId) {
    _malCache.remove(anilistId);
    _malCache[anilistId] = _CachedMal(malId, DateTime.now().add(_cacheTtl));
    while (_malCache.length > _cacheMax) {
      _malCache.remove(_malCache.keys.first);
    }
  }

  List<SkipSegment>? _lookupSegments(String key) {
    final entry = _segmentsCache[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _segmentsCache.remove(key);
      return null;
    }
    _segmentsCache.remove(key);
    _segmentsCache[key] = entry;
    return entry.segments;
  }

  void _storeSegments(String key, List<SkipSegment> segments) {
    _segmentsCache.remove(key);
    _segmentsCache[key] = _CachedSegments(
      segments,
      DateTime.now().add(_cacheTtl),
    );
    while (_segmentsCache.length > _cacheMax) {
      _segmentsCache.remove(_segmentsCache.keys.first);
    }
  }
}

class _CachedMal {
  _CachedMal(this.malId, this.expiresAt);
  final int malId;
  final DateTime expiresAt;
}

class _CachedSegments {
  _CachedSegments(this.segments, this.expiresAt);
  final List<SkipSegment> segments;
  final DateTime expiresAt;
}
