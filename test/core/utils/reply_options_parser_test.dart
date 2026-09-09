import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/utils/reply_options_parser.dart';

void main() {
  group('parseReplyOptionsFinal', () {
    test('keeps ordinary text unchanged when there is no marker', () {
      const text = '普通正文，没有选项。';
      final result = parseReplyOptionsFinal(text);

      expect(result.body, text);
      expect(result.options, isEmpty);
      expect(result.markerDetected, isFalse);
      expect(result.valid, isFalse);
    });

    test('trims, removes empty and duplicate options, and caps at six', () {
      final result = parseReplyOptionsFinal('''正文

<kelivo_options>
<option>  一  </option>
<option></option>
<option>二
两</option>
<option>一</option>
<option>三</option>
<option>四</option>
<option>五</option>
<option>六</option>
<option>七</option>
</kelivo_options>''');

      expect(result.body, '正文');
      expect(result.options, ['一', '二\n两', '三', '四', '五', '六']);
      expect(result.markerDetected, isTrue);
      expect(result.valid, isTrue);
    });

    test('accepts Chinese and plain text that resembles markup', () {
      final result = parseReplyOptionsFinal(
        '''故事
<kelivo_options><option>查看 <b>门</b></option><option>/leave</option></kelivo_options>''',
      );

      expect(result.body, '故事');
      expect(result.options, ['查看 <b>门</b>', '/leave']);
      expect(result.valid, isTrue);
    });

    test('invalid or unclosed block withholds the protocol tail', () {
      for (final text in [
        '正文<kelivo_options><option>一</option>',
        '正文<kelivo_options><option>一</kelivo_options>',
        '正文<kelivo_options>坏格式</kelivo_options>',
        '正文<kelivo_options><option>一</option></kelivo_options>尾巴',
      ]) {
        final result = parseReplyOptionsFinal(text);
        expect(result.body, '正文');
        expect(result.options, isEmpty);
        expect(result.markerDetected, isTrue);
        expect(result.valid, isFalse);
      }
    });

    test('oversized blocks are rejected', () {
      final text =
          '正文<kelivo_options><option>${'x' * replyOptionsMaxBlockLength}'
          '</option></kelivo_options>';
      final result = parseReplyOptionsFinal(text);

      expect(result.body, '正文');
      expect(result.options, isEmpty);
      expect(result.valid, isFalse);
    });
  });

  group('parseReplyOptionsStreaming', () {
    test('withholds a partial opening marker', () {
      final result = parseReplyOptionsStreaming('正文<keli');

      expect(result.body, '正文');
      expect(result.markerDetected, isFalse);
    });

    test('handles the opening marker split across accumulated chunks', () {
      final first = parseReplyOptionsStreaming('正文\n<kelivo_');
      final second = parseReplyOptionsStreaming(
        '正文\n<kelivo_options><option>一</option>',
      );

      expect(first.body, '正文\n');
      expect(second.body, '正文\n');
      expect(second.markerDetected, isTrue);
      expect(second.body, isNot(contains('option')));
    });

    test('does not hide ordinary text containing a non-prefix angle tag', () {
      final result = parseReplyOptionsStreaming('正文 <kelivo nope>');

      expect(result.body, '正文 <kelivo nope>');
    });
  });
}
