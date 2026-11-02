import 'package:animedlatino_plugin/animedlatino_source.dart';
import 'package:test/test.dart';

void main() {
  final s = AnimedLatinoSource();

  group('numeración de episodios', () {
    test('la temporada 1 es el número tal cual; de la 2 en adelante se codifica', () {
      expect(AnimedLatinoSource.encodeEpisode(1, 5), 5);
      expect(AnimedLatinoSource.encodeEpisode(1, 500), 500);
      expect(AnimedLatinoSource.encodeEpisode(2, 5), 20005);
      expect(AnimedLatinoSource.encodeEpisode(12, 3), 120003);
    });

    test('decodeEpisode es el inverso', () {
      for (final se in [(1, 1), (1, 500), (1, 9999), (2, 5), (3, 24), (12, 3)]) {
        final n = AnimedLatinoSource.encodeEpisode(se.$1, se.$2);
        final d = AnimedLatinoSource.decodeEpisode(n);
        expect((d.season, d.episode), se, reason: 'S${se.$1}E${se.$2} -> $n');
      }
    });
  });

  group('URLs', () {
    test('slugFromUrl', () {
      expect(s.slugFromUrl('https://animedlatino.com/serie/naruto-shippuden'), 'naruto-shippuden');
      expect(s.slugFromUrl('https://animedlatino.com/ver/naruto-shippuden/1x5'), 'naruto-shippuden');
      expect(s.slugFromUrl('naruto-shippuden'), 'naruto-shippuden');
    });

    test('parseEpisodeUrl', () {
      final a = s.parseEpisodeUrl('https://animedlatino.com/ver/naruto-shippuden/1x5')!;
      expect((a.slug, a.numero), ('naruto-shippuden', 5));
      final b = s.parseEpisodeUrl('https://animedlatino.com/ver/boruto/2x7')!;
      expect((b.slug, b.numero), ('boruto', 20007));
      expect(s.parseEpisodeUrl('https://animedlatino.com/serie/naruto-shippuden'), isNull);
      expect(s.parseEpisodeUrl('https://animedlatino.com/ver/naruto-shippuden'), isNull);
    });
  });

  test('opciones de filtro', () {
    expect(s.filterOptions.generos.length, 14);
    expect(s.filterOptions.letras.first.value, '%23');
    expect(s.filterOptions.letras.length, 27);
    expect(s.filterOptions.categorias, isEmpty); // el sitio solo clasifica como "serie"
    expect(s.filterOptions.anios, isEmpty);
  });
}
