import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/skip/data/aniskip_service.dart';
import 'package:skystream/features/skip/data/skip_service.dart';

void main() {
  group('AniskipService.parseResponse', () {
    // Live payloads, verified 2026-11-16 against api.aniskip.com.
    test('maps Demon Slayer ep 1 OP + ED to intro + outro', () {
      final segments = AniskipService.parseResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 5.617, 'endTime': 95.617},
            'skipType': 'op',
            'skipId': '04e8cbb7-60d6-4132-840a-24a867c1a80c',
            'episodeLength': 1435.193,
          },
          {
            'interval': {'startTime': 1295.128, 'endTime': 1385.128},
            'skipType': 'ed',
            'skipId': 'a46dcea2-4075-43ac-bcc9-e9b00f710424',
            'episodeLength': 1426.0304,
          },
        ],
        'message': 'Successfully found skip times',
        'statusCode': 200,
      }, durationSec: 1435);
      expect(segments.length, 2);
      expect(segments[0].type, SkipType.intro);
      expect(segments[0].startTime, 5.617);
      expect(segments[0].endTime, 95.617);
      expect(segments[1].type, SkipType.outro);
      expect(segments[1].startTime, 1295.128);
      expect(segments[1].endTime, 1385.128);
    });

    test('maps One Piece ep 1000 OP-only answer', () {
      final segments = AniskipService.parseResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 13.891, 'endTime': 123.834},
            'skipType': 'op',
            'skipId': '5bcf9262-b16f-40ad-9d12-8168e4ecad2d',
            'episodeLength': 1430.721,
          },
        ],
        'message': 'Successfully found skip times',
        'statusCode': 200,
      }, durationSec: 1430);
      expect(segments.length, 1);
      expect(segments[0].type, SkipType.intro);
    });

    test('found:false and missing results are an empty list, not an error', () {
      expect(
        AniskipService.parseResponse(<String, dynamic>{
          'found': false,
          'results': [],
        }),
        isEmpty,
      );
      expect(
        AniskipService.parseResponse(<String, dynamic>{'found': true}),
        isEmpty,
      );
      expect(AniskipService.parseResponse(<String, dynamic>{}), isEmpty);
    });

    test('ignores unknown skip types and malformed entries', () {
      final segments = AniskipService.parseResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 10, 'endTime': 90},
            'skipType': 'op',
          },
          {
            'interval': {'startTime': 500, 'endTime': 590},
            'skipType': 'recap',
          },
          {
            'interval': {'startTime': 700},
            'skipType': 'ed',
          },
          'not-a-map',
        ],
      }, durationSec: 1400);
      expect(segments.length, 1);
      expect(segments[0].type, SkipType.intro);
    });
  });

  group('AniskipService sync-data id readings', () {
    test('reads MAL id under every spelling plugins use', () {
      expect(AniskipService.malIdFromSyncData({'mal': '38000'}), 38000);
      expect(AniskipService.malIdFromSyncData({'malId': '21'}), 21);
      expect(AniskipService.malIdFromSyncData({'mal_id': '21'}), 21);
      expect(AniskipService.malIdFromSyncData({'anilist': '21'}), isNull);
      expect(AniskipService.malIdFromSyncData(null), isNull);
      expect(AniskipService.malIdFromSyncData({'mal': 'not-a-number'}), isNull);
    });

    test('reads AniList id under every spelling plugins use', () {
      expect(AniskipService.anilistIdFromSyncData({'anilist': '21'}), 21);
      expect(AniskipService.anilistIdFromSyncData({'anilistId': '21'}), 21);
      expect(AniskipService.anilistIdFromSyncData({'anilist_id': '21'}), 21);
      expect(AniskipService.anilistIdFromSyncData(null), isNull);
    });
  });
}
