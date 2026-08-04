import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/matrix/orex_forwarded_content.dart';

void main() {
  test('forwards encrypted media by reference and strips room relations', () {
    final result = orexBuildForwardedContent(<String, dynamic>{
      'msgtype': 'm.file',
      'body': 'Отчёт',
      'filename': '../secret?.zip',
      'file': <String, dynamic>{
        'url': 'mxc://vasys.ru/media-id',
        'key': <String, dynamic>{'k': 'secret'},
      },
      'm.relates_to': <String, dynamic>{'m.in_reply_to': <String, dynamic>{}},
      'm.mentions': <String, dynamic>{'user_ids': <String>['@alice:vasys.ru']},
    });

    expect(result['filename'], 'secret_.zip');
    expect(result['file'], isA<Map<String, dynamic>>());
    expect(result.containsKey('m.relates_to'), isFalse);
    expect(result.containsKey('m.mentions'), isFalse);
    expect(result['ru.orex.forwarded'], isTrue);
  });

  test('detects plaintext media that would weaken an encrypted target', () {
    final plain = orexBuildForwardedContent(<String, dynamic>{
      'msgtype': 'm.file',
      'body': 'archive.zip',
      'url': 'mxc://vasys.ru/plain-media',
    });
    final encrypted = orexBuildForwardedContent(<String, dynamic>{
      'msgtype': 'm.file',
      'body': 'archive.zip',
      'file': <String, dynamic>{
        'url': 'mxc://vasys.ru/encrypted-media',
        'key': <String, dynamic>{'k': 'secret'},
      },
    });

    expect(orexForwardedContentNeedsMediaReEncryption(plain), isTrue);
    expect(orexForwardedContentNeedsMediaReEncryption(encrypted), isFalse);
  });

  test('prefers encrypted references and drops plaintext duplicates', () {
    final result = orexBuildForwardedContent(<String, dynamic>{
      'msgtype': 'm.image',
      'body': 'photo.jpg',
      'url': 'mxc://vasys.ru/plain',
      'file': <String, dynamic>{
        'url': 'mxc://vasys.ru/encrypted',
        'key': <String, dynamic>{'k': 'secret'},
      },
      'info': <String, dynamic>{
        'thumbnail_url': 'mxc://vasys.ru/plain-thumb',
        'thumbnail_file': <String, dynamic>{
          'url': 'mxc://vasys.ru/encrypted-thumb',
        },
      },
    });

    expect(result.containsKey('url'), isFalse);
    expect((result['info'] as Map).containsKey('thumbnail_url'), isFalse);
  });

  test('rejects media without an mxc reference', () {
    expect(
      () => orexBuildForwardedContent(<String, dynamic>{
        'msgtype': 'm.video',
        'body': 'video.mp4',
        'url': 'https://example.org/video.mp4',
      }),
      throwsA(isA<OrexForwardingException>()),
    );
  });

  test('removes Matrix reply fallback and original-room mentions', () {
    final result = orexBuildForwardedContent(<String, dynamic>{
      'msgtype': 'm.text',
      'body': '> <@alice:vasys.ru> Секрет\n> продолжение\n\nНовый ответ',
      'format': 'org.matrix.custom.html',
      'formatted_body':
          '<mx-reply><blockquote>Секрет</blockquote></mx-reply><b>Новый ответ</b>',
      'm.relates_to': <String, dynamic>{
        'm.in_reply_to': <String, dynamic>{'event_id': r'$old'},
      },
      'm.mentions': <String, dynamic>{'user_ids': <String>['@alice:vasys.ru']},
    });

    expect(result['body'], 'Новый ответ');
    expect(result['formatted_body'], '<b>Новый ответ</b>');
    expect(result.containsKey('m.relates_to'), isFalse);
    expect(result.containsKey('m.mentions'), isFalse);
  });

  test('rejects oversized or cyclic event metadata before forwarding', () {
    expect(
      () => orexBuildForwardedContent(<String, dynamic>{
        'msgtype': 'm.text',
        'body': 'x'.padRight(
          orexForwardedEventMaxBytes + 1,
          'x',
        ),
      }),
      throwsA(isA<OrexForwardingException>()),
    );

    final cyclic = <String, dynamic>{
      'msgtype': 'm.text',
      'body': 'cycle',
    };
    cyclic['nested'] = cyclic;
    expect(
      () => orexBuildForwardedContent(cyclic),
      throwsA(isA<OrexForwardingException>()),
    );
  });

  test('forwards text without carrying edit metadata', () {
    final result = orexBuildForwardedContent(<String, dynamic>{
      'msgtype': 'm.text',
      'body': 'Готово',
      'm.new_content': <String, dynamic>{'body': 'Старое'},
    });

    expect(result['body'], 'Готово');
    expect(result.containsKey('m.new_content'), isFalse);
  });
}
