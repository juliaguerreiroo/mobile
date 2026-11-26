import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class PlayceApi {
  PlayceApi({http.Client? client})
      : _client = client ?? http.Client(),
        baseUrl = const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: 'http://10.0.2.2:3000/api',
        ).replaceFirst(RegExp(r'/$'), '');

  final http.Client _client;
  final String baseUrl;
  String? token;
  void Function()? onUnauthorized;

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
    bool authenticated = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (authenticated && token != null) {
      headers['Authorization'] = 'Bearer $token';
    }

    late http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 20),
          );
      response = await http.Response.fromStream(streamed);
    } on Exception catch (error) {
      if (error is ApiException) rethrow;
      throw const ApiException(
        'Não foi possível conectar à API. Verifique o endereço e tente novamente.',
      );
    }

    dynamic data;
    if (response.body.isNotEmpty) {
      try {
        data = jsonDecode(response.body);
      } on FormatException {
        throw ApiException(
          'A API retornou uma resposta inválida.',
          statusCode: response.statusCode,
        );
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 && authenticated) {
        onUnauthorized?.call();
      }
      var message = 'Não foi possível concluir a solicitação.';
      if (data is Map && data['message'] != null) {
        final value = data['message'];
        if (value is String && value.trim().isNotEmpty) {
          message = value;
        } else if (value is List) {
          message = value.whereType<String>().join(' ');
        }
      }
      throw ApiException(message, statusCode: response.statusCode);
    }
    return data;
  }

  Future<List<Game>> games() async {
    final data = await request('/games');
    if (data is! List) {
      throw const ApiException('Formato inesperado no catálogo.');
    }
    return data.map((item) => Game.fromJson(_map(item))).toList();
  }

  Future<Game> game(int id) async {
    final data = await request('/games/$id');
    return Game.fromJson(_map(data));
  }

  Future<List<Plan>> plans() async {
    final data = await request('/plans');
    if (data is! List) {
      throw const ApiException('Formato inesperado nos planos.');
    }
    return data.map((item) => Plan.fromJson(_map(item))).toList();
  }

  Future<Map<String, dynamic>> authenticate({
    required String email,
    required String password,
    String? name,
  }) async {
    final isRegister = name != null;
    final data = await request(
      isRegister ? '/auth/register' : '/auth/login',
      method: 'POST',
      authenticated: false,
      body: isRegister
          ? {'name': name, 'email': email, 'passwordHash': password}
          : {'email': email, 'password': password},
    );
    return _map(data);
  }

  Future<List<Library>> libraries() async {
    final data = await request('/libraries');
    if (data is! List) {
      throw const ApiException('Formato inesperado na biblioteca.');
    }
    return data.map((item) => Library.fromJson(_map(item))).toList();
  }

  Future<List<PlanGame>> planGames() async {
    final data = await request('/plans/me/games');
    if (data is! List) {
      throw const ApiException('Formato inesperado nos jogos dos planos.');
    }
    return data.map((item) {
      final json = _map(item);
      return PlanGame(
        planId: _int(json['planId']),
        game: Game.fromJson(json),
      );
    }).toList();
  }

  Future<List<PlanGame>> gamesForPlan(int planId) async {
    final data = await request('/plans/$planId/games');
    if (data is! List) {
      throw const ApiException('Formato inesperado nos jogos do plano.');
    }
    return data.map((item) => PlanGame.fromAssociation(_map(item))).toList();
  }

  Future<List<PurchaseReceipt>> purchases() async {
    final data = await request('/purchases');
    if (data is! List) {
      throw const ApiException('Formato inesperado no histórico de compras.');
    }
    return data.map((item) => PurchaseReceipt.fromJson(_map(item))).toList();
  }

  Future<PurchaseReceipt> checkout(List<int> gameIds) async {
    if (gameIds.isEmpty || gameIds.toSet().length != gameIds.length) {
      throw const ApiException('O carrinho precisa ter jogos diferentes.');
    }
    final data = await request(
      '/purchases',
      method: 'POST',
      body: {
        'items': gameIds.map((id) => {'gameId': id}).toList()
      },
    );
    final receipt = PurchaseReceipt.fromJson(_map(data));
    final returnedIds = receipt.items.map((item) => item.gameId).toSet();
    if (receipt.id <= 0 ||
        receipt.items.length != gameIds.length ||
        returnedIds.length != gameIds.length ||
        !returnedIds.containsAll(gameIds) ||
        receipt.totalPrice < 0) {
      throw const ApiException(
        'A API retornou uma confirmação de compra inválida.',
      );
    }
    return receipt;
  }

  Future<PlanSubscription> subscribe(int planId) async {
    final data = await request('/plans/$planId/subscribe', method: 'POST');
    return PlanSubscription.fromJson(_map(data));
  }

  Future<DownloadResult> download(int libraryId, int gameId) async {
    final data = await request(
      '/libraries/$libraryId/games/$gameId/download',
      method: 'POST',
    );
    return DownloadResult.fromJson(_map(data));
  }
}

class Game {
  const Game({
    required this.id,
    required this.name,
    required this.price,
    required this.imageUrl,
    required this.categories,
    this.currentDiscount = 0,
    this.description = '',
    this.longDescription = '',
    this.ownerName = '',
    this.screenshots = const [],
  });

  final int id;
  final String name;
  final double price;
  final String? imageUrl;
  final List<String> categories;
  final double currentDiscount;
  final String description;
  final String longDescription;
  final String ownerName;
  final List<String> screenshots;

  double get finalPrice => priceAtDiscount(currentDiscount);

  double priceAtDiscount(double discount) =>
      ((price * (1 - discount / 100)) * 100).round() / 100;

  factory Game.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'];
    final categories = json['categories'];
    final screenshots = json['screenshots'];
    return Game(
      id: _int(json['id']),
      name: json['name']?.toString() ?? 'Jogo sem título',
      price: _double(json['price']),
      imageUrl: json['imageUrl']?.toString(),
      categories: categories is List
          ? categories
              .whereType<Map>()
              .map((item) => item['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toList()
          : const [],
      currentDiscount: _double(json['currentDiscount']),
      description: json['description']?.toString() ?? '',
      longDescription: json['longDescription']?.toString() ?? '',
      ownerName: owner is Map ? owner['name']?.toString() ?? '' : '',
      screenshots: screenshots is List
          ? screenshots
              .whereType<Map>()
              .map((item) => item['url']?.toString() ?? '')
              .where((url) => url.isNotEmpty)
              .toList()
          : const [],
    );
  }
}

class Plan {
  const Plan({
    required this.id,
    required this.name,
    required this.price,
    required this.maxGames,
    required this.minDiscount,
    required this.maxDiscount,
  });

  final int id;
  final String name;
  final double price;
  final int maxGames;
  final double minDiscount;
  final double maxDiscount;

  factory Plan.fromJson(Map<String, dynamic> json) => Plan(
        id: _int(json['id']),
        name: json['name']?.toString() ?? 'Plano',
        price: _double(json['price']),
        maxGames: _int(json['maxGames']),
        minDiscount: _double(json['minDiscount']),
        maxDiscount: _double(json['maxDiscount']),
      );
}

class PlanPriceQuote {
  const PlanPriceQuote({
    required this.storePrice,
    required this.lowestPlanPrice,
    required this.highestPlanPrice,
    required this.storePromotionIsBest,
  });

  final double storePrice;
  final double lowestPlanPrice;
  final double highestPlanPrice;
  final bool storePromotionIsBest;

  factory PlanPriceQuote.calculate(Game game, Plan plan) {
    final minimumDiscount = game.currentDiscount > plan.minDiscount
        ? game.currentDiscount
        : plan.minDiscount;
    final maximumDiscount = game.currentDiscount > plan.maxDiscount
        ? game.currentDiscount
        : plan.maxDiscount;
    return PlanPriceQuote(
      storePrice: game.priceAtDiscount(game.currentDiscount),
      lowestPlanPrice: game.priceAtDiscount(maximumDiscount),
      highestPlanPrice: game.priceAtDiscount(minimumDiscount),
      storePromotionIsBest:
          game.currentDiscount > 0 && game.currentDiscount >= plan.maxDiscount,
    );
  }
}

class PlanGame {
  const PlanGame({required this.planId, required this.game});

  final int planId;
  final Game game;

  factory PlanGame.fromAssociation(Map<String, dynamic> json) {
    final game = json['game'];
    return PlanGame(
      planId: _int(json['planId']),
      game: Game.fromJson(game is Map ? _map(game) : const {}),
    );
  }
}

class DownloadResult {
  const DownloadResult({
    required this.gameName,
    required this.timePlayed,
  });

  final String gameName;
  final int timePlayed;

  factory DownloadResult.fromJson(Map<String, dynamic> json) => DownloadResult(
        gameName: json['gameName']?.toString() ?? 'Jogo',
        timePlayed: _int(json['timePlayed']),
      );
}

class PlanSubscription {
  const PlanSubscription({
    required this.id,
    required this.userId,
    required this.planId,
    required this.startedAt,
    required this.expiresAt,
    required this.plan,
  });

  final int id;
  final int userId;
  final int planId;
  final DateTime startedAt;
  final DateTime expiresAt;
  final Plan plan;

  factory PlanSubscription.fromJson(Map<String, dynamic> json) {
    final plan = json['plan'];
    return PlanSubscription(
      id: _int(json['id']),
      userId: _int(json['userId']),
      planId: _int(json['planId']),
      startedAt: _date(json['startedAt'], 'início da assinatura'),
      expiresAt: _date(json['expiresAt'], 'validade da assinatura'),
      plan: Plan.fromJson(plan is Map ? _map(plan) : const {}),
    );
  }
}

class PurchaseLine {
  const PurchaseLine({
    required this.gameId,
    required this.acquisitionPrice,
    required this.discount,
    required this.game,
  });

  final int gameId;
  final double acquisitionPrice;
  final double discount;
  final Game game;

  double get finalPrice => acquisitionPrice - discount;

  factory PurchaseLine.fromJson(Map<String, dynamic> json) {
    final game = json['game'];
    return PurchaseLine(
      gameId: _int(json['gameId']),
      acquisitionPrice: _double(json['acquisitionPrice']),
      discount: _double(json['discount']),
      game: Game.fromJson(game is Map ? _map(game) : const {}),
    );
  }
}

class PurchaseReceipt {
  const PurchaseReceipt({
    required this.id,
    required this.totalPrice,
    required this.purchasedAt,
    required this.items,
  });

  final int id;
  final double totalPrice;
  final DateTime purchasedAt;
  final List<PurchaseLine> items;

  double get totalDiscount =>
      items.fold(0, (total, item) => total + item.discount);

  factory PurchaseReceipt.fromJson(Map<String, dynamic> json) {
    final items = json['purchases'];
    return PurchaseReceipt(
      id: _int(json['id']),
      totalPrice: _double(json['totalPrice']),
      purchasedAt: _date(
        json['data'] ?? json['createdAt'],
        'data da compra',
      ),
      items: items is List
          ? items.map((item) => PurchaseLine.fromJson(_map(item))).toList()
          : const [],
    );
  }
}

class Library {
  const Library({
    required this.id,
    required this.games,
    required this.totalHoursPlayed,
  });

  final int id;
  final List<LibraryGame> games;
  final double totalHoursPlayed;

  factory Library.fromJson(Map<String, dynamic> json) {
    final games = json['games'];
    return Library(
      id: _int(json['id']),
      totalHoursPlayed: _double(json['totalHoursPlayed']),
      games: games is List
          ? games.map((item) => LibraryGame.fromJson(_map(item))).toList()
          : const [],
    );
  }
}

class LibraryGame {
  const LibraryGame({
    required this.game,
    required this.timePlayed,
  });

  final Game game;
  final int timePlayed;

  factory LibraryGame.fromJson(Map<String, dynamic> json) {
    final game = json['game'];
    return LibraryGame(
      game: Game.fromJson(game is Map ? _map(game) : const {}),
      timePlayed: _int(json['timePlayed']),
    );
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return const {};
}

int _int(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

double _double(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

DateTime _date(dynamic value, String field) {
  final date = value is String ? DateTime.tryParse(value) : null;
  if (date == null) {
    throw ApiException('A API retornou um formato inválido para $field.');
  }
  return date;
}
