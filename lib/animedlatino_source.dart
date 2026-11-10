import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:rolostream_core/rolostream_core.dart' as core;

/// Las secciones `/hentai` y `/adultos` del sitio no se consultan nunca.
class AnimedLatinoSource implements core.SourcePlugin {
  AnimedLatinoSource({String? baseUrl}) : baseUrl = baseUrl ?? defaultBaseUrl {
    _dio = Dio(BaseOptions(
      headers: {
        'User-Agent': _userAgent,
        'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
      followRedirects: true,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      validateStatus: (status) => status != null && status < 500,
    ));
    _dio.interceptors.add(CookieManager(CookieJar()));
  }

  static const defaultBaseUrl = 'https://animedlatino.com';

  final String baseUrl;

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

  /// Los episodios de la temporada 1 son su número tal cual; de la 2 en adelante se codifican
  /// `temporada * seasonFactor + episodio` (la app los muestra como "T2 E5").
  static const seasonFactor = 10000;

  static int encodeEpisode(int season, int episode) =>
      season <= 1 ? episode : season * seasonFactor + episode;

  static ({int season, int episode}) decodeEpisode(int numero) => numero < seasonFactor
      ? (season: 1, episode: numero)
      : (season: numero ~/ seasonFactor, episode: numero % seasonFactor);

  late final Dio _dio;

  @override
  String get id => 'animedlatino';

  @override
  String get name => 'AnimedLatino';

  @override
  String? get iconAsset => null;

  @override
  core.FilterOptions get filterOptions => _filterOptions;

  @override
  String slugFromUrl(String url) {
    final segs = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? [];
    if (segs.length >= 2 && (segs[0] == 'serie' || segs[0] == 'ver')) return segs[1];
    return segs.isEmpty ? url : segs.last;
  }

  @override
  ({String slug, int numero})? parseEpisodeUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final m = RegExp(r'^/?ver/([^/]+)/(\d+)x(\d+)/?$').firstMatch(path);
    if (m == null) return null;
    return (
      slug: m.group(1)!,
      numero: encodeEpisode(int.parse(m.group(2)!), int.parse(m.group(3)!)),
    );
  }

  String _abs(String href) {
    if (href.isEmpty || href.startsWith('http')) return href;
    return '$baseUrl/${href.replaceFirst(RegExp(r'^/'), '')}';
  }

  Future<Document> _getDoc(String url, {Map<String, dynamic>? query, String? referer}) async {
    final res = await _dio.get<String>(
      url,
      queryParameters: query,
      options: Options(
        responseType: ResponseType.plain,
        headers: referer == null ? null : {'Referer': referer},
      ),
    );
    return html_parser.parse(res.data ?? '');
  }

  List<({String titulo, String url, String imagen, String detalle})> _cards(Document doc) {
    final seen = <String>{};
    final out = <({String titulo, String url, String imagen, String detalle})>[];
    for (final card in doc.querySelectorAll('article.tarjeta')) {
      final href = card.querySelector('a.tarjeta__enlace')?.attributes['href'] ?? '';
      final titulo = card.querySelector('.tarjeta__titulo')?.text.trim() ?? '';
      if (href.isEmpty || titulo.isEmpty || !seen.add(href)) continue;
      out.add((
        titulo: titulo,
        url: _abs(href),
        imagen: _abs(card.querySelector('img.tarjeta__imagen')?.attributes['src'] ?? ''),
        detalle: card.querySelector('.tarjeta__detalle')?.text.trim() ?? '',
      ));
    }
    return out;
  }

  @override
  Future<List<core.AnimeResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final doc = await _getDoc('$baseUrl/buscar', query: {'q': query.trim()});
    return [
      for (final c in _cards(doc))
        core.AnimeResult(nombre: c.titulo, url: c.url, imagen: c.imagen),
    ];
  }

  @override
  Future<List<core.RecentSerie>> getRecentSeries() async => [
        for (final c in _cards(await _getDoc('$baseUrl/recien-agregados')))
          core.RecentSerie(titulo: c.titulo, url: c.url, imagen: c.imagen),
      ];

  @override
  Future<List<core.RecentEpisode>> getLatestEpisodes() async {
    final doc = await _getDoc('$baseUrl/ultimos');
    final seen = <String>{};
    final out = <core.RecentEpisode>[];
    for (final item in doc.querySelectorAll('article.ultimo')) {
      final href = item.querySelector('a')?.attributes['href'] ?? '';
      final titulo = item.querySelector('.ultimo__titulo')?.text.trim() ?? '';
      if (parseEpisodeUrl(href) == null || titulo.isEmpty || !seen.add(href)) continue;
      final fecha = item.querySelector('.ultimo__fecha')?.text.trim() ?? '';
      out.add(core.RecentEpisode(
        titulo: titulo,
        url: _abs(href),
        imagen: _abs(item.querySelector('img')?.attributes['src'] ?? ''),
        fecha: fecha.contains('·') ? fecha.split('·').last.trim() : '',
      ));
    }
    return out;
  }

  @override
  Future<List<core.AiringAnime>> getAiringAnimes({int page = 1}) async {
    final doc = await _getDoc('$baseUrl/tipo/serie',
        query: {'tipo': 'serie', 'orden': 'recientes', if (page > 1) 'pagina': '$page'});
    return [
      for (final c in _cards(doc))
        core.AiringAnime(titulo: c.titulo, url: c.url, imagen: c.imagen, tipo: 'Serie', anio: ''),
    ];
  }

  /// Prioridad: género, letra, tipo (`categoria`, por defecto `serie`). El sitio no filtra por año.
  @override
  Future<List<core.FilterAnime>> getAnimesByFilter({
    String genero = 'false',
    String fecha = 'false',
    String letra = 'false',
    String categoria = 'false',
    int page = 1,
  }) async {
    final String path;
    final Map<String, dynamic> query;
    if (genero != 'false') {
      path = '/genero/$genero';
      query = {'genero': genero, 'orden': 'populares'};
    } else if (letra != 'false') {
      path = '/letra/$letra';
      query = {'letra': Uri.decodeComponent(letra), 'orden': 'titulo'};
    } else {
      final tipo = categoria != 'false' ? categoria : 'serie';
      path = '/tipo/$tipo';
      query = {'tipo': tipo, 'orden': 'recientes'};
    }
    final doc = await _getDoc('$baseUrl$path', query: {...query, if (page > 1) 'pagina': '$page'});
    return [
      for (final c in _cards(doc))
        core.FilterAnime(
          titulo: c.titulo,
          url: c.url,
          imagen: c.imagen,
          tipo: c.detalle.isEmpty ? 'Serie' : c.detalle,
          anio: '',
        ),
    ];
  }

  @override
  Future<core.AnimeDetail> getAnime(String slug) async {
    final clean = slugFromUrl(slug);
    final doc = await _getDoc('$baseUrl/serie/$clean');

    final titulo = doc.querySelector('.ficha h1')?.text.trim() ?? '';
    if (titulo.isEmpty) throw Exception('No se encontró "$clean" en AnimedLatino');

    String estado = '';
    for (final li in doc.querySelectorAll('.ficha__meta li')) {
      final label = li.querySelector('strong')?.text.trim() ?? '';
      if (label.startsWith('Estado')) {
        estado = li.text.replaceFirst(label, '').trim();
      }
    }

    final byNumber = <int, core.Episode>{};
    for (final li in doc.querySelectorAll('li[data-capitulo]')) {
      final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(li.attributes['data-capitulo'] ?? '');
      final href = li.querySelector('a')?.attributes['href'] ?? '';
      if (m == null || href.isEmpty) continue;
      final numero = encodeEpisode(int.parse(m.group(1)!), int.parse(m.group(2)!));
      final titleText = li.querySelector('.lista-enlaces__titulo')?.text.trim() ?? '';
      byNumber[numero] = core.Episode(
        numero: numero,
        url: _abs(href),
        titulo: titleText.isEmpty ? 'Capítulo ${m.group(2)}' : titleText,
      );
    }

    return core.AnimeDetail(
      titulo: titulo,
      sinopsis: doc.querySelector('.ficha__sinopsis')?.text.trim() ?? '',
      imagen: _abs(doc.querySelector('.ficha__portada')?.attributes['src'] ?? ''),
      estado: estado,
      generos: [
        for (final a in doc.querySelectorAll('.ficha__generos a'))
          if (a.text.trim().isNotEmpty) a.text.trim(),
      ],
      episodios: byNumber.values.toList()..sort((a, b) => a.numero.compareTo(b.numero)),
    );
  }

  @override
  Future<List<core.VideoServer>> getServers(String slug, int numero) async {
    final e = decodeEpisode(numero);
    final pageUrl = '$baseUrl/ver/${slugFromUrl(slug)}/${e.season}x${e.episode}';
    final doc = await _getDoc(pageUrl);

    final entries = <({String name, String dataUrl})>[];
    for (final b in doc.querySelectorAll('button.servidor[data-url]')) {
      final dataUrl = b.attributes['data-url'] ?? '';
      if (dataUrl.isEmpty) continue;
      final name = (b.attributes['data-servidor'] ?? b.text).trim();
      entries.add((name: name.isEmpty ? 'Servidor' : name, dataUrl: dataUrl));
    }

    // Una petición por servidor, en paralelo. Si una falla o tarda, solo se pierde esa.
    final resolved = await Future.wait([for (final s in entries) _resolve(s.dataUrl, pageUrl)]);

    final seenUrls = <String>{};
    final nameCount = <String, int>{};
    final out = <core.VideoServer>[];
    for (var i = 0; i < entries.length; i++) {
      final url = resolved[i];
      if (url == null || !seenUrls.add(url)) continue;
      // Varios servidores con el mismo nombre: "Okru", "Okru (2)". La app descarta el paréntesis
      // al elegir el extractor del proxy.
      final n = (nameCount[entries[i].name] = (nameCount[entries[i].name] ?? 0) + 1);
      out.add(core.VideoServer(
        nombre: n == 1 ? entries[i].name : '${entries[i].name} ($n)',
        url: url,
      ));
    }

    // El reproductor abre el primero: primero los que el proxy sabe extraer.
    bool supported(core.VideoServer v) => proxySupported.any(v.nombre.toLowerCase().startsWith);
    return [...out.where(supported), ...out.where((v) => !supported(v))];
  }

  static const proxySupported = ['okru', 'voe', 'streamwish', 'filemoon', 'doodstream', 'mp4upload'];

  /// Se usa el parser HTML para decodificar los `&amp;` del `src`.
  Future<String?> _resolve(String dataUrl, String referer) async {
    try {
      final doc = await _getDoc(dataUrl, referer: referer).timeout(const Duration(seconds: 10));
      final src = doc.querySelector('iframe')?.attributes['src'] ?? '';
      return src.startsWith('http') ? src : null;
    } catch (_) {
      return null; // timeout o error de red: ese servidor se omite
    }
  }
}

// Sin `categorias`: /tipo/pelicula y /tipo/ova existen pero el sitio responde "0 resultados"
// (todo su catálogo está clasificado como "serie"), así que un filtro de tipo no aporta nada.
final _filterOptions = core.FilterOptions(
  generos: _generos,
  letras: _letras,
);

const _generos = <core.FilterOption>[
  core.FilterOption('accion', 'Acción'),
  core.FilterOption('aventura', 'Aventura'),
  core.FilterOption('ciencia-ficcion', 'Ciencia ficción'),
  core.FilterOption('comedia', 'Comedia'),
  core.FilterOption('deportes', 'Deportes'),
  core.FilterOption('drama', 'Drama'),
  core.FilterOption('escolar', 'Escolar'),
  core.FilterOption('fantasia', 'Fantasía'),
  core.FilterOption('mecha', 'Mecha'),
  core.FilterOption('misterio', 'Misterio'),
  core.FilterOption('musica', 'Música'),
  core.FilterOption('policial', 'Policial'),
  core.FilterOption('recuentos-de-la-vida', 'Recuentos de la vida'),
  core.FilterOption('romance', 'Romance'),
];

final _letras = <core.FilterOption>[
  const core.FilterOption('%23', '#'),
  for (final c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) core.FilterOption(c, c),
];
